# scraper-egress — shared VPN egress gateway for scrapers

A single gluetun + ProtonVPN container (`egress-gateway` / `gluetun-scraper`) with a
fail-closed kill-switch, deployed once on the desktop. **Any** project's scraper
(algo-factory, estate-scraper, resale-inventory, fashion-monitor, social-growth-bot, …)
attaches to this one running container so its traffic never egresses from the desktop's
real IP — the one the Kalshi real-money executor and financial pipeline share. A
scrape-induced IP ban lands on a throwaway VPN exit, not the trading/host infra.

**This is a shared service, not a library.** You do not copy or import it. You deploy it
once and consumers attach at runtime via a two-line contract:

```yaml
services:
  my-scraper:
    network_mode: "service:egress-gateway"
    depends_on:
      egress-gateway:
        condition: service_healthy
```

No VPN/ProtonVPN vars ever appear in a consumer's own definition — swapping the VPN
backend never touches a consumer. Full contract + the honest residential-proxy caveat:
`consumer-contract.md`.

## Files
- `docker-compose.yml` — the gluetun service (no published ports, own bridge netns, resource limits).
- `.env.example` — config template; the live `.env` (secrets) is desktop-only, git-ignored, chmod 600.
- `deploy.sh` — run from this Mac checkout; creates the service user + narrow sudoers grant (never docker-group), syncs runtime files to the desktop.
- `leak-test.sh` — 4-assertion isolation proof (exit IP ≠ host, ≠ arr-stack; DNS through tunnel; fail-closed). Deployed alongside the stack; run as root on the desktop.
- `deploy-and-rotate.md` — the desktop runbook (deploy, credential entry, bring-up, rotation, verification).
- `design/` — the build record: hardened spec + the 7-agent adversarial review that shaped it.

## Status
Deployed + verified (leak-test 4/4) on the desktop 2026-07-18. Reuses the arr-stack
ProtonVPN account, Netherlands exit (retune `SERVER_COUNTRIES` per a consumer's geo needs).
Built via algo-factory's `/ship-it`; moved here 2026-07-18 to be the shared home
(see `../../../docs/adr/0014-shared-scraper-egress-gateway.md`).
