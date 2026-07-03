---
name: home-infra-run-and-operate
description: Day-2 operations runbook for Preston's home-infra AI stack. Load this when you need to SSH into the desktop (10.0.0.243) or NAS (10.0.0.250), run or re-run the vault indexer, run wiki-ingest on the MacBook, find logs or state files (indexer.log, hashes.json, rag_storage), check cron/watchtower schedules, do a routine health check, or touch anything in the Obsidian vault. Keywords - SSH access, agent user, manual index run, --cleanup, STATE_FILE, wiki-ingest, --lint, --semantic-lint, captures, _raw, docker logs, pipeline_status.
---

# Run and Operate — home-infra Day-2 Runbook

This skill is the **authoritative home for the SSH access pattern** and for routine
operations: scheduled runs, manual runs, logs/artifacts, wiki-ingest, vault handling,
and the daily health check. It covers a two-machine home lab:

| Term | Meaning (see `CONTEXT.md` for the full controlled vocabulary) |
|---|---|
| Desktop | `multimedia`, 10.0.0.243 — LibreChat stack, Ollama + resource broker, GPU |
| NAS | `house-of-light`, 10.0.0.250 — Synology DS1522+, RAG stack, storage |
| Vault | Obsidian note collection, synced by Syncthing, NAS copy at `/volume1/obsidian-vault` |
| Wiki | Compiled pages at `wiki/` inside the Vault — what the RAG Engine actually indexes |
| Capture | A file in `_raw/` inside the Vault, awaiting Ingest; deleted once promoted |
| RAG Engine | LightRAG today (NAS :9621); migrating to MiniRAG (ADR 0010) |
| Broker | ollama-resource-broker on the desktop; ALL Ollama traffic goes through it, never raw `:11434` |

Repo: `/Users/prestonbernstein/dev/home-infra` (declarative mirror — it deploys nothing
automatically; humans copy compose files to machines and run them by hand).

---

## 1. Access — how agents SSH into the machines

**Always use the `agent` user with the key at `~/.ssh/agent_ed25519`. Never SSH as
`preston`.** (Source: project owner standing instructions.) The key lives at
`~/.ssh/agent_ed25519` on the MacBook — reference the path only, never read or copy
key contents into any file.

| Machine | Alias (may exist in `~/.ssh/config`) | Direct command |
|---|---|---|
| Desktop (10.0.0.243) | `ssh desktop-agent` | `ssh -i ~/.ssh/agent_ed25519 agent@10.0.0.243` |
| NAS (10.0.0.250) | `ssh nas-agent` | `ssh -i ~/.ssh/agent_ed25519 agent@10.0.0.250` |

Both machines give the `agent` user **NOPASSWD sudo** — use `sudo` freely, nothing will
prompt for a password.

### NAS (Synology) quirks — memorize these

1. **Docker binary is at `/usr/local/bin/docker` and sudo's PATH does not include it.**
   `sudo docker ps` → `command not found`. Always write the full path:

   ```bash
   ssh -i ~/.ssh/agent_ed25519 agent@10.0.0.250 "sudo /usr/local/bin/docker ps"
   ```

2. **`scp` to the NAS needs the `-O` flag** (Synology's sshd has no working SFTP
   subsystem for this flow):

   ```bash
   scp -O -i ~/.ssh/agent_ed25519 localfile agent@10.0.0.250:/tmp/
   ```

3. **rsync-over-ssh is blocked by Synology.** To move large files, stream through ssh
   instead:

   ```bash
   cat bigfile.tar | ssh -i ~/.ssh/agent_ed25519 agent@10.0.0.250 "cat > /tmp/bigfile.tar"
   ```

   (Quirks 2–3: project owner standing instructions, confirmed in prior NAS backup work.)

On the desktop, `docker` is on the normal PATH; `sudo docker ...` works as expected.

---

## 2. Command anatomy and scheduled runs

### What runs on a schedule (as of 2026-07-02)

| Job | Where | Schedule | Defined in |
|---|---|---|---|
| Vault indexer (nightly incremental index) | inside `vault-indexer` container on NAS | `0 4 * * *` (4:00 AM daily, cron inside the container) | `vault-indexer/crontab` |
| Watchtower (image auto-update) | `watchtower` container on NAS (in compose; **not observed running** 2026-07-02) | `0 0 4 * * *` (6-field cron = 4:00 AM daily — same hour as the indexer; coincidence, noted in drift register) | `compose/nas/docker-compose.yml` |

