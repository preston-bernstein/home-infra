# Steps: Shared Observability Stack

## Prerequisites
- Local clones of `financial-pipeline` and `fashion-monitor` repos must exist at known paths on the local machine (e.g., `~/dev/financial-pipeline`, `~/dev/fashion-monitor`) — needed for step 6d's `git status` verification to confirm those repos remain unmodified.
- Admin credential or API token for `fashion-monitor-grafana-1` (port 3001) and `financial-pipeline-grafana-1` (port 3200) must be available locally — needed for step 2's dashboard export via Grafana HTTP API.
- The feature adds new infrastructure; legacy Grafana and Loki instances on the desktop remain running throughout. No prior feature completion required; home-infra repo clone and desktop SSH access (as `agent` user per CLAUDE.md home-lab section) are assumed present.

## Implementation steps

### Step 1a: Create core configuration files (docker-compose.yml, metrics/logging configs)
**What**: Write docker-compose.yml, .env.example, prometheus.yml, loki-config.yml, and Grafana provisioning configs (datasources and dashboards provider). These are the foundational infra configs; Alloy's River pipeline config is separated into step 1b.

**Files**: `compose/desktop/observability/docker-compose.yml`, `compose/desktop/observability/.env.example`, `compose/desktop/observability/prometheus/prometheus.yml`, `compose/desktop/observability/loki/loki-config.yml`, `compose/desktop/observability/grafana/provisioning/datasources/datasources.yml`, `compose/desktop/observability/grafana/provisioning/dashboards/dashboards.yml`.

**Test**: 
- All YAML files are syntactically valid (`yamllint` or `python -c "import yaml; yaml.safe_load(open('file.yml'))"` for each).
- docker-compose.yml can be validated with `docker compose config` (requires Docker, safe to run on any machine).
- datasources.yml defines two datasources with fixed `uid:` values: `prometheus` (type: prometheus, URL: `http://prometheus:9090`) and `loki` (type: loki, URL: `http://loki:3100`); no template variables (`${DS_*}`).
- prometheus.yml includes retention config and self-scrape job; remote-write receiver enabled via CLI flag (not this file).
- loki-config.yml includes retention config.
- All services in docker-compose.yml (prometheus, grafana, loki, node-exporter, cadvisor) that are NOT cAdvisor or Alloy define `user:` field pinned to `${PUID}:${PGID}` (cAdvisor and Alloy omit this, per docker.sock access requirements).
- Every service defines resource limits (mem_limit/cpus) with conservative non-zero values; exact numbers flagged for Preston to tune.
- healthchecks defined per service.

**Depends on**: None.

**Parallelizable**: Yes.

### Step 1b: Create Alloy River pipeline configuration
**What**: Write `alloy/config.alloy` — Grafana Alloy's River-syntax pipeline config. Alloy is logs-only in this stack (Prometheus now scrapes node_exporter/cAdvisor directly); Alloy's `discovery.docker` + `loki.source.docker` + `loki.write` handles Docker log shipping to Loki, with cardinality relabeling to prevent label explosion from container diversity.

**Files**: `compose/desktop/observability/alloy/config.alloy`.

**Test**:
- `alloy/config.alloy` is syntactically valid River: run `docker run --rm -v $(pwd)/alloy/config.alloy:/config.alloy grafana/alloy:<pinned-tag> alloy fmt /config.alloy` to validate (not visual inspection).
- Config includes `discovery.docker`, `loki.source.docker`, and `loki.write` components; cardinality relabeling applied to prevent unbounded label growth from container names/labels.
- Alloy container in docker-compose.yml does NOT include `user:` field (docker.sock access requirement).

**Depends on**: None.

**Parallelizable**: Yes (independent of 1a; both are foundational).

### Step 2: Export dashboards from legacy Grafana instances and prepare for import
**What**: Using stored admin credentials/API token, fetch all dashboards from `fashion-monitor-grafana-1` (:3001) and `financial-pipeline-grafana-1` (:3200) via Grafana HTTP API, strip any embedded alert-rule or contact-point blocks, re-point panel datasource UIDs to match new stack's provisioned datasource identifiers (literal fixed UIDs from step 1a: `prometheus`, `loki`; no `${DS_*}` template variables), place finalized JSON files under `compose/desktop/observability/dashboards/`.

