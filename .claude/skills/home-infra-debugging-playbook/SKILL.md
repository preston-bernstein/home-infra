---
name: home-infra-debugging-playbook
description: Symptom-to-triage playbook for the home-infra Personal AI Stack (LightRAG/MiniRAG RAG Engine on the NAS, vault-indexer, wiki-ingest.py, LibreChat + MCP servers on the desktop, Ollama resource broker). Load this when something is BROKEN or behaving strangely — zero documents indexing, LLM calls returning 503, an MCP tool invisible in LibreChat, docs stuck FAILED and you don't know why, indexer exiting immediately, RAG queries missing content or returning garbled entities, files vanishing from the index, "sudo docker command not found" on the NAS, wiki-ingest printing "no pages parsed", crash-looping containers, port-bind failures, or scp/rsync to the NAS failing. Provides discriminating experiments (read-only commands with interpretation of each outcome) and pointers to the sibling skill that owns each fix.
---

# Home-Infra Debugging Playbook

Symptom → most-likely-cause → discriminating experiment → where the fix lives.
This skill diagnoses. It deliberately does NOT contain fixes that belong to sibling
skills — every row ends with a pointer. Full incident narratives live in
`home-infra-failure-archaeology`; each row here carries only a one-line story.

**Read this first — three ground rules:**

1. **Read-only until you know the cause.** Every experiment below is a GET, a log
   read, or a `docker ps`. Any behavior-changing action (restart, redeploy, config
   edit) goes through `home-infra-change-control` first.
2. **The repo is INTENT; the live machines are RUNTIME TRUTH** (assumption, per
   project sync contract — see `home-infra-architecture-contract` for the drift
   register). When repo and machine disagree, believe the machine, then record the
   drift — do not "fix" the machine to match the repo without change control.
3. **Never paste a real API key.** `LIGHTRAG_API_KEY` lives in
   `/volume1/docker/ai/.env` on the NAS — load it into an env var (see below) and
   reference `$LIGHTRAG_API_KEY` in every command.

**Jargon (one-line each; authoritative vocabulary is `CONTEXT.md`):**
*RAG Engine* = the LightRAG (soon MiniRAG) service on the NAS that builds/queries the
entity graph + vector store. *Vault* = the Obsidian note collection at
`/volume1/obsidian-vault` on the NAS (Syncthing-synced). *Vault Indexer* = nightly
container that POSTs vault files to the RAG Engine. *Capture* = file in the vault's
`_raw/` awaiting wiki-ingest. *Broker* = ollama-resource-broker on the desktop that
arbitrates GPU access (lanes :11435/:11436/:11437/:11438; never raw `:11434`).

---

## 60-second general triage flow

Run these in order; stop at the first anomaly and jump to the matching row.

```bash
# 0. Load the API key into your shell (on the NAS; never echo it into files/chat)
ssh -i ~/.ssh/agent_ed25519 agent@10.0.0.250
export LIGHTRAG_API_KEY=$(sudo grep '^LIGHTRAG_API_KEY=' /volume1/docker/ai/.env | cut -d= -f2-)

# 1. Are the containers up? (NAS — note the full docker path, see Row 8)
sudo /usr/local/bin/docker ps --format '{{.Names}}\t{{.Status}}\t{{.Ports}}'
#    Look for: lightrag (Up), lightrag-mcp (Up), vault-indexer (Up), anything "Restarting".

# 2. Is the RAG Engine answering and idle?
curl -s -H "X-API-Key: $LIGHTRAG_API_KEY" http://10.0.0.250:9621/documents/pipeline_status
#    Connection refused → container/network problem (Row 11/12). busy:true → Row 5.

# 3. What did the last indexer run say?
sudo tail -50 /volume1/docker/ai/vault-indexer/indexer.log
#    (rotates at 1 MB; previous log is indexer.log.1 in the same dir)

# 4. RAG Engine internals
sudo /usr/local/bin/docker logs --tail 50 lightrag

# 5. Is the broker reachable? (desktop; a 404 on the root path is NORMAL — the
#    broker has no landing page; 404 means "up", connection refused means "down")
curl -s -o /dev/null -w '%{http_code}\n' http://10.0.0.243:11435/
```

