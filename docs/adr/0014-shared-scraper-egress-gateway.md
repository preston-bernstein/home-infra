# 0014 — Shared scraper egress gateway (one VPN tunnel, many scrapers)

**Status:** Accepted (2026-07-18)

## Context

Multiple projects scrape public web data (algo-factory's social-sentiment leads,
estate-scraper, resale-inventory, fashion-monitor, social-growth-bot). They run on the
desktop, which also hosts the **Kalshi real-money executor** and the financial pipeline
on the desktop's real WAN IP. A scrape-induced IP ban or rate-flag on that shared IP would
put the trading infra at risk.

The desktop already runs a proven gluetun + ProtonVPN kill-switch for the arr-stack torrent
downloaders (`/opt/docker/arr-stack`). The first scraper egress harness was built via
algo-factory's `/ship-it` and initially landed inside the `algo-factory` repo — the wrong
home for a cross-cutting concern that several unrelated projects need.

## Decision

Adopt a **single shared egress gateway** as a `home-infra`-owned desktop service, not a
per-project copy or an imported library:

- One `gluetun-scraper` container (`egress-gateway`), deployed once from
  `home-infra/compose/desktop/scraper-egress/`.
- A **second, independent** ProtonVPN tunnel with its own exit IP (distinct
  `SERVER_COUNTRIES` from the arr-stack tunnel), fail-closed (`FIREWALL=on`).
- Consumers — in any repo — attach at runtime via `network_mode: service:egress-gateway`
  + `depends_on: condition: service_healthy`. No VPN config crosses into a consumer.
- Runs under a dedicated `scraper-egress` nologin user with a **narrow sudoers grant**
  (never `docker`-group membership, which is host-root-equivalent and would defeat the
  isolation).

This is the **shared-service** half of a deliberate split: cross-cutting things that are
*deployed once and consumed at runtime* live in `home-infra` and are attached to, never
imported. Cross-cutting *code* (a future Playwright-stealth / rate-governor / stop-on-C&D
scraper library) is the separate **shared-library** half and lives elsewhere, imported and
versioned — see `docs/adr/0015`.

## Consequences

- **Positive:** zero duplication of the isolation across scraper projects; one place to
  harden, rotate, and leak-test; the trading infra's egress is never shared with scraping.
- **Positive:** projects stay decoupled from the VPN backend (ProtonVPN → Mullvad, or
  OpenVPN → WireGuard) — a backend swap never touches a consumer.
- **Trade-off (same-account tunnel):** reusing the arr-stack ProtonVPN account means a
  scraping-triggered account flag could also drop the torrent tunnel. Verified empirically
  that two concurrent tunnels on the account work; a separate account is the escape hatch if
  that ever bites.
- **Caveat:** the `network_mode: service:` contract is VPN-tunnel-shaped. A residential-proxy
  backend is NOT a drop-in swap — it needs a transparent-proxy shim (documented in
  `consumer-contract.md`).
- **Follow-up:** each existing scraper project migrates its egress to attach to this gateway
  as it next ships scraper work; until a project attaches, nothing changes for it.

## Verification

Deployed + leak-tested 4/4 on the desktop 2026-07-18 (exit IP ≠ desktop WAN ≠ arr-stack
exit; DNS resolves through the tunnel; fail-closed holds when the tunnel is killed).
