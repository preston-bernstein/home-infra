# LightRAG + Vault Indexer Spec

Nightly Python service that reads the Obsidian vault from NAS, strips Obsidian syntax, and POSTs to the LightRAG REST API. Hash-based incremental — unchanged files are skipped. Part of Phase 1 in [ai-stack.md](ai-stack.md).

## Status

- LightRAG stack running: :9621 on NAS, green
- Vault synced: 1,511 files at `/volume1/obsidian-vault`
- **Prerequisite blocker:** embedding dimension mismatch — switch to `mxbai-embed-large` first (see [ADR 0001](../adr/0001-mxbai-embed-large.md))
- **Not done:** `vault-indexer/indexer.py` not written
- **Not done:** LightRAG API key still `CHANGE_ME`

---

## Prerequisite — Embedding Model Fix

`nomic-embed-text` produces 768-dim vectors. LightRAG defaults to 1024-dim. Nothing indexes until fixed.

```bash
# On desktop (10.0.0.243)
ollama pull mxbai-embed-large

# On NAS — update /volume1/docker/ai/docker-compose.yml
# EMBEDDING_MODEL=mxbai-embed-large
# then:
docker compose restart lightrag

# Verify (from MacBook)
curl -s -X POST http://10.0.0.250:9621/documents/text \
  -H "X-API-Key: CHANGE_ME" \
  -H "Content-Type: application/json" \
  -d '{"text":"test","file_source":"test.md"}'
# → get track_id, poll /documents/track_status/{track_id} → expect PROCESSED
```

---

## LightRAG API (verified against live /openapi.json)

Auth header: `X-API-Key` (not `Authorization: Bearer`).

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

`/state/hashes.json` — persisted at `/volume1/docker/vault-indexer/` on NAS.

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
2. Walk `/vault` recursively, collect `.md` files
3. SHA256 each file; skip if hash unchanged vs state
4. POST changed/new in batches of 10
5. Poll `track_status` per batch; write `doc_id` + hash to state on success
6. Files in state but missing from vault → set `archived_at` (don't delete yet)
7. Files with `archived_at` older than 30 days → `DELETE /documents/delete_document`, remove from state
8. Write updated `hashes.json`

### --cleanup flag

`python indexer.py --cleanup`:
- Lists all archived docs with age and LightRAG status
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
0 2 * * * python /app/indexer.py >> /state/indexer.log 2>&1
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
    - LIGHTRAG_API_KEY=CHANGE_ME        # rotate before use
    - VAULT_PATH=/vault
  volumes:
    - /volume1/obsidian-vault:/vault:ro
    - /volume1/docker/vault-indexer:/state
  networks:
    - ai-net
```

---

## First run

```bash
# After deploy — runs immediately, bypasses 2am cron
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

- [ ] **PREREQ:** `ollama pull mxbai-embed-large`, update compose, restart lightrag, verify
- [ ] Write `vault-indexer/indexer.py`
- [ ] Write `vault-indexer/crontab`
- [ ] Build image, transfer to NAS, update compose
- [ ] Run initial index: `docker exec vault-indexer python /app/indexer.py`
- [ ] Monitor first run: `docker logs -f vault-indexer`
- [ ] Rotate LightRAG API key off `CHANGE_ME`
- [ ] Decide Automobile/ sensitivity classification
- [ ] Remove `llama3.1:70b` from desktop if not needed

---

## ADRs

- [0001 — mxbai-embed-large over nomic-embed-text](../adr/0001-mxbai-embed-large.md)
- [0002 — Batch insert + track_status for doc_ids](../adr/0002-batch-insert-track-status.md)
- [0003 — Two-stage archive/delete](../adr/0003-two-stage-archive-delete.md)
