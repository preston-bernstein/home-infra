# home-infra

Infrastructure-as-config for Preston Bernstein's home lab: Docker Compose
stacks for a personal AI assistant (LibreChat + RAG + MCP servers), the
shared cross-project egress gateway scrapers attach to, and the
cross-cutting operational conventions every other home-lab repo links back
to.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

## What lives here

This repo hosts **shared services** (deployed once, consumed at runtime by
other repos via a network/API contract) and the **conventions** that keep
those other repos consistent — not any single product's application code.
Shared *libraries* (imported and versioned as code) live in their own repos
instead — see [`docs/adr/0015-shared-scraper-library.md`](docs/adr/0015-shared-scraper-library.md).

## How it works

```
┌─────────────────────────┐     ┌──────────────────────────┐
│ desktop (10.0.0.243)     │     │ NAS (10.0.0.250)          │
│                          │     │                            │
│ ┌──────────────────────┐ │     │ ┌────────────────────────┐ │
│ │ LibreChat + MongoDB   │ │     │ │ LightRAG / MiniRAG      │ │
│ │ vision-mcp            │◄┼─────┼─┤ vault-indexer           │ │
│ │ proton-email-mcp      │ │     │ │ lightrag-mcp            │ │
│ └──────────────────────┘ │     │ │ Tailscale, registry      │ │
│ ┌──────────────────────┐ │     │ └────────────────────────┘ │
│ │ scraper-egress        │ │     │                            │
│ │ (gluetun + ProtonVPN) │ │     └──────────────────────────┘
│ └──────────────────────┘ │
└─────────────────────────┘
```

Other repos (algo-factory, estate-scraper, resale-inventory,
fashion-monitor, social-growth-bot, …) **attach** to services defined here
at runtime — they don't copy or vendor this config.

### Shared egress gateway

`compose/desktop/scraper-egress/` is a single gluetun + ProtonVPN container
with a fail-closed kill-switch, deployed once. Any scraper attaches via
`network_mode: "service:egress-gateway"` so its traffic never exits from
the desktop's real IP — the same IP the Kalshi executor and financial
pipeline use. A scrape-induced ban lands on a throwaway VPN exit, not
trading infra. Full contract: `compose/desktop/scraper-egress/consumer-contract.md`.
Decision record: [`docs/adr/0014-shared-scraper-egress-gateway.md`](docs/adr/0014-shared-scraper-egress-gateway.md).

### Personal AI stack

LibreChat (desktop) is the single chat UI, backed by local Ollama models
(via a resource broker, never raw `:11434`) and Claude via API. RAG over an
Obsidian vault runs on the NAS — LightRAG, migrating to MiniRAG (see ADR
0010) — indexed nightly by `vault-indexer/indexer.py` and queried through
`lightrag-mcp`. `wiki-ingest.py` runs the Karpathy-pattern LLM Wiki
ingest+lint over vault captures. `mcp/vision` and `mcp/lightrag` are the
home-hosted MCP servers LibreChat's agents call.

## Stack

| Layer | Tech |
|---|---|
| Orchestration | Docker Compose |
| Chat UI | LibreChat |
| LLM (local) | Ollama, via a resource broker (never raw `:11434`) |
| LLM (cloud) | Claude, via API |
| RAG | LightRAG → MiniRAG (ADR 0010) |
| MCP transport | streamable-http (superseded SSE, ADR 0013) |
| Identity | Authentik (OIDC) |
| Reverse proxy | Caddy (forward auth), nginx |
| Public exposure | Cloudflare Tunnel |
| VPN egress | gluetun + ProtonVPN |
| Scripts | Python 3, Bash |

## Repo layout

```
compose/
├── desktop/              # LibreChat, vision-mcp, proton-email-mcp, scraper-egress
└── nas/                  # LightRAG/MiniRAG, vault-indexer, lightrag-mcp, Tailscale
mcp/
├── lightrag/              # streamable-http LightRAG MCP server
└── vision/                 # FastMCP vision server (LibreChat agent tool)
vault-indexer/             # nightly Obsidian vault → LightRAG indexer
docs/
├── adr/                   # architecture decision records
└── specs/                 # stack specs (some historical/stale, flagged in-file)
.claude/skills/             # operational playbooks Claude Code consumes when working here
wiki-ingest.py              # LLM Wiki ingest + structural/semantic lint over the vault
media-ip-migrate.sh         # *arr/Overseerr config migration after a LAN IP change
```

## Quick start

### Prerequisites

- Docker + Docker Compose on the target host (desktop or NAS)
- `.env` populated from the relevant `.env.example` (desktop: `.env.example`
  at repo root and `compose/desktop/.env.example`; NAS:
  `compose/nas/.env.example`) — never committed, entered on the target host
  only (see `CONVENTIONS.md` §5)

```bash
git clone git@github.com:preston-bernstein/home-infra.git
cd home-infra

# desktop stack
cp compose/desktop/.env.example compose/desktop/.env   # fill in, desktop-only
docker compose -f compose/desktop/docker-compose.yml up -d

# NAS stack
cp compose/nas/.env.example compose/nas/.env           # fill in, NAS-only
docker compose -f compose/nas/docker-compose.yml up -d
```

## Conventions

`CONVENTIONS.md` is the cross-cutting rulebook every other home-lab repo
links back to: dedicated service users (never `preston`/`root`), Mac as
dev/edit-only vs. the desktop as where execution happens, SSH/sudo access
pattern, Ollama-via-broker only, secrets never committed, commit
attribution, the scraping discipline (isolated egress, logged-out,
stop-on-notice), and the shared-service-vs-shared-library split.

## Architecture decisions

15 ADRs in [`docs/adr/`](docs/adr/) covering embedding model choice,
ingest/archive pipeline design, LibreChat vs. Open WebUI, MongoDB hosting,
MCP transport evolution (SSE → streamable-http), nginx/Caddy reverse-proxy
layering, Cloudflare Tunnel exposure, LightRAG → MiniRAG migration, and the
shared scraper egress gateway / library split.

## License

MIT — see [LICENSE](LICENSE).
