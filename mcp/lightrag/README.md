# LightRAG MCP (streamable-http)

Exposes `lightrag-mcp` as a streamable-http MCP server for multi-client access.

Package: `pip install lightrag-mcp`

Transport is `streamable-http`, not SSE — MCP spec evolved after this stack was
scaffolded (see ADR 0006, superseded in practice). The Dockerfile bakes in a default
CMD, but `compose/nas/docker-compose.yml`'s `lightrag-mcp` service overrides it
completely (host/port/api-key/transport args) — compose is the source of truth for
what's actually running.

Target endpoint: `http://10.0.0.250:3002/mcp` (direct — a NAS nginx `/mcp/lightrag`
route exists in `compose/nas/nginx.conf` but is commented out, not live).
Internal port: 3002.

See [docs/specs/ai-stack.md](../../docs/specs/ai-stack.md) — Phase 3 (historical intent
only; badly stale, see `home-infra-architecture-contract` drift register).
