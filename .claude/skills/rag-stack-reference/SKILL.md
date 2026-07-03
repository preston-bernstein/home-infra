---
name: rag-stack-reference
description: Domain-theory knowledge pack for the Personal AI Stack's RAG pipeline. Load when you need to understand WHY the stack is built this way or HOW its APIs behave — graph RAG on small local models, the LightRAG/MiniRAG HTTP API (endpoints, X-API-Key auth, the track_id two-step), embedding model constraints (dimensions, token windows, image-vs-text routes), MCP transports (stdio vs SSE vs streamable-http, LibreChat allowedDomains SSRF gate), the Ollama broker lanes and 503-retry contract, and the LLM Wiki compiled-layer pattern. Triggers: "how do I insert documents into LightRAG/MiniRAG", "track_id", "how does the RAG API auth work", "what is the wiki/_raw pattern", "why MiniRAG", "how do MCP transports work here". For live breakage symptoms load home-infra-debugging-playbook instead.
---

# RAG Stack Reference — domain theory as applied in this home lab

This skill explains the concepts a newcomer (human or model) needs to reason correctly
about the RAG stack in `/Users/prestonbernstein/dev/home-infra`. It is the **authoritative
home for the RAG Engine API endpoint table**. It is theory-plus-API reference, not a
runbook — for operations see `home-infra-run-and-operate`; for the migration campaign see
`minirag-migration-campaign`.

Terms used exactly as defined in `CONTEXT.md` (the repo's controlled vocabulary), each
defined inline at first use.

## 1. Graph RAG in 300 words

Plain vector RAG embeds text chunks and retrieves by similarity. Graph RAG (LightRAG,
MiniRAG — both from the HKUDS lab) additionally runs an **extraction pass at index time**:
an LLM reads each document and emits entities and relationships, which are stored in a
graph alongside the vector store. Queries then traverse the graph (entity-level, relation-
level, or hybrid with vectors), which is what makes multi-hop questions ("what maintenance
has been done on the Corolla?") answerable from scattered notes.

The catch: **query quality is capped by extraction quality**. If the index-time LLM
produces a sparse or wrong entity graph, no query mode can recover — the knowledge simply
is not in the graph. Extraction happens once, at insert; garbage in, permanently garbage
out until re-index.

LightRAG's extraction requires the LLM to emit **structured JSON** (entities + relations
in a strict schema). Small models are bad at this: per ADR 0010, HKUDS recommends 32b+
for reliable output, and at 8b (`llama3.1:8b`) extraction failed on **~35% of documents**
here, producing a sparse/incorrect graph and poor query quality. The desktop GPU (RX 9070
XT, 16GB VRAM) fits `qwen2.5:14b` at Q4 but not a 32b — so LightRAG cannot be made good
on this hardware. (Nuance: the ~35% figure was measured on `llama3.1:8b`; the committed
compose currently runs LightRAG with `LLM_MODEL=llama3.2:3b`, even smaller.)

**MiniRAG** is the same lab's answer for exactly this situation: an SLM-first design that
does **not** require structured-JSON extraction, achieving comparable accuracy with small
models. Its HTTP API is near-identical to LightRAG's (`/query`, `/documents/*`, same
`LIGHTRAG_API_KEY` env var, same `X-API-Key` header — confirmed by source inspection in
`docs/specs/minirag-migration.md`), which is why the migration (ADR 0010) swaps the engine
while keeping the **Vault Indexer** (the nightly service that pushes vault content into
the engine) and, hopefully, `lightrag-mcp` unchanged.

## 2. The RAG Engine API (authoritative endpoint table)

**RAG Engine** = the service that builds and queries the entity graph + vector store from
vault content (per `CONTEXT.md`; currently LightRAG on NAS `:9621`, migrating to MiniRAG
on `<MINIRAG_PORT>` once deployed — Gate 0a in `minirag-migration-campaign`; as of
2026-07-02 `:9622` answers as `lightrag-trading` — do not probe it with authed writes).
All endpoints below are verified against `vault-indexer/indexer.py`
and `docs/specs/minirag-migration.md`.

**Auth: `X-API-Key: <key>` header — NOT `Authorization: Bearer`.** The key lives in
`LIGHTRAG_API_KEY` in `/volume1/docker/ai/.env` on the NAS (never in the repo; never
paste it into files). Export it before running the examples:

```bash
export LIGHTRAG_API_KEY=...   # value from /volume1/docker/ai/.env on the NAS
BASE=http://10.0.0.250:9621    # LightRAG; use <MINIRAG_PORT> once MiniRAG is deployed (Gate 0a).
                               # As of 2026-07-02 :9622 answers as lightrag-trading — do not probe
                               # it with authed writes.
```

| Endpoint | Method | Body / params | Returns |
|---|---|---|---|
| `/documents/texts` | POST | `{"texts": [...], "file_sources": [...]}` (parallel arrays) | `{"track_id": ...}` — **no doc_ids** |
| `/documents/track_status/{track_id}` | GET | — | `{"documents": [{"id", "status", "file_path", "error_msg"}], "total_count", "status_summary"}` |
| `/documents/pipeline_status` | GET | — | busy flags: `busy`, `is_processing` |
| `/documents/delete_document` | DELETE | `{"doc_ids": [...]}` | deletion result |
| `/documents/paginated` | POST | `{"page": 1, "page_size": 200, "status_filter": "failed"}` — **quirk (live-verified 2026-07-02): `status_filter` values are LOWERCASE enums (`pending`/`processing`/`preprocessed`/`processed`/`failed`) and `page_size` must be ≥ 10; uppercase `"FAILED"` returns HTTP 422 with an enum error** | `{"documents": [...]}` |
| `/query` | POST | `{"query": "...", "mode": "hybrid"}` — UNVERIFIED in repo, see note | answer + context |

### The non-obvious two-step (ADR 0002)

`POST /documents/texts` returns **only a `track_id`**, not per-document IDs. Per-file
`doc_id`s (required for later deletion) exist only via a follow-up
`GET /documents/track_status/{track_id}` poll. Nothing in the POST response hints that a
second call is required — this trips up every new client. The Vault Indexer inserts in
batches of 10, then polls `track_status` every 2s (60s timeout) until
`status_summary` shows all documents PROCESSED or FAILED, and records each `doc_id` in
its state file.

```bash
# Insert (returns track_id only)
curl -s -X POST "$BASE/documents/texts" \
  -H "X-API-Key: $LIGHTRAG_API_KEY" -H "Content-Type: application/json" \
  -d '{"texts": ["Some document body"], "file_sources": ["notes/example.md"]}'

# Poll for doc_ids and statuses
curl -s "$BASE/documents/track_status/<track_id>" -H "X-API-Key: $LIGHTRAG_API_KEY"

# Pipeline busy-check (the indexer refuses to run while busy, to avoid double-queuing)
curl -s "$BASE/documents/pipeline_status" -H "X-API-Key: $LIGHTRAG_API_KEY"

# Delete documents by id
curl -s -X DELETE "$BASE/documents/delete_document" \
  -H "X-API-Key: $LIGHTRAG_API_KEY" -H "Content-Type: application/json" \
  -d '{"doc_ids": ["doc-..."]}'

# Page through failed documents (status_filter is LOWERCASE; page_size >= 10 —
# live-verified 2026-07-02, see the endpoint table quirk)
curl -s -X POST "$BASE/documents/paginated" \
  -H "X-API-Key: $LIGHTRAG_API_KEY" -H "Content-Type: application/json" \
  -d '{"page": 1, "page_size": 200, "status_filter": "failed"}'

# Query — body shape from upstream LightRAG docs, UNVERIFIED against this deployment;
# confirm field names via: curl -s "$BASE/openapi.json"
curl -s -X POST "$BASE/query" \
  -H "X-API-Key: $LIGHTRAG_API_KEY" -H "Content-Type: application/json" \
  -d '{"query": "what is the home network topology?", "mode": "hybrid"}'
```

### Document statuses