**Exact log locations (as of 2026-07-02):**

| What | Where | Notes |
|---|---|---|
| vault-indexer runs | NAS `/volume1/docker/ai/vault-indexer/indexer.log` (`/state/indexer.log` in-container) | RotatingFileHandler, 1 MB max, 1 backup (`indexer.log.1`); cron also appends stdout here |
| indexer state | NAS `/volume1/docker/ai/vault-indexer/hashes.json` | per-file `hash`, `doc_id`, optional `archived_at` |
| RAG Engine | `sudo /usr/local/bin/docker logs lightrag` | container stdout only |
| lightrag-mcp | `sudo /usr/local/bin/docker logs lightrag-mcp` | |
| wiki-ingest | stdout on the MacBook (it is run manually there) + debug dumps in vault `_raw/*-debug.txt` | see Row 9 |
| LibreChat | desktop: `docker logs librechat` | host-network container on 10.0.0.243 |

---

## Symptom → triage table

| # | Symptom (as the operator sees it) |
|---|---|
| 1 | Zero documents index; every insert fails |
| 2 | LLM calls return HTTP 503 |
| 3 | LibreChat agent can't see an MCP tool |
| 4 | Documents stuck FAILED in the RAG Engine |
| 5 | Indexer run exits immediately with a pipeline-busy warning |
| 6 | File is indexed but queries miss content at its end |
| 7 | Vault file vanished from the index |
| 8 | `sudo docker` on the NAS → command not found |
| 9 | wiki-ingest prints "no pages parsed" |
| 10 | `--semantic-lint` unexpectedly ingested captures (CLOSED 2026-07-03) |
| 11 | Container crash-looping on the NAS |
| 12 | Port bind failure / service unreachable on its expected port |
| 13 | Poor or garbled entity extraction in RAG answers |
| 14 | scp/rsync to the NAS vault fails |

Each row below: **Cause → Experiment → Fix pointer → Story**.

### Row 1 — Zero documents index / all inserts fail

- **Most likely cause:** embedding dimension mismatch — the `EMBEDDING_MODEL` the
  RAG Engine is configured with produces vectors of a different dimension than the
  already-seeded vector store (e.g. nomic-embed-text = 768-dim vs store = 1024-dim).
  mxbai-embed-large and bge-m3 are both 1024-dim; nomic-embed-text is 768.
- **Discriminating experiment** (NAS):
  ```bash
  sudo /usr/local/bin/docker exec lightrag env | grep EMBEDDING
  sudo /usr/local/bin/docker logs lightrag 2>&1 | grep -iE 'dimension|shape|embed' | tail -20
  ```
  Model in env ≠ model the store was seeded with, and/or logs show dimension/shape
  errors on insert → confirmed mismatch. Logs clean and model unchanged → not this
  row; check Row 4 (FAILED docs) instead. To read the stored dimension directly
  (UNVERIFIED filename — nano-vectordb layout, not confirmed against the live
  container): `sudo /usr/local/bin/docker exec lightrag sh -c 'grep -o "\"embedding_dim\": *[0-9]*" /app/data/rag_storage/vdb_*.json | sort -u'`.
- **Fix pointer:** changing `EMBEDDING_MODEL` after seeding requires a **full
  re-index** — that is a change-controlled operation: `home-infra-change-control`,
  executed per `home-infra-build-and-deploy`. Model/dim table: `home-infra-config-reference`.
- **Story:** ADR 0001 — nomic-embed-text's 768-dim vectors vs LightRAG's 1024-dim
  default blocked ALL indexing before the first successful run; mxbai-embed-large
  (1024-dim) fixed it. Full narrative: `home-infra-failure-archaeology`.

### Row 2 — LLM calls return HTTP 503

