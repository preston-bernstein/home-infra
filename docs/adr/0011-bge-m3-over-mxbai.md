# Use BGE-M3 for embeddings instead of mxbai-embed-large

Supersedes ADR 0001.

`mxbai-embed-large` degrades significantly past ~1k tokens. Many vault files (maintenance logs, deployment docs, development notes) exceed this limit, causing the embedding to miss content in the tail of long documents. `bge-m3` handles up to 8192 tokens, covers the full content of all vault files, and has stronger retrieval quality on long-form text. Both models fit in the RX 9070 XT's 16GB VRAM. The MiniRAG migration (ADR 0010) requires a full re-index regardless — switching embeddings carries no additional migration cost.