The crontab line, verbatim from `vault-indexer/crontab`:

```
0 4 * * * /usr/local/bin/python /app/indexer.py >> /state/indexer.log 2>&1
```

(The spec `docs/specs/lightrag-vault-indexer.md` still says 2 AM in places — that is
stale; the crontab file is truth. See `home-infra-architecture-contract` drift register.)

### Manual index run (non-interactive, safe to fire-and-forget)

A manual ADDITIVE incremental index run is an ungated routine op —
`home-infra-change-control` Class D covers destructive index operations only
(deletes, storage wipes, model swaps, full re-index), not this.

```bash
ssh -i ~/.ssh/agent_ed25519 agent@10.0.0.250 \
  "sudo /usr/local/bin/docker exec vault-indexer python /app/indexer.py"
```

What it does (verified against `vault-indexer/indexer.py`):
1. Checks `GET /documents/pipeline_status` on LightRAG first — **if the pipeline is
   busy it logs a warning and exits without indexing** (no double-queuing). A run that
   "did nothing" is often just this.
2. Walks `/vault` for `*.md`, skipping top-level dirs `.agents`, `.claude`, `.obsidian`,
   `_raw` (Captures are never indexed — only compiled wiki pages reach the RAG Engine).
3. SHA-256 hashes each file; only changed/new files are POSTed, in batches of 10 with
   2 s sleep between batches, polling `track_status` up to 60 s per batch for doc_ids.
4. Files gone from the vault get `archived_at` stamped; entries archived > 30 days are
   deleted from LightRAG and from state (two-stage archive→delete, ADR 0003).

It is idempotent — re-running when nothing changed skips everything and exits.

### Interactive cleanup (needs `-it` — it prompts)

```bash
ssh -t -i ~/.ssh/agent_ed25519 agent@10.0.0.250 \
  "sudo /usr/local/bin/docker exec -it vault-indexer python /app/indexer.py --cleanup"
```

- Lists archived docs (path, age in days, doc_id), queries LightRAG for FAILED docs,
  then prompts `Delete N archived doc(s) from LightRAG and state? [y/N]`.
- **Without `-it` (and `ssh -t` for the TTY) the `input()` prompt gets EOF and the run
  aborts with no changes** — that is the safe failure mode, but confusing if unexpected.
- Answering `y` **deletes documents from the RAG Engine** — that is a gated action; see
  section 7 before answering yes.

### STATE_FILE override — parallel index runs

`indexer.py` config (verified in source): state defaults to `$STATE_DIR/hashes.json`
(`STATE_DIR` defaults to `/state`), and the env var `STATE_FILE` overrides the full
path. This exists so a **parallel test index** (e.g. against MiniRAG during the
migration) can track its own hashes/doc_ids without touching the live LightRAG state:

```bash
# Example shape — exec-scoped env, the container's own cron run is unaffected
sudo /usr/local/bin/docker exec \
  -e STATE_FILE=/state/hashes-minirag.json \
  -e LIGHTRAG_URL=http://minirag:9721 \
  vault-indexer python /app/indexer.py
```

Semantics to keep straight:
- `docker exec -e ...` sets the variable **for that one process only**; the nightly cron
  inside the container keeps using the default `/state/hashes.json`.
- `STATE_FILE` changes only the state file. The log file is always
  `$STATE_DIR/indexer.log` — parallel runs interleave into the same log.
- State is written atomically (`.tmp` then rename), so a killed run never corrupts it.
- The full parallel-index procedure and its gates live in `minirag-migration-campaign` —
  do not improvise the migration from this snippet.

---

## 3. Logs and artifacts map

### vault-indexer (NAS)

| What | Where | Notes |
|---|---|---|
| Live log | `sudo /usr/local/bin/docker logs vault-indexer` | stdout stream |
| Persistent log | `/volume1/docker/ai/vault-indexer/indexer.log` (on NAS; `/state/indexer.log` in-container) | `RotatingFileHandler`, rotates at 1 MB, `backupCount=1` (one `.1` backup) |
| State file | `/volume1/docker/ai/vault-indexer/hashes.json` | see structure below |

Log quirk (verified from `crontab` + `indexer.py`): the cron line *appends stdout* to
`/state/indexer.log` **and** the Python `RotatingFileHandler` writes to the same file —
so cron-triggered runs log each line twice, and the cron `>>` append is not subject to
the 1 MB rotation. Cosmetic, not a bug to "fix" during ops.