- **Most likely cause:** this is the **broker working as designed**, not an outage.
  The ollama-resource-broker on the desktop 503s when the GPU is busy (gaming or
  Plex transcode has priority). Clients are contractually required to retry —
  `wiki-ingest.py chat()` implements the reference retry ladder: 5 attempts with
  10/30/60/120/180 s delays on 503.
- **Discriminating experiment:**
  ```bash
  curl -s -o /dev/null -w '%{http_code}\n' http://10.0.0.243:11435/
  ```
  `404` → broker up (no landing page — 404 on root is normal, verified 2026-07-02);
  your 503s are arbitration → wait/retry, do NOT restart anything.
  Connection refused/timeout → broker itself is down → escalate via
  `home-infra-run-and-operate` (broker runs on the desktop host, not in a container).
  503s persisting for hours with an idle GPU → broker bug, see
  `~/dev/ollama-resource-broker` repo (out of scope for this repo).
- **Fix pointer:** none needed for the normal case — retry. Client code that does
  NOT retry on 503 is the actual bug; retry-ladder pattern lives in
  `rag-stack-reference` (broker theory) and `wiki-ingest.py` (reference impl).
  Never route around the broker to raw `:11434` — non-negotiable, see
  `home-infra-change-control`.
- **Story:** the retry ladder exists because the GPU is shared with gaming/Plex by
  design; wiki-ingest bakes it in so ingest survives a gaming session. See
  `home-infra-failure-archaeology`.

### Row 3 — LibreChat agent can't see an MCP tool

- **Most likely cause:** the MCP server's origin is missing from
  `mcpSettings.allowedDomains` in `librechat.yaml`. LibreChat's SSRF protection
  **silently blocks** MCP servers on private-LAN IPs unless their origin is
  explicitly allowlisted — no error surfaces in the UI.
- **Discriminating experiment** (desktop; deployed file is runtime truth):
  ```bash
  grep -A8 'allowedDomains' /opt/docker/librechat-stack/librechat.yaml
  grep -B1 -A3 'mcpServers' /opt/docker/librechat-stack/librechat.yaml
  ```
  Every `mcpServers.*.url` origin must appear in `allowedDomains`. As of 2026-07-02
  the repo copy (`compose/desktop/librechat.yaml`) allowlists
  `http://10.0.0.250:3002`, `http://localhost:3003`, `http://localhost:3004`.
  URL present in both lists but tool still missing → check the MCP server itself:
  `curl -s -o /dev/null -w '%{http_code}\n' http://10.0.0.250:3002/mcp` — any HTTP
  status means the port answers (exact code for a bare GET against streamable-http
  is UNVERIFIED); connection refused → server down (Row 11).
- **Fix pointer:** editing `librechat.yaml` + restarting LibreChat is
  change-controlled → `home-infra-change-control`; MCP endpoint/transport table →
  `rag-stack-reference`; deploy mechanics → `home-infra-build-and-deploy`.
- **Story:** discovered when a LAN-IP MCP server was configured correctly in
  `mcpServers` yet never appeared to agents — `allowedDomains` was the missing
  half. Full story: `home-infra-failure-archaeology`.

### Row 4 — Documents stuck FAILED in the RAG Engine

- **Most likely cause:** per-document processing failures (LLM extraction errors,
  timeouts during entity extraction). The insert POST succeeds; the failure shows
  up only in document status afterwards (see ADR 0002 — the POST returns a
  `track_id`, not results).
- **Discriminating experiment** (NAS, key loaded per triage step 0):
  ```bash
  curl -s -H "X-API-Key: $LIGHTRAG_API_KEY" -H 'Content-Type: application/json' \
    -X POST http://10.0.0.250:9621/documents/paginated \
    -d '{"page":1,"page_size":50,"status_filter":"failed"}'
  ```
  (`status_filter` must be lowercase and `page_size >= 10` — live-verified 2026-07-02;
  shape + quirks: `rag-stack-reference`.) Non-empty `documents` array → confirmed; each
  entry carries `file_path` and `error_msg`. The indexer has a built-in report for
  exactly this:
  ```bash
  sudo /usr/local/bin/docker exec -it vault-indexer python /app/indexer.py --cleanup
  ```
  `--cleanup` lists archived docs AND queries the RAG Engine for FAILED docs
  (paginated, 200/page). It is read-only **until** its `[y/N]` prompt — answer `N`
  (or Enter) to exit without deleting anything. Note: `indexer.py --cleanup`'s own
  FAILED query sends uppercase `"FAILED"` and silently errors on current LightRAG
  (open bug — see `home-infra-failure-archaeology`); use the curl above for a
  trustworthy census.
