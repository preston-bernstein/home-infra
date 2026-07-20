---
name: observability-stack-verify
description: How to smoke-check the shared observability stack (Prometheus+Grafana+Loki+Alloy) after a change. Load when verifying a deploy to compose/desktop/observability/.
---

# Observability stack — verify

No test suite (matches repo-wide `home-infra-validation-and-qa` philosophy: numbers/live checks, never "looks fine").

Grafana admin password: `sudo cat /opt/docker/observability/.env` on desktop-agent (never echo it in chat/commits).

## Smoke sequence
1. `ssh desktop-agent "sudo docker ps --filter 'name=observability-' --format 'table {{.Names}}\t{{.Status}}'"` — all six `healthy`.
2. Prometheus targets, real UI: `http://10.0.0.243:9090/targets` — cadvisor/node-exporter/prometheus all `UP`. If this ever shows only `prometheus` self-scrape, the direct-scrape wiring in `prometheus.yml` broke — do NOT reintroduce Alloy remote-write, that was a deliberate fix (see ADR 0016).
3. Grafana UI login: `http://10.0.0.243:3300`, admin + password from `.env`. Check `/api/datasources` returns exactly 2 (fixed uids `prometheus`/`loki`).
4. Loki scope check (critical — this caught a real data leak once): `curl http://10.0.0.243:3100/loki/api/v1/label/compose_project/values` must return ONLY `["observability"]`. Any other project name means Alloy's `discovery.relabel` output filter regressed — stop and fix before it ships more containers' logs.
5. Restart idempotency: `docker compose down && up -d` as the `observability` user → datasource/dashboard counts must stay the same across the cycle.

## Known gap
`fashion-monitor.json` dashboard uses `frser-sqlite-datasource`, not installed here — renders as a silently blank page (check browser console for `PanelQueryRunner Error`, not a visible banner). Flagged to Preston, not yet resolved either direction.