One stale doc to ignore: `docs/specs/lightrag-vault-indexer.md` says state lives at
`/volume1/docker/vault-indexer/` — the compose mount (`/volume1/docker/ai/vault-indexer:/state`)
is truth.

`hashes.json` structure (one entry per vault-relative `.md` path):

```json
{
  "Network/AI Infrastructure.md": {
    "hash": "sha256:abc123...",
    "doc_id": "doc-7ec487ba..."
  },
  "Personal/Journal/2026-06-01.md": {
    "hash": "sha256:def456...",
    "doc_id": "doc-fc3d1b...",
    "archived_at": "2026-07-15T02:00:00+00:00"
  }
}
```

`archived_at` present = file vanished from the vault; it will be auto-deleted from the
RAG Engine after 30 days unless the file reappears (an entry with a matching hash is
never re-posted, but note the code re-archives only entries *missing* the stamp).

### RAG Engine storage (NAS)

| Service | Host path | Notes |
|---|---|---|
| LightRAG | `/volume1/docker/ai/lightrag/` (container `/app/data`; working dir `/app/data/rag_storage`) | the graph + vector store — never edit by hand |
| MiniRAG | `/volume1/docker/ai/minirag/` | **only once deployed** — as of 2026-07-02 minirag exists in the (uncommitted) compose but is NOT running |
| Secrets | `/volume1/docker/ai/.env` | holds `LIGHTRAG_API_KEY` (and `TS_AUTHKEY`); never copy values anywhere |
| Compose (live) | `/volume1/docker/ai/docker-compose.yml` | repo mirror: `compose/nas/docker-compose.yml` |

### Desktop artifacts

| What | Where |
|---|---|
| LibreChat + MongoDB data | `/opt/docker/librechat-stack/data/` (`librechat/`, `mongodb/`) |
| LibreChat stack compose + `librechat.yaml` + `.env` | `/opt/docker/librechat-stack/` (the compose header saying `/var/data/docker` is stale — drift register) |
| SigLIP model cache (infinity-siglip) | `/opt/docker/embed-stack/hf-cache/` |
| Embed stack compose | `/opt/docker/embed-stack/docker-compose.yml` (owner: `embed` service user) |

---

## 4. wiki-ingest operations (runs on the MacBook — not a container)

`wiki-ingest.py` sits at the **repo root** (`/Users/prestonbernstein/dev/home-infra/wiki-ingest.py`,
untracked as of 2026-07-02) and implements the LLM Wiki pattern (ADR 0012): it promotes
Captures from `_raw/` into compiled `wiki/` pages, then lints. It talks to the broker's
interactive lane and runs **locally on the Mac against the local vault copy** —
Syncthing propagates the results.

### Prerequisites

- Vault at `~/dev/Obsidian/Home Network Vault` (default), or set `VAULT_PATH`.
- Python with `requests`. The repo has a ready venv: `/Users/prestonbernstein/dev/home-infra/.venv`
  (verified: `requests` installed). Run via `.venv/bin/python3` or activate it.
- Broker reachable at `http://10.0.0.243:11435` (override with `OLLAMA_URL`; model
  default `qwen3:8b`, override with `INGEST_MODEL`). On 503 (GPU busy) it retries with
  a 10/30/60/120/180 s ladder — long silences are normal.

### Invocations (verified against the entry point in `wiki-ingest.py`)

| Command | What actually happens |
|---|---|
| `.venv/bin/python3 wiki-ingest.py` | Ingest all Captures in `_raw/` one at a time (full merge context), then structural lint |
| `.venv/bin/python3 wiki-ingest.py --lint` | Structural lint ONLY (orphan pages, broken wikilinks) — no LLM calls, no writes |
| `.venv/bin/python3 wiki-ingest.py --lint --semantic-lint` | Structural + semantic (LLM) lint, NO ingest |
| `.venv/bin/python3 wiki-ingest.py --semantic-lint` | Same as above (structural + semantic lint, NO ingest) — safe on its own as of the 2026-07-03 fix, see below |
| `BATCH_SIZE=3 .venv/bin/python3 wiki-ingest.py` | Bulk mode: one LLM call per group of 3 — faster, but relevant-page merge context is disabled, so merges are weaker. Use only for big backlogs you'll lint after |