Statuses observed in indexer code: **PROCESSED** and **FAILED** (matched as
case-insensitive substrings of `status_summary` keys and per-doc `status`, implying
transient in-flight states also exist mid-processing). Failed docs carry `error_msg`.
Note the API's `status_filter` enum is lowercase (table quirk above): `indexer.py
--cleanup` pages `/documents/paginated` with uppercase `status_filter: "FAILED"`, which
the current LightRAG rejects with 422 — its stuck-document report silently errors (open
bug; see `home-infra-failure-archaeology`).

### MiniRAG compatibility caveats (as of 2026-07-02)

- Env vars, `LIGHTRAG_API_KEY`, and `X-API-Key` header confirmed identical by source
  inspection (`docs/specs/minirag-migration.md`, resolved checklist).
- MiniRAG's internal port is **9721** (not 9621); compose maps `9623:9721` (moved off
  `:9622` 2026-07-03 to avoid the `lightrag-trading` conflict below).
- **`lightrag-mcp` against MiniRAG is UNVERIFIED** — spec Step 3 is explicitly TBD. If it
  fails, diff MiniRAG's `/openapi.json` against LightRAG's, looking at `/query` response
  and `/documents/track_status` field names.
- Live-NAS mystery (unrelated to minirag's port now): a `lightrag-trading` container
  occupies `:9622` (undocumented — not in any repo file). Confirm ownership with Preston
  before touching `:9622`; do not resolve unilaterally. See `home-infra-architecture-contract`
  drift register.

## 3. Embeddings as applied here

Three hard-won constraints, each backed by an ADR or incident:

1. **Dimension must match the vector store.** `nomic-embed-text` emits 768-dim vectors;
   LightRAG's store defaults to 1024-dim. The mismatch blocked **all** indexing — zero
   documents in, not degraded results (ADR 0001). `mxbai-embed-large` (1024-dim) matched
   without an `EMBEDDING_DIM` override. If "nothing indexes at all", check dimensions
   first. Full incident: `home-infra-failure-archaeology`.

2. **Effective token window matters more than advertised quality.** `mxbai-embed-large`
   degrades significantly past **~1k tokens** — long vault files (maintenance logs,
   deployment docs) lose their tails in the embedding, so tail content becomes
   unretrievable. `bge-m3` handles **8192 tokens**, covering every vault file (ADR 0011).

3. **Switching embedding models forces a full re-index.** Vectors from different models
   are not comparable; there is no in-place conversion. That is why ADR 0001 chose before
   the first run, and why ADR 0011's switch to bge-m3 was "free" — the MiniRAG migration
   requires a full re-index anyway.

**Image embeddings are a different route, not a different payload.** The Infinity SigLIP
server (desktop, loopback `:7997`, CPU — ROCm image unsupported on RDNA4) exposes
`/embeddings_image` for images. Its unified `/embeddings` route **tokenizes a `data:` URI
as text** — you get a syntactically valid, semantically meaningless text embedding, with
no error. The Ollama broker's embed lane (`10.0.0.243:11438`) rewrites `/embeddings` →
`/embeddings_image`, so clients go through the broker and never hit `:7997` directly
(header comment, `compose/desktop/embed-stack/docker-compose.yml`).

Current model assignments and env vars live in `home-infra-config-reference` — one-line
summary: LightRAG uses `mxbai-embed-large`, MiniRAG uses `bge-m3`, both via broker
`:11436`.

## 4. MCP transports as applied here

Vocabulary (`CONTEXT.md`): a **Home MCP** is an MCP server hosted on home infrastructure
(NAS or desktop), network-addressable, reachable from any Tailscale client. An
**External MCP** is a third-party MCP installed as a stdio process per client machine
(e.g. Brave Search, fetch).

| Transport | What it is | Used here for |
|---|---|---|
| stdio | Client spawns the server as a child process; per-machine install | External MCPs only |
| SSE | HTTP server, Server-Sent Events stream | ADR 0006's original decision; superseded in practice |
| streamable-http | HTTP server, current MCP spec transport | **What everything actually runs** (as of 2026-07-02) |

- **Why network transport at all (ADR 0006):** Home MCPs serve multiple clients —
  LibreChat on the desktop, Claude Code and other tools on the MacBook. stdio would mean
  installing and version-syncing every MCP on every client. A network transport runs the
  server once (e.g. on the NAS) and every client connects. ADR 0006 says "SSE"; the MCP
  spec evolved and the live deployments use `streamable-http` — a known documented drift
  (register in `home-infra-architecture-contract`), not a contradiction of the decision's
  substance (network > stdio for multi-client).
- **What actually runs:** `lightrag-mcp` on NAS `:3002` with
  `--mcp-transport streamable-http --mcp-streamable-http-path /mcp --mcp-stateless-http`
  (`compose/nas/docker-compose.yml`); vision-mcp `:3003` and proton-email-mcp `:3004` on
  the desktop; `compose/desktop/librechat.yaml` declares all three `type:
  "streamable-http"`. (`mcp/lightrag/README.md` used to say SSE and port 3001 — fixed
  2026-07-03; compose remains the contract regardless of what the README says.)
- **LibreChat SSRF gate:** LibreChat blocks MCP requests to private-LAN IPs unless the
  origin is listed in `mcpSettings.allowedDomains` in `librechat.yaml` — and it blocks
  **silently** (the MCP just never appears/works). Current allowlist:
  `http://10.0.0.250:3002`, `http://localhost:3003`, `http://localhost:3004`. Adding a
  Home MCP means adding both an `mcpServers` entry and an `allowedDomains` entry.
