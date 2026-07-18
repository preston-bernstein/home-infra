# Consumer Contract: Scraper Egress Gateway

## How a future scraper attaches

Any future scraper container consuming the `egress-gateway` tunnel attaches via the following compose schema:

```yaml
services:
  reddit-scraper:
    image: some/scraper-image
    network_mode: "service:egress-gateway"
    depends_on:
      egress-gateway:
        condition: service_healthy
    mem_limit: "512m"
    cpus: "0.5"
    # … other config specific to the scraper image …
```

**Key contract points:**
- `network_mode: "service:egress-gateway"` — attaches to the egress-gateway container's network namespace, routing all egress through the tunnel.
- `depends_on: egress-gateway: condition: service_healthy` — gates container startup on the tunnel being up and verified (not merely the process starting, but `HEALTH_TARGET_ADDRESS` confirming real connectivity).
- `mem_limit` and `cpus` — **required** on every consumer. The desktop host also runs live real-money Kalshi orders; each consumer must declare resource bounds so a runaway scraper workload cannot starve the executor. Set conservatively for your scraper's actual needs.

## Explicit: No VPN variables in consumer

**No `VPN_*`, `PROTON_*`, or `SERVER_COUNTRIES` variables appear in the consumer's own service definition.** These belong only in the `egress-gateway` service and its backing `.env` file, never in consumer config. This isolation satisfies the backend-swap requirement (FR6): a consumer service definition never mentions ProtonVPN by name and does not couple to that backend's implementation.

## Backend-swap guarantee (scoped honestly)

**Swapping VPN backends requires no consumer change:** ProtonVPN ↔ Mullvad, OpenVPN ↔ WireGuard. Any change to those backends is entirely internal to the `egress-gateway` service definition and its `.env` file; a consumer's `network_mode: "service:egress-gateway"` line remains unchanged.

**Residential-proxy backends are NOT a drop-in swap.** A residential proxy is consumed via `HTTP_PROXY`/`SOCKS_PROXY` environment variables or via a transparent-redirect sidecar (Redsocks/Privoxy + iptables `REDIRECT`), never via `network_mode: service:`. If a future plan proposes swapping to a residential-proxy backend, that backend requires:
- Either explicit proxy env vars passed to the consumer, or
- A separate transparent-proxy shim container and sidecar configuration changes to consumers' routing.

This is a different architectural shape from the current VPN-tunnel model and cannot be a same-container-name drop-in swap. Document this decision explicitly at that time so no one discovers the mismatch mid-migration.

## Out of scope

The following are explicitly out of scope for this harness:

- **Scraper implementations** — actual Reddit public-JSON, YouTube transcripts, or other platform scrapers.
- **Stealth browser layer** — Patchright or any browser-automation component.
- **Cease-and-desist halt rail** — rate-limiting or request-termination logic triggered by legal/abuse signals.
- **Rate governor** — request-pacing or concurrency control logic.
- **Residential-proxy backend implementation** — only the future swap-in point is documented above; the backend itself is not built here.

## Design rationale

For the architectural rationale behind this isolated tunnel design and the VPN-backend-swap primitives, see the Obsidian vault: `Development/Research/insulated-scraping-architecture.md`.
