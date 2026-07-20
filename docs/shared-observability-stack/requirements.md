# Requirements: Shared Observability Stack

## Problem statement
Desktop-hosted services each stand up their own Grafana (and in one case Loki): `fashion-monitor-grafana-1` (port 3001) and `financial-pipeline-grafana-1` (port 3200), backed by a standalone `financial-pipeline-loki-1`. No Prometheus exists anywhere. This duplicates the same class of infrastructure per repo, wastes desktop resources running redundant Grafana instances, and leaves host + container metrics (CPU, memory, disk) uncollected entirely since no repo scrapes them. Per home-infra's established shared-service pattern (ADR 0014), cross-cutting infrastructure deployed once and consumed at runtime belongs in `home-infra`, not duplicated per product repo. This matters now because a second duplicate stack (financial-pipeline's) has already been stood up, confirming the duplication is a recurring pattern that will keep recurring as new services are added unless a shared stack exists to attach to.

## Users / stakeholders
- Preston (sole operator) — views dashboards, receives alerts, deploys and maintains the stack.
- financial-pipeline — a live repo with real bank/investment adapters (Plaid, Betterment, Fidelity, Vanguard); consumer of the shared stack for its metrics/logs; its data adapters and containers are out of scope for this feature.
- fashion-monitor — a live scrape+alert service; consumer of the shared stack for its metrics/logs; its scrape/alert logic is out of scope for this feature.
- Any future desktop or NAS service that needs metrics/logs — the shared stack is the intended attach point going forward, not a one-off migration.

## Functional requirements
1. The system shall provide a Prometheus instance running as a desktop service, deployed from `compose/desktop/observability/docker-compose.yml`, that scrapes and stores host and container metrics.
2. The system shall provide a Grafana instance running as a desktop service that reads from the shared Prometheus and shared Loki as its only metrics/logs data sources.
3. The system shall provide a Loki instance running as a desktop service that receives and stores log streams shipped by Grafana Alloy.
4. The system shall provide a Grafana Alloy instance running as a desktop service that (a) scrapes node_exporter for host-level metrics (CPU, memory, disk, network), (b) scrapes cAdvisor for per-container metrics, and (c) tails and ships Docker container logs to the shared Loki, scoped to an explicit allow-list or label-based opt-in — not blanket discovery of every container running on the desktop. In this build phase, only containers under the observability stack itself (or containers explicitly labeled to opt in) shall be included, so that other live services on the desktop — including financial-pipeline's containers, which touch real Plaid/Betterment/Fidelity/Vanguard data — are never auto-captured until they are deliberately and separately repointed at the shared stack per requirement 16.
5. The system shall bind Grafana Alloy's debug/status UI (port 12345) to loopback only (127.0.0.1), not exposed on the LAN interface, since it exposes container topology and pipeline health with no authentication.
6. The system shall run node_exporter and cAdvisor as desktop services to expose the metrics Alloy scrapes in requirement 4.
7. The system shall run every container in the observability stack (Prometheus, Grafana, Loki, Alloy, node_exporter, cAdvisor) under a single dedicated nologin service user (e.g. `observability`), per CONVENTIONS.md section 1, never under `preston` or `root`.
8. The system shall define a Docker healthcheck for every one of the six services in the stack (Prometheus, Grafana, Loki, Alloy, node_exporter, cAdvisor), since acceptance criterion 4 requires verifying all containers are running and healthy.
9. cAdvisor and Grafana Alloy each require read access to the Docker socket to function — cAdvisor reads cgroups via the socket, and Alloy's `discovery.docker` component enumerates containers via the socket — this is a firm, known requirement, not conditional on deployment specifics. The system shall grant the cAdvisor and Alloy containers read access to the Docker socket (e.g. via a bind mount of `/var/run/docker.sock`) to satisfy this. This is a separate concern from CONVENTIONS.md section 1's narrow-sudoers-grant rule, which governs the HOST `observability` service user's own privilege boundary (that user never joins the docker group; any host-level docker-invoking access it needs, e.g. for `deploy.sh`, is granted solely through a scoped `/etc/sudoers.d/observability` entry) — not which containers' internal processes read the Docker socket.
10. The system shall provision Grafana dashboards as code: dashboard JSON files committed to the repo (e.g. under `compose/desktop/observability/dashboards/`) and loaded via Grafana's file-based dashboard provisioning, not created or edited through the Grafana UI.
11. The system shall include, among the provisioned dashboards, an equivalent of each dashboard currently present in `fashion-monitor-grafana-1` and `financial-pipeline-grafana-1`, exported or recreated from those instances before they are decommissioned. A provisioned dashboard is equivalent to its source when: (a) it has the same panel count as the source dashboard, (b) each panel's underlying query is unchanged from the source except for the datasource reference, which is repointed at the new shared Prometheus/Loki, and (c) the dashboard renders data when loaded in the new Grafana.
12. The system shall provision Prometheus and Loki data sources in the shared Grafana as code (via Grafana provisioning config files in the repo), not manually added through the UI.
13. The system shall provision Grafana's Prometheus and Loki data sources with fixed, explicit `uid:` values (not auto-generated), and every dashboard JSON file shall reference those literal fixed UIDs directly in its panel datasource fields — not Grafana's `${DS_PROMETHEUS}` / `${DS_LOKI}` template-variable syntax, which is resolved only by Grafana's UI import wizard and not by file-based provisioning; using template variables in provisioned dashboard JSON will silently fail to resolve and break every panel.
14. The system shall expose Grafana on the desktop at a port distinct from the two ports it is replacing (3001, 3200), documented in the stack's README.
15. The system shall follow the `compose/desktop/scraper-egress/` file layout convention: `docker-compose.yml`, `.env.example` (placeholders only, real `.env` desktop-only and git-ignored), `deploy.sh`, and `README.md` under `compose/desktop/observability/`.
16. The system shall document, in the stack's README, how a consumer repo (e.g. financial-pipeline, fashion-monitor) points its metrics/logs at the shared Prometheus/Loki instead of running its own — this is the attach contract for requirement 3 of the Scope section (financial-pipeline/fashion-monitor repointing), which is implemented as a follow-on step outside this build.
17. The system shall persist Prometheus, Grafana, and Loki data via named Docker volumes (or bind mounts owned by the `observability` service user) that survive container restarts and redeploys.
18. The system shall not require modifying financial-pipeline's data adapters (Plaid/Betterment/Fidelity/Vanguard), materializer, or Postgres, or fashion-monitor's scrape/alert logic, to satisfy any requirement above.

