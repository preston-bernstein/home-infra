# Run LibreChat and MongoDB on desktop, not NAS

The NAS (DS1522+, Ryzen R1600, 7.7GB RAM) is already running 3.2GB of swap under its current load. MongoDB plus LibreChat (Node.js) would push it further into memory pressure. The desktop (10.0.0.243, 62GB RAM, 54GB available) has ample headroom and already runs Ollama — co-locating LibreChat on the same machine as Ollama means LLM calls are localhost with zero network latency. NAS stays focused on storage services (LightRAG, vault-indexer).
