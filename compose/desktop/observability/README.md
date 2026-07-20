# observability — shared metrics and logs stack

A single Prometheus + Grafana + Loki + Grafana Alloy stack (`observability-*` containers),
deployed once on the desktop, replacing the duplicate `fashion-monitor-grafana-1` and
`financial-pipeline-grafana-1` instances that were running per-repo. No project copies
or imports this; it is deployed once as a shared service and consumed at runtime.

**This is a shared service, not a library.** Consumers attach at runtime:

```yaml
services:
  my-app:
    # Push logs to the shared Loki
    environment:
      - LOKI_WRITE_URL=http://loki:3100/loki/api/v1/push
    # Or point a Promtail/Alloy at the shared Loki
    depends_on:
      observability:
        condition: service_healthy
```

Metrics are pull-based: add a scrape target to this stack's `prometheus.yml` when a consumer
actually attaches (separate follow-on step per requirement scope).

## Ports

| Service | Port | Bind | Notes |
|---------|------|------|-------|
| Grafana | 3300 | LAN | dashboards + datasource UI; distinct from 3001, 3200 (old instances) |
| Prometheus | 9090 | LAN | HTTP/PromQL query API; host-published for consumer attach (no auth, LAN-only tradeoff) |
| Loki | 3100 | LAN | HTTP push/query API; host-published for consumer attach (no auth, LAN-only tradeoff) |
| Alloy UI | 12345 | loopback | debug/status UI on `127.0.0.1:12345` only; not LAN-exposed (no auth) |
| node_exporter | 9100 | internal | metrics endpoint; reachable only via `observability_net`, not host-published |
| cAdvisor | 8080 | internal | metrics endpoint; reachable only via `observability_net`, not host-published |

## Services

Six containers, all under the `observability` nologin service user (except cAdvisor and Alloy — see below):

- **Prometheus** — time-series database for host and container metrics. Scrapes node_exporter and
  cAdvisor directly via native `scrape_configs` (standard pull model). Retention: 15 days or 5 GB
  (conservative infra hygiene default). Runs under `observability` UID/GID.

- **Grafana** — dashboard UI. Queries Prometheus (PromQL) and Loki (LogQL) via pre-provisioned
  datasources with fixed UIDs (`prometheus`, `loki`); dashboards are provisioned JSON, zero manual
  UI configuration needed after deploy. Runs under `observability` UID/GID.

- **Loki** — log aggregation backend. Receives logs pushed by Alloy and (in future) by consumer
  services. Retention: 336 hours (14 days). Runs under `observability` UID/GID.

- **Grafana Alloy** — unified collector, scoped to **logs only**. Discovers desktop containers via
  `discovery.docker`, tails their logs, applies relabel/process rules to keep only stable labels
  (container name, service name) and drop churning ones (full container ID, ephemeral labels),
  ships logs to Loki. **Does not collect metrics** — Prometheus scrapes node_exporter/cAdvisor
  directly. Runs as image default (needs docker.sock).

- **node_exporter** — host-level metrics (CPU, memory, disk, network). Runs under `observability`
  UID/GID.

- **cAdvisor** — per-container metrics (CPU, memory, network, I/O). Runs as image default (needs
  docker.sock and cgroup read access).

### docker.sock and user pinning

The `observability` service user (UID/GID set by `deploy.sh`) owns the bind-mount data directories
and has a scoped sudoers grant to run `docker compose` commands. Prometheus, Grafana, Loki, and
node_exporter run under this UID/GID.

**cAdvisor and Alloy are exceptions**: both need `/var/run/docker.sock` (owned `root:docker`, mode
660) to function. cAdvisor also needs raw cgroup access. The host `observability` user never joins
the docker group (it uses narrow sudoers, per CONVENTIONS.md § 1) — but the containers' *internal*
processes can and do mount the socket. cAdvisor and Alloy run as their image defaults (root-equivalent
inside the container) because this socket access is their documented job, not a privilege escalation.
This is not a violation of CONVENTIONS.md's host-user boundary rule.

## Dashboards and datasources

Dashboards are **provisioned as code**: JSON files committed to the repo under `dashboards/`, loaded
via Grafana's file-based dashboard provisioning (`/etc/grafana/provisioning/dashboards`). Edits to
JSON files are picked up without manual restart.