## Non-functional requirements
- Every container in the stack runs under the dedicated `observability` nologin service user; no container runs as `preston` or `root` (CONVENTIONS.md section 1).
- No real credentials (Grafana admin password, any API tokens) are committed to the repo; only `.env.example` with placeholders is tracked, per CONVENTIONS.md section 5.
- The stack is a shared service, attached to at runtime by consumers, not imported or copy-pasted per repo (CONVENTIONS.md section 8 / ADR 0014 precedent).
- Resource limits (`mem_limit`/`cpus`) must be set on every service in the stack, using conservative defaults consistent with this repo's other stacks (`scraper-egress`, `embed-stack` precedent). This is mandatory independent of the exact numeric idle-usage ceiling — the numeric ceiling for total stack CPU/memory at idle is an open question for Preston to set later (numeric ceiling TBD, revisit with Preston).
- Dashboard/data-source provisioning must be idempotent: re-running `deploy.sh` or restarting the stack must not duplicate dashboards or data sources.

## Constraints
- Must integrate with the desktop's existing Docker Compose deployment pattern (as seen in `compose/desktop/scraper-egress/` and `compose/desktop/embed-stack/`).
- Must follow CONVENTIONS.md section 1 (dedicated service user, narrow sudoers grant, never docker-group).
- Must follow CONVENTIONS.md section 8 (shared services live in home-infra, attached-to not imported).
- Mandated components per the feature description: Prometheus, Grafana, Loki, Grafana Alloy as the unified collector (not Grafana Agent, which is deprecated). No other collector or backend substitutions.
- Must not touch or modify financial-pipeline's live data adapters (Plaid, Betterment, Fidelity, Vanguard), its materializer, or its Postgres database — those containers keep running unmodified throughout this build.
- Must not touch or modify fashion-monitor's scrape/alert logic.
- Old `fashion-monitor-grafana-1`, `financial-pipeline-grafana-1`, and `financial-pipeline-loki-1` containers stay running until the new shared stack is confirmed serving equivalent dashboards — no teardown before verification.
- Per CONVENTIONS.md section 2, deployment and any commands touching live desktop state run on the desktop (`ssh desktop-agent`) as the service user, not from the Mac checkout.

