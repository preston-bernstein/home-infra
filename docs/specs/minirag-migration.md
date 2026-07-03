# MiniRAG Migration Spec

Migrate the vault RAG stack from LightRAG → MiniRAG, llama3.1:8b → qwen2.5:14b, mxbai-embed-large → bge-m3.

See ADR 0010 (MiniRAG over LightRAG) and ADR 0011 (BGE-M3 over mxbai). See [lightrag-vault-indexer.md](lightrag-vault-indexer.md) for vault-indexer design.

---

## Prerequisites

On desktop (10.0.0.243):
```bash
ollama pull qwen2.5:14b
ollama pull bge-m3
```

Both fit in the RX 9070 XT 16GB VRAM. Pull them before deploying MiniRAG — the first indexing run will block on model load otherwise.

Build MiniRAG image on MacBook and push to NAS local registry (no pre-built GHCR image exists — HKUDS/MiniRAG has no CI/CD pipeline):
```bash
# Clone locally (Dockerfile requires a .env file that isn't in the repo)
git clone --depth 1 https://github.com/HKUDS/MiniRAG.git /tmp/minirag-build
touch /tmp/minirag-build/.env

# Build and push directly to NAS registry
docker buildx build --platform linux/amd64 \
  -t 10.0.0.250:5000/minirag:latest \
  /tmp/minirag-build
docker push 10.0.0.250:5000/minirag:latest
```

This pattern (build → push to `10.0.0.250:5000/<image>`) applies to all custom images going forward. `docker compose pull` on the NAS fetches the latest pushed image.

---

## Step 1 — Deploy MiniRAG in parallel (NAS :9623)

Add to `/volume1/docker/ai/docker-compose.yml` alongside LightRAG. LightRAG stays on :9621 untouched.

```yaml
minirag:
  image: minirag:latest   # built from source — see Prerequisites (no GHCR image published)
  container_name: minirag
  restart: always
  ports:
    - "9623:9721"   # MiniRAG default internal port is 9721 (not 9621); :9622 is occupied by lightrag-trading (Gate 0a)
  environment:
    - LLM_BINDING=ollama
    - LLM_MODEL=qwen2.5:14b
    - LLM_BINDING_HOST=http://10.0.0.243:11435
    - EMBEDDING_BINDING=ollama
    - EMBEDDING_MODEL=bge-m3
    - EMBEDDING_BINDING_HOST=http://10.0.0.243:11436
    - WORKING_DIR=/app/data/rag_storage
    - LIGHTRAG_API_KEY=${LIGHTRAG_API_KEY}
  volumes:
    - /volume1/docker/ai/minirag:/app/data
  networks:
    - ai-net
```

**Resolved checklist (from source inspection of HKUDS/MiniRAG):**
- [x] No GHCR image — must build locally (see Prerequisites)
- [x] Env vars confirmed: `LLM_BINDING`, `LLM_BINDING_HOST`, `LLM_MODEL`, `EMBEDDING_BINDING`, `EMBEDDING_BINDING_HOST`, `EMBEDDING_MODEL`, `WORKING_DIR` all match
- [x] `LIGHTRAG_API_KEY` confirmed — same env var, same `X-API-Key` header
- [x] Internal port is **9721** (server `PORT` default) — compose mapping corrected to `9623:9721` (Gate 0a: :9622 occupied by `lightrag-trading`, resolved 2026-07-03 to move minirag to :9623)

Deploy:
```bash
cd /volume1/docker/ai
docker compose up -d minirag
docker logs minirag   # expect startup, not crash
```

Verify MiniRAG API reachable:
```bash
curl -s -H "X-API-Key: ${LIGHTRAG_API_KEY}" http://10.0.0.250:9623/documents/pipeline_status
```

---

## Step 2 — Initial index into MiniRAG (separate state file)

Run vault-indexer against MiniRAG with `STATE_FILE` overridden. LightRAG and `hashes.json` are untouched.

```bash
docker run --rm \
  --network container:lightrag \
  -e LIGHTRAG_URL=http://10.0.0.250:9623 \
  -e LIGHTRAG_API_KEY=${LIGHTRAG_API_KEY} \
  -e VAULT_PATH=/vault \
  -e STATE_FILE=/state/hashes-minirag.json \
  -v /volume1/obsidian-vault:/vault:ro \
  -v /volume1/docker/ai/vault-indexer:/state \
  vault-indexer:latest python /app/indexer.py
```

