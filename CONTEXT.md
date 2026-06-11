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
