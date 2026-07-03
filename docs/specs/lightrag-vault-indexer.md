# Vault Indexer Spec

Nightly Python service that reads the Obsidian vault from NAS, strips Obsidian syntax, and POSTs to the RAG Engine REST API. Hash-based incremental — unchanged files are skipped.

**RAG Engine target:** MiniRAG (migrated from LightRAG — see ADR 0010). See [minirag-migration.md](minirag-migration.md) for the step-by-step migration guide.

## Status

- vault-indexer deployed and running on NAS ✅
- 369/379 files indexed (10 retried nightly) ✅
- LightRAG API key rotated off `changeme` ✅
- **In progress:** MiniRAG migration — see [minirag-migration.md](minirag-migration.md)

---

## RAG Engine API

Auth header: `X-API-Key` (not `Authorization: Bearer`). Verified against LightRAG; MiniRAG expected to match (TBD — verify during migration Step 3).

```
POST /documents/texts
{ "texts": [...], "file_sources": [...] }
→ { "status": "success", "track_id": "insert_..." }

GET /documents/track_status/{track_id}
→ { "documents": [{ "id": "doc-abc123", "file_path": "...", "status": "PROCESSED|FAILED" }] }

GET /documents/pipeline_status

DELETE /documents/delete_document
{ "doc_ids": ["doc-abc123", ...] }
```

No metadata or sensitivity field — LightRAG has no server-side filtering. `file_source` carries vault-relative path only.

---

## vault-indexer Design

### Batching

`POST /documents/texts` (batch, 10 files), 2s sleep between batches. After each POST:
1. Get `track_id`
2. Poll `track_status` (up to 30s) → extract per-file `doc_id`s
3. Write to state

See [ADR 0002](../adr/0002-batch-insert-track-status.md).

### State file

`/state/hashes.json` — persisted at `/volume1/docker/ai/vault-indexer/` on NAS.

```json
{
  "Network/AI Infrastructure.md": {
    "hash": "sha256:abc123...",
    "doc_id": "doc-7ec487ba..."
  },
  "Personal/Journal/2026-06-01.md": {
    "hash": "sha256:def456...",
    "doc_id": "doc-fc3d1b...",
    "archived_at": "2026-07-15T02:00:00Z"
  }
}
```

### Run loop

1. Check `pipeline_status` — if running, log warning and exit (don't double-queue)
2. Walk `/vault` recursively, collect `.md` files (skipping `EXCLUDE_DIRS`: `.agents`, `.claude`, `.obsidian`)
3. SHA256 each file; skip if hash unchanged vs state
4. POST changed/new in batches of 10
5. Poll `track_status` per batch; write `doc_id` + hash to state on success
6. Files in state but missing from vault → set `archived_at` (don't delete yet)
7. Files with `archived_at` older than 30 days → `DELETE /documents/delete_document`, remove from state
8. Write updated state file

### State file env override

`STATE_FILE` env var overrides the default `$STATE_DIR/hashes.json`. Used during MiniRAG parallel testing to maintain a separate index without touching the live LightRAG state:

```bash
-e STATE_FILE=/state/hashes-minirag.json
```

### --cleanup flag

`python indexer.py --cleanup`:
- Lists all archived docs with age and RAG Engine status
- Prompts for confirmation before deleting
- Also reports docs stuck in non-PROCESSED status

See [ADR 0003](../adr/0003-two-stage-archive-delete.md).

### Obsidian syntax stripping

Keep: prose, headings, code fences, URLs, tables, callouts, tasks

Strip:
- Frontmatter YAML (`---` ... `---`) → remove
- `[[File|Display]]` → `Display`; `[[File]]` → `File`
- `![[image.png]]` → remove
- `%%comment%%` → remove
- `#tag` (standalone) → remove
- ` ```dataview ` blocks → remove

### Sensitivity

No sensitivity tagging in v1 — LightRAG has no server-side filtering. All vault files land in one index.

### Logging

- stdout → `docker logs vault-indexer`
- `/state/indexer.log` → persists, readable from DSM File Station; rotate at 1MB

---

## Dockerfile

```dockerfile
FROM python:3.12-slim
RUN pip install --no-cache-dir requests
COPY indexer.py /app/indexer.py
COPY crontab /etc/cron.d/vault-indexer
RUN chmod 0644 /etc/cron.d/vault-indexer && crontab /etc/cron.d/vault-indexer
CMD ["crond", "-f"]
```

crontab file:
```
0 4 * * * python /app/indexer.py >> /state/indexer.log 2>&1
```

Build: `docker buildx build --platform linux/amd64 -t vault-indexer:latest ./vault-indexer/`
Transfer + load on NAS via SSH (same pattern as financial-pipeline Makefile).

---

## Compose entry (NAS)

```yaml
vault-indexer:
  image: vault-indexer:latest
  container_name: vault-indexer
  restart: always
  environment:
    - LIGHTRAG_URL=http://lightrag:9621
    - LIGHTRAG_API_KEY=${LIGHTRAG_API_KEY}
    - VAULT_PATH=/vault
  volumes:
    - /volume1/obsidian-vault:/vault:ro
    - /volume1/docker/ai/vault-indexer:/state
  networks:
    - ai-net
```

---

## First run

```bash
# After deploy — runs immediately, bypasses 4am cron
docker exec vault-indexer python /app/indexer.py

# Watch progress (will take several hours for 1,511 files)
docker logs -f vault-indexer
```

---

## API Key Rotation

Replace `CHANGE_ME` before exposing LightRAG beyond LAN:

```bash
openssl rand -hex 32   # generate key
# Update LIGHTRAG_API_KEY in /volume1/docker/ai/docker-compose.yml
# Update in aichat config, Claude Code settings.json, LibreChat env
docker compose restart lightrag vault-indexer
curl -H "X-API-Key: <new-key>" http://10.0.0.250:9621/documents/pipeline_status
```

---

## TODO

This list predates the vault-indexer actually being built and deployed; most of it is
done. Updated 2026-07-03 against the Status section above and `docs/adr/0011`.

- [x] ~~**PREREQ:** `ollama pull mxbai-embed-large`, update compose, restart lightrag, verify~~ — done historically (lightrag ran mxbai in production); superseded by the MiniRAG migration's move to `bge-m3` (ADR 0011)
- [x] Write `vault-indexer/indexer.py`
- [x] Write `vault-indexer/crontab`
- [x] Build image, transfer to NAS, update compose
- [x] Run initial index: `docker exec vault-indexer python /app/indexer.py`
- [x] Monitor first run: `docker logs -f vault-indexer`
- [x] Rotate LightRAG API key off `CHANGE_ME`
- [x] Decide Automobile/ sensitivity classification — resolved by the v1 design decision (see Sensitivity section above): no per-category tagging, all vault files land in one index
- [ ] Remove `llama3.1:70b` from desktop if not needed — live-machine fact, unverified from the repo; check with Preston

---

## ADRs

- [0002 — Batch insert + track_status for doc_ids](../adr/0002-batch-insert-track-status.md)
- [0003 — Two-stage archive/delete](../adr/0003-two-stage-archive-delete.md)
- [0010 — MiniRAG over LightRAG](../adr/0010-minirag-over-lightrag.md)
- [0011 — BGE-M3 over mxbai-embed-large](../adr/0011-bge-m3-over-mxbai.md) _(supersedes 0001)_