**Files**: `compose/desktop/observability/dashboards/*.json` (one JSON file per exported dashboard, with datasource references updated and alert blocks removed).

**Test**:
- All dashboard JSON files are valid JSON (`jq empty dashboards/*.json` passes for each file).
- Verify no two exported dashboards share the same UID (de-duplicate/rename if necessary).
- Each dashboard's panels reference datasource UIDs `prometheus` or `loki` (literal, hardcoded — no `${DS_*}` template variables).
- Verify any embedded `alert`, `alerting`, `alerts`, or `rules` blocks are stripped from the exported JSON (no Alertmanager is deployed in this stack).
- Grafana provisioning dashboard discovery can parse the files (no syntax errors that would prevent Grafana from loading them).

**Depends on**: 1a (datasources.yml must define the final fixed UIDs first).

**Parallelizable**: No.

### Step 3a: Create deploy.sh and associated deployment tooling
**What**: Write `deploy.sh` (service-user creation via `useradd`, sudoers installation with `visudo -c` pre-activation validation, recursive rsync of all subdirectories to desktop, .env seeding with captured real UID/GID and random Grafana admin password generation).

**Files**: `compose/desktop/observability/deploy.sh`.

**Test**:
- `deploy.sh` is executable (`chmod +x` already applied, `file deploy.sh` shows shell script).
- `deploy.sh` references correct file paths: rsync sources include all of Steps 1a, 1b, and 2's files (docker-compose.yml, .env.example, prometheus/, alloy/, grafana/, loki/, dashboards/); destination is `/opt/docker/observability/`.
- Post-useradd, `deploy.sh` captures real `id -u observability` and `id -g observability` values and writes them to `.env` as `PUID` and `PGID` (so compose variables resolve correctly).
- If `.env` does not already define `GRAFANA_ADMIN_PASSWORD`, `deploy.sh` generates a random 32-character password and writes it to `.env`.
- `.env` is written with mode 0600 on the desktop (readable only by owner).
- Sudoers installation: `deploy.sh` writes the sudoers entry to `/etc/sudoers.d/observability`, then validates it with `sudo visudo -c -f /etc/sudoers.d/observability` (must pass before file is considered active; failed validation means file was never installed).
- Successful rsync: `ls -la /opt/docker/observability/` shows docker-compose.yml, .env, prometheus/, alloy/, grafana/, dashboards/, loki/ directories and files, with ownership `observability:observability`.

**Depends on**: 1a, 1b, 2 (all config/dashboard files must be finalized before rsync sources are locked down).

**Parallelizable**: No.

### Step 3b: Create documentation and architecture decision record
**What**: Write `README.md` (port table, six-container overview, attach contract for consumer repos, dashboard-provisioning explanation, deploy/verify steps) and `docs/adr/0016-shared-observability-stack.md` (decision record following ADR 0014 precedent).

**Files**: `compose/desktop/observability/README.md`, `docs/adr/0016-shared-observability-stack.md`.

**Test**:
- `README.md` documents Grafana port as 3300 (distinct from 3001/3200), explains all six services, describes attach contract (Prometheus remote-write receiver at `10.0.0.243:9090` — note: Prometheus now scrapes node_exporter/cAdvisor directly, no longer receives metrics from Alloy; Loki push API at `10.0.0.243:3100`), includes deploy and verify steps.
- ADR 0016 follows org format (Status/Context/Decision/Consequences), references ADR 0014, documents decision to consolidate duplicate stacks, clarifies that Alloy now handles logs-only (Prometheus direct scrape for metrics).

**Depends on**: None (documentation, genuinely parallel to 3a).

**Parallelizable**: Yes (parallel to 3a; does not block or depend on deploy.sh logic).

