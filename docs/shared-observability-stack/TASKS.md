# Tasks: Shared Observability Stack

Generated from: docs/shared-observability-stack/ on 2026-07-19

## Status legend
- [ ] pending
- [>] in progress
- [x] done
- [!] blocked

## Tasks

### Task 1a: Create core configuration files (docker-compose.yml, metrics/logging configs)
**Status**: [x] done
**Files**: compose/desktop/observability/docker-compose.yml, compose/desktop/observability/.env.example, compose/desktop/observability/prometheus/prometheus.yml, compose/desktop/observability/loki/loki-config.yml, compose/desktop/observability/grafana/provisioning/datasources/datasources.yml, compose/desktop/observability/grafana/provisioning/dashboards/dashboards.yml
**Test**: YAML valid; docker-compose.yml validates with `docker compose config`; datasources.yml has fixed uid: prometheus/loki; prometheus.yml has retention+self-scrape; loki-config.yml has retention; user: pin on prometheus/grafana/loki/node-exporter only; resource limits + healthchecks on all services
**Depends on**: none
**Parallelizable**: Yes
**Notes**:

### Task 1b: Create Alloy River pipeline configuration
**Status**: [x] done
**Notes**: syntax validation via `alloy fmt` could not be run in the agent's environment — must validate during Task 4/5 deployment.
**Files**: compose/desktop/observability/alloy/config.alloy
**Test**: `alloy fmt` validates the config; discovery.docker + loki.source.docker + loki.write present with cardinality relabeling; no user: field on alloy container
**Depends on**: none
**Parallelizable**: Yes
**Notes**:

### Task 2: Export dashboards from legacy Grafana instances
**Status**: [x] done
**Notes**: financial-pipeline-grafana-1 has zero dashboards (verified live, not an auth failure). fm-logs.json is Loki-backed, cleanly repointed to uid `loki` — fully renders under AC7. fashion-monitor.json unexpectedly uses the `frser-sqlite-datasource` plugin querying fashion-monitor's own app SQLite DB directly, not Prometheus/Loki — no equivalent exists in the shared stack without installing a SQLite plugin + bind-mounting fashion-monitor's live DB file into observability's Grafana, which is new cross-repo coupling not in the approved scope. Kept the file in the repo unmodified/unrepointed; flagged as a deferred gap against AC7, not silently faked as working.
**Files**: compose/desktop/observability/dashboards/*.json
**Test**: valid JSON; no duplicate UIDs; panels reference literal `prometheus`/`loki` UIDs (no ${DS_*} vars); alert/alerting blocks stripped
**Depends on**: 1a
**Parallelizable**: No
**Notes**:

### Task 3a: Create deploy.sh
**Status**: [x] done
**Notes**: reviewed by orchestrator directly given sensitivity (creates system user, installs sudoers). Looks correct — idempotent, visudo pre-checked, narrow scoped grant, UID/GID capture, no secrets echoed.
**Files**: compose/desktop/observability/deploy.sh
**Test**: executable; recursive rsync of all subdirs; captures real UID/GID into .env; generates random Grafana password if absent; visudo -c validates sudoers before activation; .env mode 0600
**Depends on**: 1a, 1b, 2
**Parallelizable**: No
**Notes**:

### Task 3b: Create README.md and ADR 0016
**Status**: [x] done
**Files**: compose/desktop/observability/README.md, docs/adr/0016-shared-observability-stack.md
**Test**: README documents port table, six services, attach contract, docker.sock/user-pin reconciliation; ADR follows Status/Context/Decision/Consequences format, references ADR 0014
**Depends on**: none
**Parallelizable**: Yes
**Notes**:

### Task 4: Deploy to desktop (run deploy.sh)
**Status**: [x] done
**Notes**: found+fixed a real bug: grafana's dashboards bind mount was nested inside the read-only provisioning mount (Docker can't create a mountpoint inside an already-ro parent) — moved to a sibling path /etc/grafana/dashboards-data and updated dashboards.yml's provider path to match.
**Files**: (desktop state — /opt/docker/observability/, /etc/sudoers.d/observability, observability system user)
**Test**: id observability shows UID/GID; groups observability shows no docker group; sudoers file present and valid; /opt/docker/observability/ populated with correct ownership; .env has real PUID/PGID + generated password + mode 0600
**Depends on**: 1a, 1b, 2, 3a
**Parallelizable**: No
**Notes**:

### Task 5: Start stack and verify container health
**Status**: [x] done
**Notes**: found+fixed TWO real bugs during live deployment: (1) CRITICAL — Alloy's loki.source.docker was fed the raw unfiltered discovery.docker target list instead of discovery.relabel's filtered output, so it tailed EVERY desktop container's logs, not just this stack's own; confirmed leaked content from tdarr/ntfy actually landed in Loki. Stopped Alloy immediately, purged Loki's data directory, fixed config to use discovery.relabel.observability_containers.output as the targets arg, redeployed, and re-verified only observability's own 6 containers appear in Loki's labels — clean. (2) Alloy's image (Ubuntu 24.04 base) has no wget/curl, so its wget-based healthcheck always failed; switched to a bash /dev/tcp port-check. All six containers now healthy.
**Files**: (runtime — docker compose up on desktop)
**Test**: all six containers Up/healthy; no error logs; Prometheus/Grafana/Loki health endpoints respond
**Depends on**: 4
**Parallelizable**: No
**Notes**:

### Task 6a: Verify static configuration and service definitions (AC1-6)
**Status**: [x] done
**Notes**: all pass. AC5 confirms the direct-scrape architecture fix works (node-exporter+cadvisor show UP as real Prometheus targets, not remote-write series).
**Files**: (verification only)
**Test**: AC1 (user pin on 4 of 6 services), AC2 (.env.example placeholders only), AC3 (deploy.sh+README exist), AC4 (all six Up), AC5 (node-exporter/cadvisor UP via direct scrape), AC6 (2 datasources with fixed UIDs)
**Depends on**: 5
**Parallelizable**: No
**Notes**:

### Task 6b: Verify data-flow correctness and dashboard rendering (AC7-8)
**Status**: [x] done
**Notes**: HTTP 200 + datasource resolution PASS for fm-logs.json (loki uid resolves). fashion-monitor.json (SQLite-backed) has no matching datasource in this stack — known gap, already flagged in Task 2 notes. Non-empty data for fm-logs.json is empty right now because fashion-monitor's actual containers aren't repointed at this Loki yet — that's explicit out-of-scope follow-on work (FR16), not a build defect; confirmed the pipeline itself works end-to-end using the stack's own self-monitoring logs (AC8 passes cleanly for the stack's own 6 containers).
**Files**: (verification only)
**Test**: AC7 (dashboards HTTP 200, datasource resolves, non-empty data per dashboard), AC8 (Loki query returns log lines)
**Depends on**: 6a
**Parallelizable**: No
**Notes**:

### Task 6c: Verify persistence and idempotency across restart (AC9-10)
**Status**: [x] done
**Notes**: full down+up cycle: all six back healthy, datasource count (2) and dashboard count (2) unchanged, Prometheus metric history queryable immediately post-restart (bind-mount persistence confirmed). deploy.sh re-run confirmed idempotent (no re-seed, password untouched).
**Files**: (verification only)
**Test**: AC9 (restart preserves metrics/dashboards), AC10 (deploy.sh re-run twice leaves dashboard/datasource counts unchanged)
**Depends on**: 6b
**Parallelizable**: No
**Notes**:

### Task 6d: Verify legacy stack immutability (AC11-12)
**Status**: [x] done
**Notes**: observability user has no docker group, sudoers scoped correctly; cadvisor/alloy have direct ro socket mounts as designed. All three legacy containers still running unmodified. financial-pipeline and fashion-monitor repos show zero diff to any tracked file (only pre-existing unrelated untracked artifacts).
**Files**: (verification only)
**Test**: AC11 (observability user no docker group, sudoers scoped; cadvisor/alloy have direct socket mount), AC12 (legacy containers still running, financial-pipeline/fashion-monitor repos show no git diff)
**Depends on**: 6c
**Parallelizable**: No
**Notes**:

## Blocked / open
All 11 tasks complete. Two known, deliberately-scoped gaps (not blockers):
1. `fashion-monitor.json` (the SQLite-plugin-backed dashboard) has no equivalent datasource in this stack — would require installing the `frser-sqlite-datasource` Grafana plugin plus a new cross-repo bind mount to fashion-monitor's live SQLite DB file, which is materially larger/different scope than "shared Prometheus/Loki observability" and was never in the approved plan. Left unmodified in the repo, not silently faked as working.
2. AC7's "non-empty data" check for `fm-logs.json` can't be satisfied until fashion-monitor's containers are actually repointed at this shared stack (FR16 — explicit follow-on work, separate repo, out of scope this build). Dashboard loads and datasource resolves correctly; the pipeline is proven end-to-end using the stack's own self-monitoring logs.

Two real bugs found and fixed during live deployment (see Task 4/5 notes): a read-only-mount nesting error in the Grafana dashboards bind mount, and a critical Alloy discovery filter that shipped ALL desktop containers' logs (not just this stack's own) until fixed — confirmed leaked content purged from Loki before it could propagate further.