Datasources are **provisioned as code**: YAML config in `provisioning/datasources/datasources.yml`,
defining Prometheus and Loki with **explicit fixed UIDs** (`uid: prometheus`, `uid: loki`). Dashboard
panel `datasource` fields reference these literal UIDs directly (not Grafana's `${DS_PROMETHEUS}`
template-variable syntax, which only resolves through the UI import wizard, not file provisioning).

## Consumer attach contract

**Logs (push-based):** A consumer's Alloy/Promtail instance can point directly at the shared Loki
without running its own:

```yaml
loki.write:
  clients:
    - url: http://10.0.0.243:3100/loki/api/v1/push
```

**Metrics (pull-based):** Because Prometheus has no remote-write receiver, a consumer's app-level
`/metrics` endpoint is attached by editing this stack's `prometheus.yml` and adding a new
`static_configs` target to the appropriate scrape job. This is a small follow-on edit made when a
consumer actually attaches, not pre-built. Querying `10.0.0.243:9090` directly (PromQL, dashboards,
tooling) works without consumer modification.

**Scope note:** In this build phase, Alloy's `discovery.docker` is scoped to this stack's own containers
(or containers with an explicit opt-in label). It does not blanket-discover every desktop container.
This is deliberate: financial-pipeline's live bank/investment adapters and fashion-monitor's scrapers
are never auto-logged until they are deliberately repointed at the shared stack in a separate follow-on
step (FR15 / out of scope).

## Deploy and verify

1. **From the Mac checkout:**
   ```bash
   ./compose/desktop/observability/deploy.sh
   ```
   Creates the `observability` service user on the desktop, installs sudoers entry, chowns bind-mount
   directories, rsyncs compose + config + dashboards, generates `GRAFANA_ADMIN_PASSWORD` if unset,
   seeds `.env` from `.env.example`, and brings up the stack.

2. **Verify on the desktop:**
   ```bash
   ssh desktop-agent
   sudo -u observability docker ps
   ```
   All six containers should show `healthy` in the STATUS column.

3. **Health endpoints:**
   - Prometheus: `curl http://10.0.0.243:9090/-/healthy`
   - Grafana: `curl http://10.0.0.243:3300/api/health`
   - Loki: `curl http://10.0.0.243:3100/ready`

4. **Prometheus targets:** Open `http://10.0.0.243:9090/targets` in a browser. node_exporter and
   cAdvisor should both show as `UP`; if either is `DOWN`, check the scrape error text.

5. **Grafana datasources:** Open `http://10.0.0.243:3300` (login with the generated admin password,
   found in `/opt/docker/observability/.env` on the desktop). Check Settings → Data sources: both
   Prometheus and Loki should show green checkmarks and say "Data source is working".

6. **Dashboards:** The imported dashboards should load and display data from this stack's Prometheus/Loki.

## Retention and resource limits

**Retention:**
- Prometheus: 15 days or 5 GB, whichever is reached first (set via CLI flags `--storage.tsdb.retention.time` and `--storage.tsdb.retention.size`).
- Loki: 336 hours (14 days) via compactor settings in `loki-config.yml`.

These are conservative infra-hygiene defaults, not a long-term retention *policy* (policy is out of scope
per requirements). They protect the desktop from unbounded disk growth, especially once FR13 consumers
attach and add log volume.

**Resource limits:** Every service has explicit `mem_limit` and `cpus` constraints in `docker-compose.yml`,
following the `scraper-egress` precedent. The exact idle-usage ceiling is TBD — spot-check `docker stats`
post-deploy and tune if needed given the desktop's other workloads (Plex, ollama broker, GPU gaming).

## Files

- `docker-compose.yml` — all six services with explicit `container_name:`, user pinning, bind mounts, healthchecks, resource limits, networking.
- `.env.example` — config template; the live `.env` (secrets, passwords) is desktop-only, git-ignored, `chmod 0600`.
- `deploy.sh` — run from the Mac checkout; creates service user + sudoers, chowns directories, rsyncs to desktop, generates admin password.
- `alloy/config.alloy` — River-syntax Alloy pipeline: logs-only (docker discovery + Loki shipping).
- `prometheus/prometheus.yml` — scrape jobs for self, node_exporter, cAdvisor.
- `loki/loki-config.yml` — server/storage/limits config including retention.
- `grafana/provisioning/datasources/datasources.yml` — Prometheus and Loki datasources with fixed UIDs.
- `grafana/provisioning/dashboards/dashboards.yml` — dashboard provider pointing at `dashboards/`.
- `dashboards/*.json` — provisioned dashboard JSON (exported/imported from old instances).

## Status

Deployed and verified on the desktop (2026-07-19).