### Step 4: Deploy to desktop and provision infrastructure (run deploy.sh)
**What**: Run `deploy.sh` from the Mac checkout to create `observability` nologin service user on desktop, install `/etc/sudoers.d/observability` grants with `visudo -c` validation, rsync compose/provisioning/dashboard/metrics/logging files to `/opt/docker/observability/`, seed `.env` with real UID/GID and random Grafana password.

**Files**: On desktop: `/opt/docker/observability/` directory tree (docker-compose.yml, .env, prometheus/, alloy/, grafana/, loki/, dashboards/), `/etc/passwd` entry for `observability` user, `/etc/sudoers.d/observability` file, `/var/lib/observability/` (home directory for service user).

**Test**:
- SSH to desktop (`ssh desktop-agent`).
- `id observability` returns UID/GID (e.g., `uid=999(observability) gid=999(observability) groups=999(observability)`).
- `groups observability` shows only `observability`, no `docker` group.
- `cat /etc/sudoers.d/observability` exists and grants `docker compose -f /opt/docker/observability/docker-compose.yml *` to `observability` user (scoped sudoers grant, not `ALL`).
- `ls -la /opt/docker/observability/` shows docker-compose.yml, .env, prometheus/, alloy/, grafana/, loki/, dashboards/ directories and files, with ownership `observability:observability`.
- `.env` file exists, contains `PUID` and `PGID` set to the captured `observability` UID/GID (not assumed defaults), and contains `GRAFANA_ADMIN_PASSWORD` set to a random value (if it was not already present).
- `.env` is readable only by owner: `ls -l /opt/docker/observability/.env` shows mode 0600.

**Depends on**: 1a, 1b, 2, 3a (deploy.sh logic, which depends on finalized configs and dashboard files; 3b is parallel and does not block this).

**Parallelizable**: No.

### Step 5: Start observability stack and verify container health
**What**: SSH to desktop, use sudoers-scoped `docker compose` to bring up all six containers, wait for health checks to pass, verify all services are running.

**Files**: Docker bind mounts and named volumes created automatically on first `up` (exact mount type per docker-compose.yml definition).

**Test**:
- `sudo -u observability docker compose -f /opt/docker/observability/docker-compose.yml ps` shows all six services: `prometheus`, `grafana`, `loki`, `alloy`, `node-exporter`, `cadvisor`, with status `Up` and health `healthy` (or no health check if not defined, but all should be `Up`).
- No error logs in `docker logs <container>` for any of the six (spot-check: `sudo -u observability docker logs observability-grafana-1 | head -20` should show startup messages, not errors).
- Ports are reachable: `curl -s http://localhost:9090/api/v1/query?query=up` returns JSON (Prometheus); `curl -s http://localhost:3300/api/health` returns JSON (Grafana); `curl -s http://localhost:3100/loki/api/v1/status` returns JSON (Loki).

**Depends on**: Step 4 (infrastructure must be provisioned first).

**Parallelizable**: No.

### Step 6a: Verify static configuration and service definitions
**What**: Verify all container definitions, secrets handling, file layout, container health checks, Prometheus targets (node_exporter and cAdvisor) showing UP via direct scrape, and Grafana datasources with fixed UIDs.

**Files**: No new files created.

**Test**:
- **AC1**: `docker inspect observability-prometheus-1 | jq '.Config.User'` shows `999:999` (PUID:PGID), matching `observability` user. Repeat for `grafana`, `loki`, `node-exporter`, but NOT for `alloy` or `cadvisor` (those do not have `user:` field due to docker.sock requirement). Verify only four of six services have pinned user.
- **AC2**: `git show HEAD:.env.example | grep -i password` shows placeholder values like `GRAFANA_ADMIN_PASSWORD=changeme`, no real credentials.
- **AC3**: `test -f compose/desktop/observability/deploy.sh && test -f compose/desktop/observability/README.md` succeeds.
- **AC4**: `sudo -u observability docker compose -f /opt/docker/observability/docker-compose.yml ps --format "table {{.Service}}\t{{.Status}}"` shows all six services as `Up`.
- **AC5**: `curl -s http://localhost:9090/api/v1/targets | jq '.data.activeTargets[] | {job: .labels.job, state: .health}'` shows `node-exporter` and `cadvisor` targets with `state: "up"` (Prometheus now scrapes these directly, not via Alloy remote-write).
- **AC6**: `curl -s http://localhost:3300/api/datasources | jq '.[] | {name, type, uid}'` shows exactly two datasources: one with `type: prometheus`, `name: "Prometheus"`, `uid: "prometheus"` (literal fixed UID), and one with `type: loki`, `name: "Loki"`, `uid: "loki"` (literal fixed UID).