> **Fixed 2026-07-03:** `--semantic-lint` used alone previously also ran a full ingest.
> The entry-point conditional was corrected; full story: `home-infra-failure-archaeology`
> F10 (now CLOSED). `--lint --semantic-lint` still works identically if you prefer to be
> explicit.

### Behavior you should expect (all verified in source)

- **Captures are DELETED after successful ingest** (`capture.unlink()`). This is the
  design contract (ADR 0012) — a vanished `_raw/` file after a run means success, not
  data loss. The content now lives in `wiki/` pages.
- **On LLM output parse failure** the capture is NOT deleted; the raw model response is
  saved to `_raw/<capture-stem>-debug.txt` and the run moves on. Inspect the debug file,
  then re-run — `-debug` files and `.txt` files are never picked up as Captures.
- On broker/network failure after all retries, the file simply remains in `_raw/` for
  the next run.
- Q&A captures are named `qa-YYYY-MM-DD-topic.md` and become `Q&A: Topic.md` Concept
  pages.
- Known drift: `CONTEXT.md` says Lint uses broker `:11436`; the script uses `:11435`
  for everything. The script is runtime truth; drift is logged in
  `home-infra-architecture-contract`.

---

## 5. Vault handling rules

- The NAS vault copy `/volume1/obsidian-vault` is owned by the `sc-syncthing` service
  user. **Syncthing propagates every write to all devices** (MacBook, others) — a
  careless write or delete on the NAS replicates everywhere within seconds. Treat the
  live vault as production data. (Source: project owner standing instructions.)
- Containers mount the vault **read-only** (`/volume1/obsidian-vault:/vault:ro` for both
  lightrag and vault-indexer) — nothing on the NAS side writes into it. Keep it that way.
- `wiki-ingest.py`'s write contract is exactly: create/update files under `wiki/`
  (flat filenames, no subfolders) and delete the `_raw/` Captures it successfully
  promoted (plus `-debug.txt` files on parse failure). It touches nothing else. Any
  other vault write by an agent needs an explicit human go-ahead.
- If you must copy a file to the NAS vault, remember `scp -O` (section 1) and expect
  ownership friction with `sc-syncthing` — prefer letting Syncthing carry the change
  from the Mac instead.

---

## 6. Routine health check (read-only, one screen)

Copy-paste sequence — all commands are read-only. `home-infra-diagnostics` has the
scripted version with interpretation; this is the manual fallback.

```bash
# 1. NAS containers up? (expect: lightrag, lightrag-mcp, vault-indexer all "Up")
ssh -i ~/.ssh/agent_ed25519 agent@10.0.0.250 \
  "sudo /usr/local/bin/docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'"

# 2. RAG Engine pipeline status (key stays on the NAS — never echo it)
ssh -i ~/.ssh/agent_ed25519 agent@10.0.0.250 \
  'KEY=$(sudo grep "^LIGHTRAG_API_KEY=" /volume1/docker/ai/.env | cut -d= -f2-); \
   curl -s -H "X-API-Key: $KEY" http://localhost:9621/documents/pipeline_status'

# 3. Last indexer run (look for "=== run end ===" and the succeeded/failed counts)
ssh -i ~/.ssh/agent_ed25519 agent@10.0.0.250 \
  "sudo tail -n 30 /volume1/docker/ai/vault-indexer/indexer.log"

# 4. Broker alive on the interactive lane? (ANY HTTP status incl. 404 = broker is up;
#    the root path returning 404 is normal)
curl -s -o /dev/null -w '%{http_code}\n' http://10.0.0.243:11435/

# 5. Desktop containers up? (expect librechat, mongodb, vision-mcp, proton-email-mcp,
#    infinity-siglip healthy)
ssh -i ~/.ssh/agent_ed25519 agent@10.0.0.243 \
  "sudo docker ps --format 'table {{.Names}}\t{{.Status}}'"
```

Reading the results:
- `pipeline_status` returning JSON = LightRAG up and the API key is valid. A `busy` /
  `is_processing` truthy flag means an index/extraction is in flight — do not start a
  manual index run (the indexer would skip itself anyway).
