# Personal AI Stack

A personal AI assistant system spanning home network and remote access, combining local LLMs, cloud AI, RAG over a personal knowledge base, and MCP tool use.

## Language

**Primary UI**:
The single web interface used for all AI interaction — LibreChat. Accessible from desktop browser, mobile browser (as PWA), and any Tailscale-connected device.
_Avoid_: chat UI, web UI, frontend

**Home MCP**:
An MCP server hosted on home network infrastructure (NAS or desktop), exposed via SSE transport, reachable from any Tailscale client. Built and maintained by the user.
_Avoid_: local MCP, custom MCP (ambiguous — could mean stdio)

**External MCP**:
An MCP server the user does not host — installed as a stdio process on each client machine (e.g. Brave Search, fetch). Not network-addressable.
_Avoid_: third-party MCP (confusing with open-source MCPs the user hosts)

**Local Model**:
An LLM running via Ollama on the desktop (10.0.0.243). Free to use, no API charges, GPU-accelerated.
_Avoid_: self-hosted model, open-source model (those are properties, not the thing itself)

**Cloud Model**:
An LLM accessed via API (Claude on Anthropic). Billed per token. Used only when explicitly selected.
_Avoid_: remote model, paid model

**Vault**:
The Obsidian markdown note collection synced via Syncthing to NAS and indexed by LightRAG. The primary knowledge base for RAG queries.
_Avoid_: notes, knowledge base (too generic)

**MCP Gateway**:
A pattern explicitly rejected — a single proxy (mcpo) wrapping multiple MCPs behind one port. Each Home MCP runs as its own service instead.
_Avoid_: using this term to mean the nginx reverse proxy (that's just a proxy)

**IdP**:
Authentik — the single identity provider for all home services. All user authentication flows through it.
_Avoid_: auth server, SSO server

**Public Service**:
A home service exposed via Cloudflare Tunnel at a `houseoflight.dev` subdomain, reachable off-network without a VPN client.
_Avoid_: external service (ambiguous with third-party services)

**Internal Service**:
A home service reachable only on LAN (10.0.0.0/24) or via Tailscale. Not exposed through Cloudflare Tunnel.
_Avoid_: local service (too vague)

**OIDC Client**:
A service that delegates authentication to the IdP via the OIDC protocol — LibreChat and Home Assistant are OIDC clients. The service never handles credentials directly.
_Avoid_: OAuth app (OIDC is the correct term here)

**Forward Auth**:
The Caddy + Authentik pattern for services that have no native OIDC support. Caddy checks every request against Authentik before proxying it; unauthenticated requests are redirected to the IdP login page.
_Avoid_: proxy auth (generic), middleware auth

**Access Group**:
One of three Authentik user groups controlling which services a user can reach: `admin` (Preston only), `household` (wife — most services), `social` (parents and friends — limited services).
_Avoid_: role, permission level