**Depends on**: Step 5 (stack must be running to inspect container config and query API endpoints).

**Parallelizable**: No.

### Step 6b: Verify data-flow correctness and dashboard rendering
**What**: Verify dashboard rendering with data, Loki log ingestion, and datasource connectivity per the concrete checklist.

**Files**: No new files created.

**Test**:
- For each provisioned dashboard (retrieved from `compose/desktop/observability/dashboards/`), perform the following checks in Grafana UI (`http://10.0.0.243:3300`):
  - (a) Query Grafana API: `GET /api/dashboards/uid/{dashboard_uid}` returns HTTP 200 (dashboard JSON).
  - (b) Inspect each panel's `datasource` field: it must resolve to an existing datasource (uid `prometheus` or `loki`, matching step 1a's provisioned datasources). No "datasource not found" errors.
  - (c) At least one panel in each dashboard returns non-empty query results when queried (spot-check via the panel's "Query Inspector" or by checking the response to the underlying PromQL/LogQL query).
- **AC7**: Navigate to Grafana UI, load each exported dashboard, verify the above. Panels render without datasource errors, metrics/logs visible in visualizations.
- **AC8**: In Grafana Explore (Loki datasource), query with label selector `{job="docker"}` or similar; should return log entries from running desktop containers (or via direct API: `curl -s 'http://localhost:3100/loki/api/v1/query_range?query={job%3D%22docker%22}&start=<unix-timestamp-1-hour-ago>&end=<now>'` returns non-empty log entries).

**Depends on**: Step 6a (config checks must pass first).

**Parallelizable**: No.

### Step 6c: Verify persistence and idempotency across restart
**What**: Verify that restarting the full observability stack preserves Prometheus metrics, Grafana dashboards, and Loki logs without manual re-provisioning. Also verify that re-running deploy.sh is idempotent (no duplicate dashboards/datasources).

**Files**: No new files created.

**Test**:
- Record a sample metric value from Prometheus before restart (e.g., `curl -s http://localhost:9090/api/v1/query?query=up | jq '.data.result[0].value'` to capture a recent data point).
- Record a list of dashboards and datasources before restart: `curl -s http://localhost:3300/api/datasources | jq 'length'` (should be 2), `curl -s http://localhost:3300/api/search?type=dash-db | jq 'length'` (note the dashboard count).
- **AC9a** (restart test): `sudo -u observability docker compose -f /opt/docker/observability/docker-compose.yml down`, then `up -d`, wait for health checks to pass.
- Verify containers restart healthy: `sudo -u observability docker compose -f /opt/docker/observability/docker-compose.yml ps` shows all six as `Up`.
- Verify Prometheus metrics persist: query the same metric again and confirm the previous data point is still present in the time-series history.
- Verify Grafana dashboards persist: `curl -s http://localhost:3300/api/datasources | jq 'length'` returns 2 (no duplicate datasources created); dashboard count is unchanged from pre-restart.
- **AC9b** (idempotency check): On the desktop, re-run `sudo /opt/docker/observability/deploy.sh` (or the equivalent deployment command from the Mac). Verify that:
  - No new dashboards are created (dashboard count remains the same).
  - No duplicate datasources are created (`curl -s http://localhost:3300/api/datasources | jq 'length'` still returns 2, with no duplicate "Prometheus" or "Loki" entries).
  - Sudoers file re-install passes `visudo -c` validation without errors.

**Depends on**: Step 6b (data-flow must be functional first).

**Parallelizable**: No.

### Step 6d: Verify legacy stack immutability and absence of side effects
**What**: Verify that throughout the build and verification, the legacy Grafana/Loki instances (fashion-monitor-grafana-1, financial-pipeline-grafana-1, financial-pipeline-loki-1) remain running unmodified, and financial-pipeline/fashion-monitor repos show no configuration changes.

**Files**: No new files created.

**Test**:
- **AC10**: Service-user isolation check: `id observability` shows no `docker` in groups; `sudo cat /etc/sudoers.d/observability` shows scoped grant (e.g., `observability ALL=(ALL) NOPASSWD: /usr/bin/docker compose -f /opt/docker/observability/docker-compose.yml *`), not an open `ALL` grant.
- **AC11**: Legacy stack immutability:
  - SSH to desktop (`ssh desktop-agent`).
  - `docker ps --filter "name=fashion-monitor" --format "{{.Names}}\t{{.Status}}"` shows `fashion-monitor-grafana-1` running (status `Up`).
  - `docker ps --filter "name=financial-pipeline" --format "{{.Names}}\t{{.Status}}"` shows both `financial-pipeline-grafana-1` and `financial-pipeline-loki-1` running (status `Up`).
  - Verify repos remain unmodified: On the local machine (or SSH to desktop and check), `cd /path/to/financial-pipeline && git status` shows no changes (all tracked files unmodified; data adapters, materializer, Postgres container definition all unchanged). `cd /path/to/fashion-monitor && git status` shows no changes.

**Depends on**: Step 6c (all prior verifications must pass).

**Parallelizable**: No.

## Rollback plan

**Steps 1a–3b** (local file creation and documentation): All reversible via `git checkout` or `git reset` (no state on desktop yet). No rollback action needed.

**Step 3a failure** (sudoers validation): If `visudo -c -f /etc/sudoers.d/observability` fails during step 3a's pre-activation check, the sudoers file is NOT installed to `/etc/sudoers.d/` (deploy.sh should refuse to proceed). This is safe; no partial state exists on the desktop. Fix the sudoers syntax in `compose/desktop/observability/deploy.sh`, re-run `deploy.sh`, and the validation will pass on the second attempt.

**Step 4** (desktop infrastructure): Service-user and sudoers entries are idempotent (re-running deploy.sh is safe). To fully rollback: SSH to desktop, `userdel -r observability` (removes user and home directory), `rm /etc/sudoers.d/observability`. Then `rm -rf /opt/docker/observability/`. This leaves no trace of the deployment.

**Step 5** (container startup): `sudo -u observability docker compose -f /opt/docker/observability/docker-compose.yml down -v` removes all containers and volumes. Recoverable via restarting step 5 (volumes recreated on `up -d`). To fully remove: combine with Step 4 rollback above.

**Step 6c failure** (restart test): If the stack does not come back healthy after the `down && up -d` restart (e.g., a container fails to start or a health check fails), check `sudo -u observability docker compose -f /opt/docker/observability/docker-compose.yml logs <service>` per-service to identify the failure (e.g., Alloy's docker.sock connection issue, Prometheus remote-write receiver config error). Fix the root cause in the repo's config files (steps 1a–1b), re-run deploy.sh (step 4), and retry the restart (step 6c). In a worst-case scenario where data corruption is suspected: `sudo -u observability docker compose -f /opt/docker/observability/docker-compose.yml down -v` (destroys all volumes, losing collected metrics/logs since initial deploy — acceptable for an initial verification build), then redeploy from step 3a/4 onward. Historical data loss is limited to metrics/logs collected between the initial deploy and the restart failure.

**Steps 6a–6d** (verification): Read-only; no rollback needed (except for the data-preservation implications of 6c failure above).

If issues are discovered during verification (steps 6a–6d) that require config changes (e.g., Alloy config syntax error, datasource UID mismatch), edit the config files in the repo (steps 1a–1b), rerun deploy.sh with the updated files (step 4), and restart the stack (step 5). All data persists in Docker volumes across redeploy, so no loss of historical metrics/logs (unless a destructive `down -v` is performed).

If complete rollback is needed: userdel + sudoers + /opt/docker removal (above), then `git reset` any local file changes. No data loss outside `/opt/docker/observability/` volumes.
