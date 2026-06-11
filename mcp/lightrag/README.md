# LightRAG MCP (SSE wrapper)

Exposes `daniel-lightrag-mcp` as an SSE HTTP server for multi-client access.

Package: `pip install daniel-lightrag-mcp`

TODO: verify SSE transport support in `daniel-lightrag-mcp`. If stdio-only, write a thin wrapper here that starts the stdio process and proxies to SSE.

Target endpoint: `http://10.0.0.250/mcp/lightrag` (via NAS nginx)
Internal port: 3001

See [docs/specs/ai-stack.md](../../docs/specs/ai-stack.md) — Phase 3.