- **Fix pointer:** widespread extraction failures are Row 13 territory (SLM JSON
  extraction → MiniRAG migration). Deleting/re-queueing failed docs is
  change-controlled → `home-infra-change-control`; API details →
  `rag-stack-reference`.
- **Story:** ADR 0002 — the API gives no doc_ids or failures in the POST response;
  `track_status` polling and the `--cleanup` report were built to make failures
  visible at all. See `home-infra-failure-archaeology`.

### Row 5 — Indexer exits immediately with a pipeline-busy warning

- **Most likely cause:** **expected behavior, not a bug.** `indexer.py` checks
  `GET /documents/pipeline_status` before every run and logs
  `"LightRAG pipeline is busy — skipping run to avoid double-queuing"` then exits
  if the engine reports `busy` or `is_processing`. A large previous run (or the
  MiniRAG initial index) can legitimately keep the pipeline busy for hours.
- **Discriminating experiment:**
  ```bash
  curl -s -H "X-API-Key: $LIGHTRAG_API_KEY" http://10.0.0.250:9621/documents/pipeline_status
  ```
  `busy`/`is_processing` truthy → wait and re-run later; nothing is wrong.
  Flag stuck truthy for many hours with `docker logs lightrag` showing no activity
  → engine wedged; that is a restart decision → `home-infra-change-control`.
- **Fix pointer:** manual-run procedure and cron schedule (nightly at 04:00, per
  `vault-indexer/crontab` — note spec prose still says 2am in places, crontab wins)
  → `home-infra-run-and-operate`.
- **Story:** the busy-check exists precisely so cron and manual runs can't
  double-queue the same batch into a slow pipeline. See
  `home-infra-failure-archaeology`.

### Row 6 — File indexed but queries miss content at its end

- **Most likely cause:** embedding token truncation. mxbai-embed-large (the current
  LightRAG embedding model as of 2026-07-02) degrades significantly past ~1k
  tokens; facts in the tail of long files (maintenance logs, deployment docs)
  effectively never make it into the vector.
- **Discriminating experiment:** pick a long vault file (>~4 KB of text). Query the
  RAG Engine for a fact stated **near the top**, then for a fact stated **only in
  the last section**. Top-fact retrieved, tail-fact missed, and
  `hashes.json` shows the file indexed with a `doc_id` → truncation confirmed.
  Confirm the file really is in state:
  ```bash
  sudo python3 -c "import json; s=json.load(open('/volume1/docker/ai/vault-indexer/hashes.json')); print(s.get('<relative/path.md>'))"
  ```
- **Fix pointer:** do NOT hand-chunk files as a workaround. The fix is the
  embedding switch to bge-m3 (8192-token window) which ships with the MiniRAG
  migration → `minirag-migration-campaign`. Rationale: ADR 0011. Query-quality
  evidence methodology → `rag-evaluation-methodology`.
- **Story:** ADR 0011 — long vault files silently lost their tails under mxbai;
  bge-m3 chosen because the migration forces a full re-index anyway (free switch).
  See `home-infra-failure-archaeology`.

### Row 7 — Vault file vanished from the index

- **Most likely cause:** the file went missing from the vault at scan time (deleted,
  renamed, or a Syncthing lag) and the indexer archived it. Per ADR 0003 the
  indexer NEVER deletes on first miss: it stamps `archived_at` in `hashes.json` and
  only calls the delete endpoint after 30 days.
