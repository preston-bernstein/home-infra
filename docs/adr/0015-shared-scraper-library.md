# 0015 — Shared scraper library (imported code, not copied)

**Status:** Accepted (2026-07-18) — home established, implemented incrementally on first use.

## Context

Several projects will run real scrapers (algo-factory's social-sentiment leads,
estate-scraper, resale-inventory, fashion-monitor, social-growth-bot). Beyond the network
**egress isolation** — which is a shared *service* (ADR 0014, attach via
`network_mode: service:egress-gateway`) — those scrapers will each need the same *code*:

- a **stealth browser** wrapper (Playwright + anti-detection: fingerprint/UA/webdriver/WebRTC),
- a **rate governor** (low, steady request pacing),
- a **stop-on-cease-and-desist** rail (halt a platform's collector on a C&D or hard block —
  never auto-rotate to evade; the one CFAA tripwire),
- a small **egress-attach helper** / config for the shared gateway,
- logged-out/public-only fetch helpers.

If each product repo reimplements these, they drift and the legal/opsec discipline
(ADR 0014, CONVENTIONS §7) gets applied inconsistently. This is the exact
"under-modularization" risk: the same code copy-pasted across product repos.

None of this code exists yet — the egress harness deliberately scoped all of it OUT. So this
is a decision about **where it will live when it's built**, made now to prevent copy-paste.

## Decision

Cross-project scraper **code** lives in a single shared library, `scraper-commons`
(`~/dev/scraper-commons`), **imported and versioned** — not copied between product repos.

- It is a **library** (imported), distinct from the egress **service** (attached to, ADR 0014).
  A project uses both: it *imports* `scraper-commons` for stealth/rate/C&D and *attaches* its
  container to the egress gateway.
- **Implemented incrementally, on first real use.** The library's module boundaries + contract
  are defined now (`scraper-commons/CONTRACT.md`); each module is implemented when the first
  scraper actually needs it — extracted from that first real implementation, not written
  speculatively against an imagined interface.
- The legal/opsec discipline (logged-out, slow, stop-on-C&D, isolated egress) is encoded **in
  the library** so every consumer inherits it by construction, not by remembering to.

## Consequences

- **Positive:** one place for the scraper discipline; no per-repo drift; the first scraper
  seeds the shared code, the second imports it.
- **Deliberately deferred:** no speculative implementation now — an empty contract beats a
  wrong interface built with no consumer (YAGNI). The skeleton exists so there's an obvious
  home and the first scraper knows to extract-not-inline.
- **Split with ADR 0014 is the point:** deployed-once-consumed-at-runtime → `home-infra`
  service; imported-code → `scraper-commons` library. Conflating them is what put the egress
  harness in the wrong repo originally.

## Status / next

`~/dev/scraper-commons` scaffolded (README + CONTRACT.md + pyproject, no implementation).
First mover: whichever of the social-sentiment scrapers (algo-factory Reddit/YouTube leads)
ships first implements the stealth + rate + C&D modules there and imports them, rather than
writing them inline. Local git repo only for now — publish/remote when convenient.