## Out of scope
- Editing financial-pipeline's docker-compose.yml to remove its embedded Grafana/Loki (follow-on step, separate repo, after shared stack is verified).
- Editing fashion-monitor's docker-compose.yml to remove its embedded Grafana (follow-on step, separate repo, after shared stack is verified).
- Stopping/removing the old `fashion-monitor-grafana-1`, `financial-pipeline-grafana-1`, `financial-pipeline-loki-1` containers (follow-on step, after verification).
- Any change to financial-pipeline's data adapters, materializer, or Postgres.
- Any change to fashion-monitor's scrape or alert logic.
- Alerting/notification rules (Grafana alerting, Alertmanager) beyond what already exists in the exported dashboards — not called for in the feature description.
- Long-term retention/backup policy for Prometheus/Loki data beyond persistence across restarts.
- Extending the shared stack to the NAS (10.0.0.250) — this build targets the desktop only; NAS scraping is a future attach, not part of this feature.
- Public/Cloudflare Tunnel exposure of Grafana — per CONTEXT.md's Public Service / Internal Service distinction, this stack is Internal Service (LAN/Tailscale only) unless explicitly requested otherwise.
- Migrating or recreating alert rules, annotations, or historical time-series data from the old Grafana/Loki instances — only dashboard definitions are carried over.
- Blanket, opt-out log collection from every desktop container, including financial-pipeline's live adapters, in this build phase.

## Acceptance criteria
1. `compose/desktop/observability/docker-compose.yml` defines Prometheus, Grafana, Loki, Grafana Alloy, node_exporter, and cAdvisor services, all running under the `observability` service user.
2. `compose/desktop/observability/.env.example` exists with placeholder values only; no live secrets are present in any tracked file in the directory.
3. `compose/desktop/observability/deploy.sh` and `compose/desktop/observability/README.md` exist and follow the same structure as `compose/desktop/scraper-egress/`.
4. On the desktop, `sudo -u observability docker ps` (or equivalent) shows all six containers running and healthy.
5. Prometheus's targets page shows node_exporter and cAdvisor as `UP`.
6. Grafana, reachable at the documented port, shows Prometheus and Loki as pre-provisioned data sources (no manual UI configuration required after a fresh deploy).
7. For every dashboard present in `fashion-monitor-grafana-1` and `financial-pipeline-grafana-1` at the start of this work, an equivalent dashboard JSON file exists under `compose/desktop/observability/dashboards/`, and for each: (a) the dashboard loads via Grafana's API with HTTP 200, (b) every panel's datasource reference resolves (no "datasource not found" errors), and (c) at least one panel returns non-empty query results.
8. Querying Loki in the new Grafana for desktop container logs (any container) returns log lines shipped by Alloy.
9. Restarting the full observability stack (`docker compose down && docker compose up -d` as the `observability` user) preserves existing Prometheus metric history and Grafana dashboards without manual re-provisioning.
10. Running `deploy.sh` (or restarting the stack) twice in succession leaves the Grafana dashboard count and datasource count unchanged between the two runs — verified by comparing counts via Grafana's API after each of the two consecutive deploys.
11. The `observability` service user has no `docker` group membership; any host-level `docker`-invoking access it uses (e.g. for `deploy.sh`) is granted solely through a scoped `/etc/sudoers.d/observability` entry, verified by inspecting `/etc/sudoers.d/observability` and `groups observability` on the desktop. Separately, cAdvisor and Alloy containers have direct read access to the Docker socket via bind mount, verified by inspecting their container mounts.
12. Throughout the build and verification, `financial-pipeline-grafana-1`, `financial-pipeline-loki-1`, and `fashion-monitor-grafana-1` remain running and unmodified, and financial-pipeline's Plaid/Betterment/Fidelity/Vanguard adapters, materializer, and Postgres show no configuration or code diff.