- **Discriminating experiment** (NAS):
  ```bash
  sudo grep -B3 'archived_at' /volume1/docker/ai/vault-indexer/hashes.json | head -40
  ls /volume1/obsidian-vault/<relative/path.md>
  ```
  Entry has `archived_at` and the file is absent on disk → rename/delete/sync-lag;
  if the file reappears in the vault, the next nightly run re-indexes it under its
  hash (a renamed file indexes under the new path; the old path ages out at 30 d).
  File present on disk but archived anyway → check Syncthing sync state and
  whether the file sits under an excluded dir (`.agents`, `.claude`, `.obsidian`,
  `_raw` are never indexed — `_raw/` exclusion is deliberate, ADR 0012).
- **Fix pointer:** manual archive review/purge is `--cleanup`
  (interactive — see Row 4); operating procedure → `home-infra-run-and-operate`;
  vault write discipline (never write into the live vault casually — Syncthing
  propagates everywhere) → `home-infra-change-control`.
- **Story:** ADR 0003 — Syncthing false positives during vault reorganization made
  immediate-delete too dangerous; two-stage archive→delete (30 d) was the answer.
  See `home-infra-failure-archaeology`.

### Row 8 — `sudo docker` on the NAS → command not found

- **Most likely cause:** Synology quirk — `docker` lives at `/usr/local/bin/docker`,
  which is not on root's `PATH` under `sudo`.
- **Discriminating experiment / fix in one:**
  ```bash
  sudo /usr/local/bin/docker ps
  ```
  Works → it was just the PATH. Still not found → you are probably not on the NAS
  (check `hostname` — the NAS is `house-of-light`, 10.0.0.250).
- **Fix pointer:** this row is self-fixing (always type the full path on the NAS);
  SSH access pattern (agent identity, aliases) → `home-infra-run-and-operate`.
- **Story:** verified live 2026-07-02: `sudo docker` → command not found;
  `sudo /usr/local/bin/docker` works. Trips up every fresh session.

### Row 9 — wiki-ingest prints "no pages parsed"

- **Most likely cause:** the model's output broke the expected
  `### PAGE: <name>.md … ### END` block format, so `parse_pages()` found nothing
  (common with model changes, thinking-token leakage, or truncated responses).
  **This path is safe:** the raw model response is dumped to
  `_raw/<capture-stem>-debug.txt` and the capture is **NOT deleted** — nothing is
  lost, the ingest for that file simply didn't happen.
- **Discriminating experiment** (MacBook; vault default
  `~/dev/Obsidian/Home Network Vault`, override via `VAULT_PATH`):
  ```bash
  ls ~/dev/Obsidian/Home\ Network\ Vault/_raw/*-debug.txt
  head -60 ~/dev/Obsidian/Home\ Network\ Vault/_raw/<capture>-debug.txt
  ```
  Debug file contains wiki content but with malformed `### PAGE:` markers → format
  break, likely model/prompt drift. Debug file empty or an error message →
  broker/model problem (Row 2). Note debug files themselves are skipped on
  re-ingest (stems ending `-debug` are filtered).
- **Fix pointer:** re-run procedure and wiki-ingest operations →
  `home-infra-run-and-operate`; changing `INGEST_MODEL` or the prompt is
  change-controlled → `home-infra-change-control`.
- **Story:** the debug-dump-and-keep-capture behavior was designed in from the
  start of the LLM Wiki layer (ADR 0012) because SLM format compliance is flaky.
  See `home-infra-failure-archaeology`.

### Row 10 — Ran `--semantic-lint` and it ingested captures unexpectedly (CLOSED 2026-07-03)

- **Historical cause:** entry-point bug in `wiki-ingest.py`. The dispatch had:
  ```python
  elif semantic and not lint_only:
      run_ingest()
  ```
  so `--semantic-lint` **alone** ALSO ran a full ingest of `_raw/`, contradicting
  the docstring ("structural + semantic (LLM) lint").
