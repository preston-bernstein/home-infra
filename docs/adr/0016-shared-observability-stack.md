# 0016 — Shared observability stack (one Prometheus/Grafana/Loki, many services)

**Status:** Accepted (2026-07-19)

## Context

Desktop-hosted services each run their own Grafana instance:

- `fashion-monitor-grafana-1` (port 3001) — service's own dashboards
- `financial-pipeline-grafana-1` (port 3200) — service's own dashboards
- `financial-pipeline-loki-1` — standalone Loki (no Prometheus anywhere)

This duplicates observability infrastructure per product repo: the same class of service
deployed multiple times, wasting desktop resources and leaving host + container metrics
(CPU, memory, disk, network) uncollected entirely — no Prometheus exists on the desktop
to scrape them.

Per home-infra's established shared-service pattern (ADR 0014), infrastructure that is
cross-cutting and deployed once should live in `home-infra`, not duplicated per repo.
This matters now because duplication is already a pattern (two duplicate Grafana instances
confirm it will keep recurring as new services are added) unless a shared stack exists to
attach to.

## Decision

Adopt a **single shared Prometheus + Grafana + Loki + Grafana Alloy stack** deployed once
in `home-infra/compose/desktop/observability/`, running under a dedicated `observability`
nologin service user, following the same pattern as ADR 0014 (scraper-egress gateway):

- **Prometheus** — time-series database for host + container metrics, running at `10.0.0.243:9090`.
- **Grafana** — dashboard UI at `10.0.0.243:3300` (distinct from 3001/3200).
- **Loki** — log aggregation at `10.0.0.243:3100`.
- **Grafana Alloy** — unified logs collector (not Grafana Agent, deprecated), scoped narrowly to Docker log discovery and shipping to Loki. **Alloy plays no role in metrics collection** — this is a deliberate design correction from an earlier `prometheus.remote_write` design.
- **node_exporter** + **cAdvisor** — metrics exporters scraped directly by Prometheus (standard pull model).

All six services are deployed as a single unit and consumed at runtime by product repos
(financial-pipeline, fashion-monitor, and future services) via a documented attach contract:
logs are push-based (point a consumer's Alloy/Promtail at `10.0.0.243:3100`); metrics are
pull-based (add a consumer's `/metrics` endpoint as a new scrape target in this stack's
`prometheus.yml` when the consumer actually attaches — separate follow-on work per FR15).

### Architecture correction: Prometheus direct scrape, not remote-write

The original spec considered a design where Prometheus collected metrics via Alloy's
`prometheus.remote_write` sender. This was revised during spec-challenge review:

- A `remote_write` receiver on Prometheus requires an unauthenticated write endpoint
  (`--web.enable-remote-write-receiver`), which accepts metric pushes from any client on
  the LAN with no auth — a cardinality-bomb/DoS vector never surfaced as a risk.
- More critically, this design makes Prometheus's `/targets` page empty (it shows no scrape
  targets when all metrics come through remote-write). AC5 ("targets page shows node_exporter
  and cAdvisor as UP") is architecturally impossible under remote-write and directly ties
  to the standard Prometheus pull model.

**Resolution:** Prometheus uses native `scrape_configs` with `static_configs` targets for
node_exporter and cAdvisor — the standard, documented way to do it. Alloy is used only for
what it's actually needed for: Docker log discovery and shipping to Loki.

## Consequences

- **Positive:** no more duplicated Grafana instances running per-repo; a single shared
  observability stack is the attach point for all desktop services going forward.
- **Positive:** host + container metrics are now collected for the first time (CPU, memory,
  disk, network, per-container isolation).
- **Positive:** future services can attach for both metrics and logs without standing up
  their own Prometheus/Grafana/Loki; attach is a small config change, not infrastructure
  duplication.
- **Trade-off:** Prometheus and Loki APIs are unauthenticated and host-published to the LAN
  (no auth in front). This is a documented, accepted tradeoff for single-operator + LAN-only
  use; full auth (Authentik/OIDC) is deferred and revisited per a follow-on ADR if the stack
  is ever exposed beyond the LAN.
- **Constraint:** the two legacy Grafana instances (`fashion-monitor-grafana-1`,
  `financial-pipeline-grafana-1`) and the legacy Loki instance (`financial-pipeline-loki-1`)
  stay running throughout this build and verification phase. They are not decommissioned,
  repointed, or modified in this phase. Repointing/decommissioning is explicit follow-on work
  in separate repos (financial-pipeline, fashion-monitor), scoped outside this feature and
  documented in requirements FR15 / out of scope.
- **Follow-up:** Each existing product repo (financial-pipeline, fashion-monitor) will
  eventually migrate its metrics/logs to point at the shared stack — a separate change in
  each repo, not part of this build.

## Reference

See ADR 0014 for the established shared-service pattern that this decision follows.