Or build a fresh vault-indexer image first if the exclude list changes haven't been deployed:
```bash
# On MacBook (home-infra repo)
docker buildx build --platform linux/amd64 -t vault-indexer:latest ./vault-indexer/
# Transfer to NAS and load (same pattern as other images)
```

Monitor progress — full re-index of ~380 files will take several hours:
```bash
tail -f /volume1/docker/ai/vault-indexer/hashes-minirag.json   # grows as files index
# Or tail the log if running with logging to /state/indexer.log
```

---

## Step 3 — Verify lightrag-mcp against MiniRAG

**TBD: lightrag-mcp API compatibility with MiniRAG not verified.**

1. Temporarily run lightrag-mcp pointed at MiniRAG:9623:
```bash
docker run --rm -it \
  --network container:lightrag \
  lightrag-mcp:latest lightrag-mcp \
  --host 10.0.0.250 --port 9623 \
  --api-key ${LIGHTRAG_API_KEY} \
  --mcp-transport streamable-http \
  --mcp-host 0.0.0.0 --mcp-port 3003 \
  --mcp-streamable-http-path /mcp \
  --mcp-stateless-http
```

2. Point LibreChat Vault Assistant agent at the temp MCP endpoint (`:3003`).

3. Run a representative test query — e.g. "what maintenance has been done on the Corolla?" or "what's my current home network topology?"

4. If lightrag-mcp fails or returns garbage:
   - Check MiniRAG's `/openapi.json` against LightRAG's — look for field name differences in `/query` response or `/documents/track_status`
   - Patch lightrag-mcp command flags if needed
   - If unfixable, evaluate `minirag-mcp` package or a thin wrapper

---

## Step 4 — Cutover

Once Step 3 passes and index looks complete:

**a. Stop LightRAG and old vault-indexer cron:**
```bash
cd /volume1/docker/ai
docker compose stop lightrag vault-indexer
```

**b. Update `/volume1/docker/ai/docker-compose.yml`:**
- Remove `lightrag` service (or comment it out)
- Change MiniRAG port: `9623:9721` → `9621:9721`
- Update `lightrag-mcp` command: `--host lightrag --port 9621` → `--host minirag --port 9721`
- Update `vault-indexer` env: `LIGHTRAG_URL=http://minirag:9621`
- Remove `STATE_FILE` override from vault-indexer (or set to `/state/hashes.json`)

**c. Rename state file:**
```bash
mv /volume1/docker/ai/vault-indexer/hashes-minirag.json \
   /volume1/docker/ai/vault-indexer/hashes.json
```

**d. Bring up:**
```bash
docker compose up -d minirag lightrag-mcp vault-indexer
```

**e. Verify:**
```bash
curl -s -H "X-API-Key: ${LIGHTRAG_API_KEY}" http://10.0.0.250:9621/documents/pipeline_status
# Then test a query from LibreChat Vault Assistant
```

---

## Step 5 — Sync home-infra repo

Update `compose/nas/docker-compose.yml`:
- Replace `lightrag` service with `minirag` service (on :9621)
- Update `lightrag-mcp` command args
- Update `vault-indexer` `LIGHTRAG_URL`
- Update models in `docs/specs/ai-stack.md` (LLM → qwen2.5:14b, embedding → bge-m3)

Commit: "migrate RAG stack: LightRAG → MiniRAG, mxbai → BGE-M3, 8b → 14b"

---

## Rollback

At any step before cutover:
- MiniRAG storage: `/volume1/docker/ai/minirag/` — separate, wipe and restart if needed
- LightRAG storage: `/volume1/docker/ai/lightrag/` — untouched
- `hashes.json` (LightRAG state): untouched until cutover step c
- Roll back: `docker compose stop minirag`, `docker compose start lightrag vault-indexer`

After cutover: rollback requires `docker compose stop minirag`, restore LightRAG service in compose, rename `hashes.json` back (if kept), `docker compose up -d lightrag vault-indexer`.

---

## ADRs

- [0010 — MiniRAG over LightRAG](../adr/0010-minirag-over-lightrag.md)
- [0011 — BGE-M3 over mxbai-embed-large](../adr/0011-bge-m3-over-mxbai.md)