- **Fix (2026-07-03):** the erroneous `elif` branch was removed; `--semantic-lint`
  alone now only lints, matching the docstring. All 4 flag combinations verified
  against expected behavior. If you still see this symptom, `wiki-ingest.py` may be
  running from an older checkout — `sed -n '389,398p' wiki-ingest.py` and confirm no
  `elif semantic and not lint_only` branch is present.
- **Story:** documented as drift item #9 (`home-infra-architecture-contract`) and F10
  (`home-infra-failure-archaeology`) — both now closed.

### Row 11 — Container crash-looping on the NAS

- **Most likely cause:** varies — but **first check ownership before touching
  anything.** Not every container on the NAS belongs to this repo. As of
  2026-07-02, `fashion-monitor-mcp-server-1` and `fashion-monitor-dashboard-1`
  were observed Restarting — those belong to the fashion-monitor repo, NOT
  home-infra; leave them alone.
- **Discriminating experiment:**
  ```bash
  sudo /usr/local/bin/docker ps --filter status=restarting --format '{{.Names}}\t{{.Status}}'
  sudo /usr/local/bin/docker logs --tail 50 <container>
  ```
  Then check ownership: is the service defined in this repo's
  `compose/nas/docker-compose.yml` (tailscale, lightrag, registry, minirag,
  vault-indexer, lightrag-mcp, watchtower)? Not in that list → another repo's
  problem; report, don't act.
- **Fix pointer:** restarts/redeploys of home-infra services →
  `home-infra-change-control` then `home-infra-build-and-deploy`. NAS is
  memory-pressured (7.7 GB RAM, ADR 0005) — OOM kills are a plausible root cause;
  memory-pressure context → `home-infra-architecture-contract`.
- **Story:** ADR 0005 moved LibreChat+Mongo OFF the NAS because it hit 3.2 GB
  swap; the NAS remains the tightest box in the fleet. See
  `home-infra-failure-archaeology`.

### Row 12 — Port bind failure / service unreachable on its expected port

- **Most likely cause:** live-vs-repo port drift. Headline case (as of
  2026-07-02): **NAS `:9622` is occupied by a live container `lightrag-trading`
  that appears in NO repo file.** The repo compose used to also assign minirag
  to `:9622` (a real collision); that was resolved 2026-07-03 by moving minirag
  to `9623:9721` (Gate 0a in `minirag-migration-campaign`), so deploying minirag
  as-written no longer collides with `lightrag-trading` — but `lightrag-trading`
  itself is still undocumented live reality worth checking for on any port-bind
  failure.
- **Discriminating experiment:**
  ```bash
  sudo /usr/local/bin/docker ps --format '{{.Names}}\t{{.Ports}}' | grep -E '9621|9622|9623|3002|5000'
  ```
  Compare against `compose/nas/docker-compose.yml`. Mismatch → drift; record it,
  don't resolve it unilaterally.
- **Fix pointer:** **FLAG — confirm ownership of `:9622`/`lightrag-trading` with
  Preston before touching that port. Do not stop, rebind, or redeploy over it.**
  Drift register (authoritative copy) → `home-infra-architecture-contract`. Also
  stale-port traps: `mcp/lightrag/README.md` says :3001 but compose runs
  lightrag-mcp on :3002 — compose wins.
- **Story:** `lightrag-trading` (0.0.0.0:9622→9621) showed up in live `docker ps`
  2026-07-02 with zero repo footprint — undocumented live reality. See
  `home-infra-failure-archaeology`.

### Row 13 — Poor or garbled entity extraction in RAG answers

- **Most likely cause:** SLM structured-JSON extraction failure — the architectural
  weakness that motivated the MiniRAG migration (ADR 0010). LightRAG's pipeline
  needs the LLM to emit structured JSON for entity/relationship extraction;
  HKUDS recommends 32b+; at llama3.1:8b extraction failed ~35% of documents. The
  committed compose currently runs `LLM_MODEL=llama3.2:3b` — even smaller, so
  expect the same failure class or worse (the ~35% number was measured on 8b).