- **One service per Home MCP (ADR 0007):** the mcpo single-gateway pattern was rejected
  (an **MCP Gateway** is an explicitly rejected pattern in `CONTEXT.md`). Each Home MCP
  is its own Docker service on its own port; adding one is always the same operation.
  The planned nginx `/mcp/<name>` path routing exists only as commented-out location
  blocks in `compose/nas/nginx.conf` — clients hit ports directly today.

## 5. Ollama broker theory

The desktop GPU (RX 9070 XT, 16GB VRAM) is shared with gaming and Plex transcoding. Raw
Ollama on `:11434` has no admission control — an embedding batch would stutter a game.
The **ollama-resource-broker** (repo `~/dev/ollama-resource-broker` on the desktop; not
part of home-infra) fronts Ollama and arbitrates: when the GPU is busy with a
higher-priority use, the broker returns **503** instead of queuing your request into a
contended GPU.

**Rule (project owner standing instructions, enforced repo-wide by commit f2565b4):
nothing ever points at `:11434`. No exceptions.** The one apparent exception proves the
rule: `mcp/vision/server.py` has a code default of `http://localhost:11434`, but the
compose file overrides `OLLAMA_HOST=http://localhost:11435` — the compose value is the
contract.

The broker exposes four lanes on `10.0.0.243` (`:11435` interactive, `:11436` batch,
`:11437/jobs` durable jobs, `:11438` SigLIP image embed) — authoritative lane table:
`home-infra-config-reference` §2.

**503 means "retry later", not "broken".** Every broker client must implement a retry
ladder. The reference implementation is `wiki-ingest.py` `chat()`: on 503, retry up to
5 times with backoff delays **10s, 30s, 60s, 120s, 180s** (`RETRY_DELAYS`), then give up
loudly. Request errors (timeouts, connection resets) use the same ladder. A client that
treats 503 as fatal will fail every time someone launches a game.

Known drift (as of 2026-07-02): `CONTEXT.md` says **Lint** uses `:11436`, but
`wiki-ingest.py` sends everything (ingest and lint) to `:11435`. Flagged in the drift
register (`home-infra-architecture-contract`); do not silently "fix" either side.

## 6. The LLM Wiki pattern (ADR 0012)

Vocabulary (`CONTEXT.md`): the **Vault** is the Obsidian markdown collection synced via
Syncthing to the NAS at `/volume1/obsidian-vault`. The **Wiki** is the compiled,
LLM-maintained markdown collection at `wiki/` inside the vault — the persistent,
compounding artifact, and **what the RAG Engine actually indexes**. A **Capture** is a
file dropped into `_raw/` awaiting processing — immutable once placed, deleted after
promotion. **Ingest** is the manual operation (via Claude Code, running `wiki-ingest.py`
on the MacBook) that compiles Captures into wiki pages. **Lint** is the health check run
after every Ingest.

