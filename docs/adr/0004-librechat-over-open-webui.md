# Replace Open WebUI with LibreChat as primary UI

Open WebUI was deployed as the chat UI but does not support MCP — it has its own Python-function tool system, not an MCP client. MCP tool use is a first-class requirement for this stack. LibreChat has native MCP support in its Agents feature, supports multiple LLM backends (Ollama + Anthropic), and works as a mobile PWA. Open WebUI is removed from the NAS compose entirely; its LightRAG Ollama-compatible connection is superseded by the LightRAG Home MCP accessed through LibreChat agents.