- **Discriminating experiment:** check the failure surface, not the symptom:
  Row 4's FAILED-docs query (`/documents/paginated`, `status_filter=failed`) — a
  high FAILED count with extraction-flavored `error_msg` values → confirmed.
  Measuring the extraction failure *rate* properly → `rag-evaluation-methodology`.
- **Fix pointer:** **do NOT attempt the rejected workarounds** — 32b models
  (won't fit 16 GB VRAM), GLEANING passes, chunk-size tuning, 32k context: all
  explicitly rejected in ADR 0010 ("no Phase 1 workarounds"). The fix is the
  MiniRAG migration → `minirag-migration-campaign`. Design rationale →
  `home-infra-architecture-contract` / `rag-stack-reference`.
- **Story:** ADR 0010 — LightRAG at SLM scale produces a sparse/incorrect entity
  graph; MiniRAG is SLM-first by design with a near-identical API. See
  `home-infra-failure-archaeology`.

### Row 14 — scp/rsync to the NAS vault fails

- **Most likely cause:** two stacked Synology quirks. (a) `scp` in sftp mode fails
  against the NAS — use legacy protocol: `scp -O`. (b) rsync-over-ssh is blocked
  entirely — stream instead: `ssh ... 'cat > /dest/path' < localfile` (or
  `cat localfile | ssh nas-agent 'sudo tee /dest/path > /dev/null'` when the
  destination needs elevated write). Source: project owner standing instructions.
- **Discriminating experiment:**
  ```bash
  scp -O -i ~/.ssh/agent_ed25519 <file> agent@10.0.0.250:/tmp/
  ```
  Works with `-O` but not without → sftp quirk confirmed, done. Fails with `-O`
  too → auth/permission problem: the vault at `/volume1/obsidian-vault` is owned
  by `sc-syncthing`, and the `agent` user cannot write there directly.
- **Fix pointer:** SSH/transfer patterns → `home-infra-run-and-operate`.
  **Do not write into the live vault casually** — Syncthing propagates every write
  to all devices (project owner standing instructions; change-controlled →
  `home-infra-change-control`).
- **Story:** the `-O` flag and ssh-cat streaming were discovered the hard way
  moving backups to the NAS. See `home-infra-failure-archaeology`.

---

## Traps that cost real time

- **`sudo docker` on the NAS fails.** Always `sudo /usr/local/bin/docker …` (Row 8).
- **`docs/specs/ai-stack.md` is badly stale** — raw `:11434`, old models, MCP
  `:3001`, SSE. Treat as historical intent only. Current truth: compose files +
  `home-infra-config-reference`.
- **`--semantic-lint` alone previously also ran a full ingest** (Row 10) — fixed
  2026-07-03; safe to use alone now.
- **A broker 503 is arbitration, not an outage** (Row 2). Restarting things because
  of a 503 during a gaming session makes it worse.
- **LibreChat silently drops LAN MCP servers** missing from
  `mcpSettings.allowedDomains` — no error anywhere (Row 3).
- **`.env` files are dotfiles** — plain `ls` hides them; `ls -la`. Secrets live only
  in on-machine `.env`; `.env.example` is committed. Never copy key values into
  files or chat.
- **`:9622` is NOT minirag** on the live NAS — it is `lightrag-trading`,
  undocumented. FLAG and confirm with Preston; do not touch (Row 12). Repo minirag
  is `:9623` as of 2026-07-03.
- **Repo compose ≠ live compose.** Diff before reasoning from the repo; drift
  register in `home-infra-architecture-contract`.
- **04:00 is a double-load window**: vault-indexer cron AND watchtower both fire at
  4am (`vault-indexer/crontab`; watchtower `--schedule "0 0 4 * * *"`). Weirdness
  observed "around 4am" may be either — or their interaction.
- **`mcp/lightrag/README.md` is stale** (package `daniel-lightrag-mcp`, port 3001).
  The Dockerfile installs `lightrag-mcp`; compose runs it on :3002. Compose wins.
- **The vault is a Syncthing replica** — any file you write there appears on every
  synced device within seconds. Debug artifacts belong elsewhere (the one sanctioned
  exception: wiki-ingest's own `_raw/*-debug.txt` dumps).
- **The insert POST "succeeding" proves nothing** — doc status lives behind
  `track_status`/`paginated` polling (ADR 0002; Rows 4, 5).

---

## When NOT to use this skill

- You want the **fix procedure**, not the diagnosis → `home-infra-change-control`
  (gating) then `home-infra-build-and-deploy` (images, registry, compose deploy) or
  `home-infra-run-and-operate` (manual runs, cron, SSH, logs).
- You want the **full incident story** behind a row → `home-infra-failure-archaeology`.
- You want **ports / env vars / model tables** → `home-infra-config-reference`.
- You want **RAG Engine API endpoints, auth, MCP transports** → `rag-stack-reference`.
- You are **executing the MiniRAG migration** → `minirag-migration-campaign`.
- You want to **measure** (health scripts, index-state checks, drift checks) →
  `home-infra-diagnostics`; measurement methodology → `rag-evaluation-methodology`.
- You want **architecture rationale or the drift register** →
  `home-infra-architecture-contract`.
- Nothing is broken and you're **validating a change** → `home-infra-validation-and-qa`.

## Provenance and maintenance

- Facts verified 2026-07-02 against repo state (commit 6cbd3a1 + uncommitted
  MiniRAG-migration worktree changes: ADRs 0010–0012, `docs/specs/minirag-migration.md`,
  `wiki-ingest.py`, minirag/registry compose entries) and live containers observed
  via SSH 2026-07-02 (lightrag Up on :9621, lightrag-trading on :9622,
  fashion-monitor containers Restarting, broker root returning 404).
- Sources per row: 1 → ADR 0001 + `compose/nas/docker-compose.yml`;
  2 → `wiki-ingest.py` `chat()`; 3 → `compose/desktop/librechat.yaml`;
  4/5/7 → `vault-indexer/indexer.py` (`run_cleanup`, `pipeline_is_idle`,
  archive logic) + ADRs 0002/0003; 6 → ADR 0011; 8/11/12 → live SSH observation
  2026-07-02; 9/10 → `wiki-ingest.py` (`ingest_one`, entry point); 13 → ADR 0010 +
  compose `LLM_MODEL`; 14 → project owner standing instructions (labeled as such).
- Labeled assumptions: repo=intent/live=truth sync contract (labeled ASSUMPTION,
  2026-07-02 authoring pass; not re-observed since); `lightrag-trading` ownership
  unknown (FLAG, do not resolve);
  nano-vectordb `vdb_*.json` filename in Row 1 (UNVERIFIED); HTTP status of bare
  GET on `/mcp` in Row 3 (UNVERIFIED).
- Re-verification one-liners (volatile facts):
  - Live ports/containers: `ssh -i ~/.ssh/agent_ed25519 agent@10.0.0.250 'sudo /usr/local/bin/docker ps --format "{{.Names}}\t{{.Ports}}"'`
  - RAG Engine model config: `ssh -i ~/.ssh/agent_ed25519 agent@10.0.0.250 'sudo /usr/local/bin/docker exec lightrag env | grep -E "LLM_MODEL|EMBEDDING_MODEL"'`
  - Cron hour: `cat vault-indexer/crontab` (repo) — currently `0 4 * * *`
  - allowedDomains: `grep -A8 allowedDomains compose/desktop/librechat.yaml`
  - Retry ladder: `grep -n 'RETRY_DELAYS' wiki-ingest.py` — currently `[10, 30, 60, 120, 180]`
  - `--semantic-lint` bug fixed (expect no match): `grep -n -A1 'elif semantic and not lint_only' wiki-ingest.py`
  - Broker up: `curl -s -o /dev/null -w '%{http_code}\n' http://10.0.0.243:11435/` (expect 404)
  - Indexer excludes: `grep -n 'EXCLUDE_DIRS' vault-indexer/indexer.py` — currently `{.agents,.claude,.obsidian,_raw}`