The wiki is a **compiled layer** (Karpathy's LLM Wiki pattern). Dataflow:

```
Capture (_raw/) → Ingest (wiki-ingest.py, qwen3:8b via broker :11435)
               → wiki/ pages (created or MERGED with existing pages)
               → Vault Indexer nightly (EXCLUDES _raw/) → RAG Engine
```

**Why compounding beats raw-fragment retrieval:** raw notes are redundant, contradictory
fragments; retrieval over them stays flat in quality as the pile grows. Ingest merges
each new Capture into existing entity pages (one Capture per LLM call, passing full
content of relevant existing pages under a 10,000-char budget so merges are real merges,
not blind appends), writes `[[cross-references]]`, then deletes the Capture. Each ingest
improves the pages every future query retrieves — quality compounds. It also plays to
the RAG Engine's strengths: graph extraction works far better on structured, cross-linked
pages than on unprocessed fragments (ADR 0012). Tradeoff accepted: ingest overhead and a
schema to maintain. `BATCH_SIZE>1` enables bulk mode (faster, weaker merging — relevant-
page lookup disabled).

**What Lint checks** (`wiki-ingest.py`):
- Structural (every run): **orphan pages** (no incoming wikilinks) and **broken
  wikilinks** (targets that don't exist).
- Semantic (`--semantic-lint`, LLM over 8-page batches): **CONTRADICTION** (pages
  conflict), **STALE** ("currently"/"now" claims likely outdated), **MISSING-LINK**
  (entity named but not `[[bracketed]]`).
- Known bug (as of 2026-07-02): `--semantic-lint` alone also runs a full ingest — safe
  lint-only invocation is `--lint --semantic-lint` together; full story:
  `home-infra-failure-archaeology` F10.

The Vault Indexer's `EXCLUDE_DIRS` (`{.agents, .claude, .obsidian, _raw}`) is what
guarantees only compiled pages reach the RAG Engine — never index `_raw/`.

## When NOT to use this skill

- Looking up a specific port, env var, model name, or flag value → `home-infra-config-reference` (authoritative tables).
- Running, deploying, SSHing, cron, logs, or executing the indexer/ingest → `home-infra-run-and-operate`.
- Measuring RAG quality (extraction failure rate, retrieval eval, evidence bar) → `rag-evaluation-methodology`.
- Executing the LightRAG→MiniRAG migration step-by-step → `minirag-migration-campaign`.
- Full incident narratives (nomic dimension incident, etc.) → `home-infra-failure-archaeology`.
- Authoritative drift register (repo vs live vs docs) → `home-infra-architecture-contract`.

## Provenance and maintenance

- Facts verified 2026-07-02 against repo state (commit 6cbd3a1 + committed (ebc8e9e/521df55/8fcc49c/34988d1) MiniRAG-migration changes) and live containers observed via SSH 2026-07-02.
- Sources: `vault-indexer/indexer.py` (API endpoints, auth header, statuses, batching),
  `docs/adr/0001,0002,0006,0007,0010,0011,0012`, `docs/specs/minirag-migration.md`,
  `compose/nas/docker-compose.yml`, `compose/desktop/docker-compose.yml`,
  `compose/desktop/librechat.yaml`, `compose/desktop/embed-stack/docker-compose.yml`,
  `wiki-ingest.py`, `CONTEXT.md`, `mcp/vision/server.py`, `mcp/lightrag/Dockerfile`.
  The "broker arbitrates a shared GPU" rationale is from project owner standing
  instructions and the embed-stack compose header; the broker's own code lives outside
  this repo.
- Re-verification one-liners (volatile facts):
  - RAG Engine up + auth style: `curl -s -H "X-API-Key: $LIGHTRAG_API_KEY" http://10.0.0.250:9621/documents/pipeline_status`
  - `/query` body shape (UNVERIFIED above): `curl -s http://10.0.0.250:9621/openapi.json | python3 -m json.tool | grep -A5 '"/query"'`
  - What occupies :9622 today: `ssh -i ~/.ssh/agent_ed25519 agent@10.0.0.250 'sudo /usr/local/bin/docker ps --format "{{.Names}} {{.Ports}}" | grep 9622'`
  - Live MCP transport flags: `grep -A20 'lightrag-mcp:' /Users/prestonbernstein/dev/home-infra/compose/nas/docker-compose.yml`
  - LibreChat allowlist: `grep -A5 allowedDomains /Users/prestonbernstein/dev/home-infra/compose/desktop/librechat.yaml`
  - Broker lanes answering: `curl -s -o /dev/null -w '%{http_code}\n' http://10.0.0.243:11435/api/tags` (repeat for 11436/11438; a 404 on `/` is normal)
  - Retry ladder still current: `grep RETRY_DELAYS /Users/prestonbernstein/dev/home-infra/wiki-ingest.py`
  - Semantic-lint bug still present: `grep -n 'elif semantic and not lint_only' /Users/prestonbernstein/dev/home-infra/wiki-ingest.py`
  - Indexer exclude list: `grep EXCLUDE_DIRS /Users/prestonbernstein/dev/home-infra/vault-indexer/indexer.py`