- As of 2026-07-02 the NAS also shows `lightrag-trading` on `:9622` — it appears in NO
  repo file. **Flag it, confirm ownership with Preston before touching anything on
  :9622** (repo minirag moved to `:9623` 2026-07-03, so it no longer contests this port —
  `lightrag-trading`'s own ownership is still unexplained).
- Symptom → cause chasing beyond this screen: switch to `home-infra-debugging-playbook`.

---

## 7. What operators must NOT do without a gate

`home-infra-change-control` defines the change classes and gates; this is the ops-side
summary. Never do these on impulse, even with NOPASSWD sudo at your fingertips:

| Action | Why gated |
|---|---|
| Restart/stop/recreate any live container (`docker restart/stop/compose up`) | Behavior-changing; the NAS is memory-pressured (ADR 0005) and restarts have knock-on effects — change-control class action |
| Edit live compose files or `.env` on either machine | Repo is intent, live is runtime truth (ASSUMPTION — sync contract, labeled in `home-infra-change-control`); unsynced edits create drift — go through change control's repo↔live sync contract |
| Delete documents from the RAG Engine (`--cleanup` "y", `DELETE /documents/delete_document`) | Destructive to the index; the two-stage archive exists precisely to prevent hasty deletes (ADR 0003) |
| Write into the live vault (beyond wiki-ingest's contract, section 5) | Syncthing replicates mistakes to every device |
| Point anything at raw Ollama `:11434` | Non-negotiable invariant — broker only (`:11435`/`:11436`/`:11437`/`:11438`) |
| "Fix" repo code mid-operation (the old `wiki-ingest --semantic-lint` entry-point bug is one past example — now closed 2026-07-03) | Code changes are change-control territory, not ops |
| Touch anything on NAS port `:9622` | `lightrag-trading` is undocumented live reality — confirm with Preston first |

Read-only is always fine: `docker ps`, `docker logs`, `cat`, `ls`, `curl` GETs.

## When NOT to use this skill

- **Building images or deploying compose changes** (buildx, registry vs ssh-load,
  deploy paths, watchtower rollout) → `home-infra-build-and-deploy`.
- **Debugging a symptom** (indexing failures, MCP not reachable, broker 503 storms) →
  `home-infra-debugging-playbook`.
- **Scripted health measurement + interpretation thresholds** → `home-infra-diagnostics`.
- **Port/env-var/model lookup tables** → `home-infra-config-reference`.
- **RAG Engine API details (endpoints, auth, transports)** → `rag-stack-reference`.
- **Executing the MiniRAG migration** → `minirag-migration-campaign`.
- **Deciding whether an action is allowed at all** → `home-infra-change-control`.

## Provenance and maintenance

- Facts verified 2026-07-02 against repo state (commit 6cbd3a1 + uncommitted
  MiniRAG-migration worktree changes: `wiki-ingest.py`, updated `indexer.py`/`crontab`,
  minirag in NAS compose) and live containers observed via SSH 2026-07-02.
- Sources marked "project owner standing instructions" (agent SSH identity, service
  users, vault ownership, scp `-O` / rsync-blocked quirks) come from Preston's standing
  rules, not repo files. UNVERIFIED this session: the `desktop-agent`/`nas-agent`
  ssh aliases (may or may not exist in `~/.ssh/config`), and the exact
  `sudo docker → command not found` behavior on the NAS (verified 2026-07-02 during
  the authoring pass; not re-tested since).
- Re-verification one-liners for volatile facts:
  - Cron schedule: `cat /Users/prestonbernstein/dev/home-infra/vault-indexer/crontab`
  - Indexer flags/env (`STATE_FILE`, `--cleanup`, EXCLUDE_DIRS, log rotation): `grep -nE "STATE_FILE|cleanup|EXCLUDE_DIRS|RotatingFileHandler" /Users/prestonbernstein/dev/home-infra/vault-indexer/indexer.py`
  - wiki-ingest entry-point bug still present: `grep -n "elif semantic and not lint_only" /Users/prestonbernstein/dev/home-infra/wiki-ingest.py`
  - NAS mounts/ports/watchtower schedule: `grep -nE "vault-indexer|/state|schedule|9621|9622" /Users/prestonbernstein/dev/home-infra/compose/nas/docker-compose.yml`
  - Live NAS containers: `ssh -i ~/.ssh/agent_ed25519 agent@10.0.0.250 "sudo /usr/local/bin/docker ps --format '{{.Names}} {{.Ports}}'"`
  - Broker up: `curl -s -o /dev/null -w '%{http_code}\n' http://10.0.0.243:11435/`
  - Desktop artifact paths: `grep -n "/opt/docker" /Users/prestonbernstein/dev/home-infra/compose/desktop/docker-compose.yml /Users/prestonbernstein/dev/home-infra/compose/desktop/embed-stack/docker-compose.yml`
