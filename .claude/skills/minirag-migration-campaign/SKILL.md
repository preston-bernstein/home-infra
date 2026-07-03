---
name: minirag-migration-campaign
description: Load this skill when finishing, resuming, or auditing the LightRAG→MiniRAG migration on the NAS (10.0.0.250) — keywords/symptoms: MiniRAG, minirag container missing, registry :5000 not running, port 9622 conflict, lightrag-trading, qwen2.5:14b / bge-m3 pulls, hashes-minirag.json, lightrag-mcp compatibility with MiniRAG, RAG cutover to :9621, rollback of the RAG Engine. Provides the decision-gated executable campaign — numbered phases with preconditions, exact commands, expected observations, branches, rollbacks, and human-blocking gates — wrapped around the doc of record docs/specs/minirag-migration.md.
---

# MiniRAG Migration Campaign (LightRAG → MiniRAG)

This is the **executable campaign** for the project's hardest live problem (ASSUMPTION,
2026-07-02 authoring pass): finishing the
migration of the vault RAG Engine from LightRAG (llama3.2:3b + mxbai-embed-large) to
MiniRAG (qwen2.5:14b + bge-m3) on the NAS.

- **Doc of record:** `docs/specs/minirag-migration.md` (5 steps + rollback). This skill does
  not replace it — it wraps every step in gates, expected observations, and failure branches.
  If this skill and the spec disagree on intent, the spec wins; if they disagree on *live
  reality*, re-derive status (below) and trust the machines.
- **Why migrate:** ADR 0010 — LightRAG's entity/relationship extraction needs structured JSON;
  at 8b it failed ~35% of documents and 32b won't fit the 16GB-VRAM GPU. MiniRAG (same lab,
  HKUDS) is SLM-first and API-near-identical. ADR 0011 — bge-m3 (8192-token window) replaces
  mxbai-embed-large (degrades past ~1k tokens); free switch since a full re-index happens anyway.
- **Operator contract:** you (a future Claude Code session or engineer) EXECUTE this campaign
  only when directed to. Every gate marked **HUMAN GATE** blocks on Preston's explicit
  confirmation — see `home-infra-change-control` for how changes are classified and gated.
  Behavior-changing actions (deploys, restarts, compose edits on machines) MUST go through
  that skill's process; this campaign supplies the technical steps, not the authority.

Jargon (one-line each; authoritative definitions in `CONTEXT.md` and `rag-stack-reference`):
**RAG Engine** = the retrieval service on the NAS (currently LightRAG :9621, target MiniRAG).
**Vault** = the Obsidian vault at `/volume1/obsidian-vault` on the NAS.
**Vault Indexer** = nightly container that POSTs vault markdown to the RAG Engine
(`vault-indexer/indexer.py`). **Broker** = the Ollama resource broker on the desktop
(lanes :11435 interactive, :11436 batch/embeddings) — never raw `:11434`.
**NAS docker** = `sudo /usr/local/bin/docker` (plain `sudo docker` → command not found on Synology).

SSH pattern (full detail in `home-infra-run-and-operate`) — set these once per shell:

```bash
NAS="ssh -i ~/.ssh/agent_ed25519 agent@10.0.0.250"
DT="ssh -i ~/.ssh/agent_ed25519 agent@10.0.0.243"
DK="sudo /usr/local/bin/docker"   # docker on the NAS, used as: $NAS "$DK ps"
```

Never SSH as `preston`. The API key `LIGHTRAG_API_KEY` lives ONLY in
`/volume1/docker/ai/.env` on the NAS — never copy its value into any file.

---

## 1. Status snapshot — as of 2026-07-03 (volatile; re-derive before acting)

| Item | State as of 2026-07-03 |
|---|---|
| ADRs 0010 / 0011 / 0012 written | DONE, committed (`ebc8e9e`, `521df55`) |
| `docs/specs/minirag-migration.md` written | DONE, committed (`ebc8e9e`) |
| `minirag` service stanza in `compose/nas/docker-compose.yml` | DONE, committed (`ebc8e9e`; image `10.0.0.250:5000/minirag:latest`, ports `9623:9721` — corrected from `9622:9721` per Gate 0a resolution below) |
| `_raw/` exclusion + `STATE_FILE` override in `vault-indexer/indexer.py` | DONE, committed (`ebc8e9e`) — **NOT verified in the deployed `vault-indexer:latest` image on the NAS** |
| Models decided | DONE — qwen2.5:14b (LLM, broker :11435) + bge-m3 (embeddings, broker :11436) |
| Models pulled on desktop | UNVERIFIED — check with Phase 1 |
| MiniRAG image built / in registry | NOT DONE — no image; registry catalog unreachable |
| `registry` container on NAS | NOT RUNNING (in repo compose, not live) |
| `minirag` container on NAS | NOT RUNNING (in repo compose only) |
| Gate 0a (:9622 port conflict) | **RESOLVED 2026-07-03 — Option 2: minirag moved to `:9623`.** `lightrag-trading` still occupies `:9622` and its ownership is still undocumented (see F11) — that mystery stays open, but it's no longer a blocker since minirag no longer wants that port. Repo compose + spec updated to `9623:9721` consistently. |
| lightrag-mcp ↔ MiniRAG compatibility (spec Step 3) | UNVERIFIED — the known unknown |
| LightRAG baseline | live on :9621, 369/379 vault files indexed (97.4% PROCESSED per `docs/specs/lightrag-vault-indexer.md`) |

### Re-derive current status from scratch (all read-only)

```bash
# Which RAG/migration containers exist, on which ports?
$NAS "$DK ps -a --format '{{.Names}}\t{{.Status}}\t{{.Ports}}'" | grep -Ei 'lightrag|minirag|registry|vault-indexer'

# Has MiniRAG ever written storage on the NAS?
$NAS "ls -la /volume1/docker/ai/minirag 2>&1"          # 'No such file' = never deployed

# Is the local registry up, and does it hold a minirag image?
curl -s --max-time 5 http://10.0.0.250:5000/v2/_catalog # connection refused = registry down

# Has the parallel-index state file been started?
$NAS "ls -la /volume1/docker/ai/vault-indexer/ 2>&1"   # look for hashes-minirag.json

# Migration repo changes are committed as of 2026-07-03 (ebc8e9e, 521df55, 8fcc49c);
# this should show clean unless new work is in flight
git -C ~/dev/home-infra status --short

# Are the new models on the desktop?
$DT "ollama list" | grep -Ei 'qwen2.5:14b|bge-m3'
```

Map results back to the table above. If a later phase's artifacts already exist (e.g.
`hashes-minirag.json` is present and large), the campaign was resumed mid-flight — enter at
the first phase whose EXPECTED observation is not yet satisfied, but still run every
Phase 0 gate.

---

## 2. Phases

Every phase lists PRECONDITIONS → COMMANDS → EXPECTED → BRANCHES. Do not skip preconditions.

### Phase 0 — Preflight gates (ALL HUMAN-BLOCKING)

These three gates require decisions from Preston. Route each through
`home-infra-change-control`. **DO NOT GUESS** any of them.

**All three gates below were RESOLVED 2026-07-03** (per `home-infra-failure-archaeology`
F8/F12 open-items note): Gate 0a → Option 2, minirag moved to `:9623`; Gate 0b → verify
and free NAS memory headroom before deploying; Gate 0c → Route B (save/ssh-load). The
gate writeups below are kept for the reasoning/evidence — read them for context, but the
decisions are made; proceed to Phase 1 without re-litigating.

**Gate 0a — resolve the :9622 port conflict (HUMAN GATE) — RESOLVED, Option 2.**
Repo compose and the spec both assign host port `9622` to minirag. But live, as of
2026-07-02, `lightrag-trading` (0.0.0.0:9622→9621, a second LightRAG instance appearing in
**no repo file**) occupies :9622. Its owner/purpose is undocumented (drift-register item —
see `home-infra-architecture-contract`).

```bash
$NAS "$DK ps --format '{{.Names}}\t{{.Ports}}'" | grep 9622   # confirm still occupied
$NAS "$DK inspect lightrag-trading --format '{{json .Config.Env}}' 2>/dev/null" | head -c 400  # read-only clue-gathering only
```

Present Preston exactly two options and record the answer:

1. **Retire/move `lightrag-trading`** — Preston (or whoever owns it) frees :9622; minirag
   keeps the spec-canonical port. Requires knowing what lightrag-trading serves first.
2. **Move minirag to a free port** (e.g. `:9623` — verify free with the `docker ps` grep
   above) — then update BOTH `docs/specs/minirag-migration.md` AND
   `compose/nas/docker-compose.yml` (`9623:9721`) consistently BEFORE deploying, so repo,
   spec, and live never diverge on this.

Everywhere below, `<MRPORT>` means the resolved host port. Do not proceed past this gate
with `<MRPORT>` unresolved.

**Gate 0b — NAS memory headroom (HUMAN-ACKNOWLEDGED RISK) — RESOLVED: free headroom first.**
The NAS has 7.7GB RAM and was already at 3.2GB swap under load when ADR 0005 was written.
MiniRAG's resident memory footprint is **UNVERIFIED** (no measurement exists), and during
the parallel phase LightRAG + lightrag-trading + MiniRAG all run at once.

```bash
$NAS "free -m"
```

EXPECTED: `Mem: total` ≈ 7700–7900 MB. Record `used`, `available`, and `Swap: used` as the
**pre-deploy baseline** — you will re-check against it in Phases 3–4. If `available` is
already < ~500 MB or swap used > ~4 GB, tell Preston the parallel deploy is high-risk and
get an explicit go/no-go. Label everything about MiniRAG memory UNVERIFIED until observed.

**Gate 0c — choose the image-shipping route (HUMAN GATE) — RESOLVED: Route B.**
The `registry` service (registry:2, :5000, `/volume1/docker/registry`) is in repo compose
but NOT running live as of 2026-07-02. Route B (save/ssh-load) was chosen — Route A detail
kept below only in case Route B hits an unexpected blocker and you need the fallback-of-the-fallback:

- **Route A — start the registry** (behavior change on the NAS → change control):
  `$NAS "cd /volume1/docker/ai && $DK compose up -d registry"` — then Phase 2 pushes to
  `10.0.0.250:5000`. CAVEAT (UNVERIFIED): the registry is plain HTTP, so the MacBook's
  Docker daemon must list `10.0.0.250:5000` under `insecure-registries` (Docker Desktop →
  Settings → Docker Engine), and the NAS daemon may need the same to `docker compose pull`
  from it. Neither daemon config has been verified. Also UNVERIFIED: whether Synology's
  docker has the `compose` plugin at `/usr/local/bin/docker compose` or only a separate
  `docker-compose` binary — check with `$NAS "$DK compose version || which docker-compose"`.
- **Route B — `docker save | ssh load` fallback** (no registry, no daemon config, no new
  service): Phase 2 shows the exact command. Slower per shipment; zero new moving parts.

If Route B is chosen, the compose image ref `10.0.0.250:5000/minirag:latest` still works —
you tag the local build with that exact name before saving, so `docker compose up` finds it
loaded locally and never contacts the registry. (`docker compose pull` will fail in Route B;
that is expected — don't run it.)

### Phase 1 — Models on the desktop

PRECONDITIONS: Phase 0 gates answered (models can be pulled in parallel with 0a/0c
deliberation — pulling is safe and reversible).

ASSUMPTION/inference (not a recorded standing instruction): model pulls are host-admin
operations outside the broker's inference arbitration — the broker-only rule ("never point
anything at :11434") governs inference *calls*, so `ollama pull` run on the desktop host
is treated as the admin path. They still
download large blobs over the internet:

```bash
$DT "ollama pull qwen2.5:14b"   # ~9.0 GB download (approx — Q4 quant)
$DT "ollama pull bge-m3"        # ~1.2 GB download (approx)
$DT "ollama list" | grep -Ei 'qwen2.5:14b|bge-m3'
```

EXPECTED: both models listed with sizes in the ~9 GB / ~1.2 GB range. Both fit the
RX 9070 XT's 16GB VRAM (per spec/ADR 0011) — though not necessarily simultaneously with
other loaded models; the broker arbitrates.

BRANCHES:
- Pull hangs or fails → desktop internet/disk issue; check `$DT "df -h /"`.
- `ollama: command not found` over SSH → non-login shell PATH; try
  `$DT "which ollama || ls /usr/local/bin/ollama /usr/bin/ollama 2>/dev/null"` and use the full path.
- GPU busy (gaming/Plex) → irrelevant to pulls; pulls are disk+network only.

### Phase 2 — Build and ship the MiniRAG image

PRECONDITIONS: Gate 0c answered. Docker with buildx on the MacBook.

No pre-built image exists (HKUDS/MiniRAG has no CI/CD → nothing on GHCR). Build from
source per spec Prerequisites. **TRAP (spec-documented, REQUIRED):** the MiniRAG Dockerfile
requires a `.env` file that is not in the repo — `touch` it or the build fails.

```bash
git clone --depth 1 https://github.com/HKUDS/MiniRAG.git /tmp/minirag-build
touch /tmp/minirag-build/.env                       # REQUIRED — build breaks without it
docker buildx build --platform linux/amd64 \
  -t 10.0.0.250:5000/minirag:latest \
  /tmp/minirag-build
```

(`--platform linux/amd64` is mandatory: the NAS is x86 (Ryzen R1600); an Apple-Silicon-native
build will not run there.)

Ship — **Route A** (registry running, insecure-registry configured):

```bash
docker push 10.0.0.250:5000/minirag:latest
curl -s http://10.0.0.250:5000/v2/_catalog          # EXPECT: {"repositories":["minirag"]}
$NAS "cd /volume1/docker/ai && $DK compose pull minirag"
```

Ship — **Route B** (save | ssh load fallback):

```bash
docker save 10.0.0.250:5000/minirag:latest \
  | ssh -i ~/.ssh/agent_ed25519 agent@10.0.0.250 'sudo /usr/local/bin/docker load'
```

EXPECTED: `$NAS "$DK images"` shows `10.0.0.250:5000/minirag` with tag `latest`, size in
the hundreds-of-MB-to-few-GB range (exact size UNVERIFIED until first build).

BRANCHES:
- Build fails referencing `.env` → you skipped the `touch`.
- `docker push` errors "server gave HTTP response to HTTPS client" → MacBook daemon lacks
  the `insecure-registries` entry (Gate 0c caveat) → fix daemon config or fall back to Route B.
- `compose pull` on NAS fails with an HTTPS/insecure error → NAS daemon lacks the entry →
  Route B.
- buildx errors about platform/driver → `docker buildx ls`; create a builder if needed
  (`docker buildx create --use`). Generic build mechanics live in `home-infra-build-and-deploy`.

### Phase 3 — Deploy MiniRAG in parallel on `<MRPORT>`

PRECONDITIONS: Gate 0a resolved (`<MRPORT>` known, compose+spec updated if it changed);
Phase 1 models present; Phase 2 image on the NAS; live compose at
`/volume1/docker/ai/docker-compose.yml` updated to include the minirag stanza (copy it from
repo `compose/nas/docker-compose.yml` — repo is intent, live is runtime truth; keep them
convergent per the sync contract in `home-infra-change-control`). This is a behavior change
on the NAS → change control applies.

The stanza (repo compose, committed `ebc8e9e`/`8fcc49c` — env summary; the authoritative
env-var table lives in `home-infra-config-reference`):

| Env | Value |
|---|---|
| `LLM_BINDING` / `LLM_MODEL` / `LLM_BINDING_HOST` | `ollama` / `qwen2.5:14b` / `http://10.0.0.243:11435` |
| `EMBEDDING_BINDING` / `EMBEDDING_MODEL` / `EMBEDDING_BINDING_HOST` | `ollama` / `bge-m3` / `http://10.0.0.243:11436` |
| `WORKING_DIR` | `/app/data/rag_storage` |
| `LIGHTRAG_API_KEY` | `${LIGHTRAG_API_KEY}` from `/volume1/docker/ai/.env` (same var/header as LightRAG — confirmed in spec) |
| volume | `/volume1/docker/ai/minirag:/app/data` |
| ports | `<MRPORT>:9721` — **TRAP: MiniRAG's internal port is 9721, NOT LightRAG's 9621** (spec-documented) |
| network | `ai-net` (external, real name `ai_ai-net`) |

```bash
$NAS "cd /volume1/docker/ai && $DK compose up -d minirag"
$NAS "$DK logs --tail 50 minirag"
```

EXPECTED: clean startup in logs (server binds 0.0.0.0:9721; no tracebacks, no restart loop;
`$NAS "$DK ps"` shows minirag `Up`, not `Restarting`).

Then verify the API (run on the NAS so the key never leaves it):

```bash
$NAS 'KEY=$(sudo grep "^LIGHTRAG_API_KEY=" /volume1/docker/ai/.env | cut -d= -f2-); \
  curl -s -o /dev/null -w "%{http_code}\n" -H "X-API-Key: $KEY" http://localhost:<MRPORT>/documents/pipeline_status; \
  curl -s -H "X-API-Key: $KEY" http://localhost:<MRPORT>/documents/pipeline_status'
```

EXPECTED: `200` and a JSON body (a pipeline-status object; idle, nothing queued).

BRANCHES:
- `401`/`403` → `LIGHTRAG_API_KEY` env not loaded into the container — is `.env` next to
  the live compose file? `$NAS "$DK inspect minirag --format '{{json .Config.Env}}'" | grep -o LIGHTRAG_API_KEY` (checks presence only — do not print the value).
- Container crash-loops → `$NAS "$DK logs minirag"`; classify: missing env → fix compose;
  Python import/module error → image build problem, back to Phase 2; OOM-killed
  (`$NAS "$DK inspect minirag --format '{{.State.OOMKilled}}'"` → `true`) → Gate 0b risk
  realized; stop minirag, report to Preston.
- Port bind error on `<MRPORT>` → something took the port since Gate 0a; re-run the Gate 0a grep.
- After startup, re-run `$NAS "free -m"` and compare to the Gate 0b baseline. Record the
  delta — this is the first real MiniRAG memory measurement (was UNVERIFIED).

### Phase 4 — Initial index into MiniRAG (separate state file)

PRECONDITIONS (all hard):
1. Phase 3 EXPECTED met.
2. **The `vault-indexer:latest` image ON THE NAS honors `STATE_FILE` and excludes `_raw/`.**
   Both features are committed in the repo (`ebc8e9e`, 2026-07-03) but the live image
   (running since before that) likely predates them and needs a rebuild. If the deployed
   image lacks `STATE_FILE` support, the run below
   would **silently write to `hashes.json` and corrupt LightRAG's state**. Verify first
   (read-only container run):

```bash
$NAS "$DK run --rm --entrypoint grep vault-indexer:latest -c 'STATE_FILE\|_raw' /app/indexer.py"
```

   EXPECTED: a count ≥ 2. If `0` or grep errors → rebuild and ship `vault-indexer:latest`
   from the current worktree first (same Route A/B shipping pattern as Phase 2):
   `docker buildx build --platform linux/amd64 -t vault-indexer:latest ~/dev/home-infra/vault-indexer/`
   then save|load or push, and re-run the grep.

3. LightRAG's own pipeline idle (the indexer checks `pipeline_status` before running and
   refuses if busy — see `vault-indexer/indexer.py pipeline_is_idle()`).

Two network variants — read before choosing:

- **Spec-canonical** (`docs/specs/minirag-migration.md` Step 2): `--network container:lightrag`
  with `LIGHTRAG_URL=http://10.0.0.250:<MRPORT>`. **Oddity, flagged:** this joins the
  indexer to *lightrag's* network namespace while targeting MiniRAG via the NAS *host* IP
  and published port. It works (outbound to a host IP needs no published ports on the
  joined container) but it is confusing, couples the run to the lightrag container being up,
  and depends on the Gate 0a port resolution.
- **Simpler (recommended):** join the compose network and hit MiniRAG's internal port
  directly — immune to host-port choices:

```bash
$NAS 'KEY=$(sudo grep "^LIGHTRAG_API_KEY=" /volume1/docker/ai/.env | cut -d= -f2-); \
  sudo /usr/local/bin/docker run --rm \
  --network ai_ai-net \
  -e LIGHTRAG_URL=http://minirag:9721 \
  -e LIGHTRAG_API_KEY="$KEY" \
  -e VAULT_PATH=/vault \
  -e STATE_FILE=/state/hashes-minirag.json \
  -v /volume1/obsidian-vault:/vault:ro \
  -v /volume1/docker/ai/vault-indexer:/state \
  vault-indexer:latest python /app/indexer.py'
```

(For the spec-canonical variant, swap `--network ai_ai-net` for
`--network container:lightrag` and set `LIGHTRAG_URL=http://10.0.0.250:<MRPORT>`.
Everything else identical. Either way: `STATE_FILE=/state/hashes-minirag.json` is
NON-NEGOTIABLE — see fenced-off paths.)

EXPECTED observations (numbers where known):
- Log opens `Vault: ~380 .md files found` (baseline population was 379) and
  `To index: ~380 | Unchanged (skip): 0` (fresh state file → everything indexes).
- ~38 batches (`BATCH_SIZE = 10`), `Batch N/38 complete` lines, 2s sleep between batches.
- Wall clock: **several hours** (spec estimate; qwen2.5:14b extraction per document over
  the broker's interactive lane; broker 503s under GPU contention add retry delay).
- `track_status timeout (60s)` warnings followed by `No doc_id for <file> — will retry next
  run` are **normal at 14b** — extraction can outlast the indexer's 60s poll window.
  Those files are simply re-attempted on the next run; they are not failures.
- Afterward: `hashes-minirag.json` exists and `hashes.json`'s mtime is UNCHANGED
  (`$NAS "ls -l /volume1/docker/ai/vault-indexer/"`).

Monitor progress (from the MacBook). Prefer the diagnostics script — it exists at
`.claude/skills/home-infra-diagnostics/scripts/index-state.py` with `--state-file`,
`--rag-url`, and `--failed` flags (interpretation guide: `home-infra-diagnostics`):

```bash
cd ~/dev/home-infra/.claude/skills/home-infra-diagnostics/scripts
./index-state.py --state-file /volume1/docker/ai/vault-indexer/hashes-minirag.json \
                 --rag-url http://10.0.0.250:<MRPORT> --failed
```

Fallback (if the script is unavailable) — note `status_filter` values are LOWERCASE and
`page_size` must be >= 10 (live-verified against LightRAG 2026-07-02; UNVERIFIED whether
MiniRAG shares the quirk — inspect the JSON shape on first call):

```bash
# Server-side status counts
$NAS 'KEY=$(sudo grep "^LIGHTRAG_API_KEY=" /volume1/docker/ai/.env | cut -d= -f2-); \
  curl -s -X POST -H "X-API-Key: $KEY" -H "Content-Type: application/json" \
  -d "{\"page\":1,\"page_size\":50,\"status_filter\":\"processed\"}" \
  http://localhost:<MRPORT>/documents/paginated' | python3 -m json.tool | head -30

# NAS memory while the heaviest phase of the whole campaign runs (compare to Gate 0b baseline)
$NAS "free -m"
```

TARGET: ≥97% of files reach `PROCESSED` (LightRAG baseline: 369/379 = 97.4%; per
`home-infra-validation-and-qa` this is the candidate acceptance threshold).

BRANCHES:
- **High FAILED rate** (>3%): pull `error_msg`s (lowercase `status_filter`, `page_size >= 10` — see quirk note above) —
  `$NAS 'KEY=$(sudo grep "^LIGHTRAG_API_KEY=" /volume1/docker/ai/.env | cut -d= -f2-); curl -s -X POST -H "X-API-Key: $KEY" -H "Content-Type: application/json" -d "{\"page\":1,\"page_size\":200,\"status_filter\":\"failed\"}" http://localhost:<MRPORT>/documents/paginated' | python3 -m json.tool | grep -i error_msg | sort | uniq -c | sort -rn | head`
  Then check the LLM is actually the intended one: `$DT "ollama ps"` while indexing —
  EXPECT `qwen2.5:14b` loaded (if `llama3.2:3b` shows instead, minirag env is wrong).
  And check embedding-dimension consistency: bge-m3 is 1024-dim; if MiniRAG storage was
  ever touched by a different embedder, dimension mismatch blocks everything (this exact
  class of failure is ADR 0001's origin story — see `home-infra-failure-archaeology`).
  Recovery for a poisoned index: wipe `/volume1/docker/ai/minirag/`, delete
  `hashes-minirag.json`, fix env, redeploy, re-run (LightRAG untouched throughout).
  This wipe/delete is **Class D (index-destructive) — human approval required per
  `home-infra-change-control`, even for the staging index.**
- **Run refuses to start** ("pipeline is busy") → LightRAG's nightly 4am cron run or a
  previous MiniRAG queue is draining; wait and retry.
- **NAS swap ballooning** (swap used grows ≫ +1 GB over baseline) → pause: `Ctrl-C` the
  run (safe — state is written per-batch, resume is incremental), report to Preston (Gate 0b).
- Many `No doc_id — will retry next run` at the end → just re-run the same command once the
  pipeline drains; the state file makes re-runs incremental.

### Phase 5 — MCP compatibility gate (spec Step 3 — the known unknown)

PRECONDITIONS: Phase 4 target met (≥97% PROCESSED). This gate decides whether the existing
`lightrag-mcp` (pip package, container on :3002) can front MiniRAG. **Nobody has verified
this** — the spec marks it TBD. Do not cut over without passing it.

First, a direct sanity probe (no MCP involved) — does MiniRAG itself answer well?

```bash
$NAS 'KEY=$(sudo grep "^LIGHTRAG_API_KEY=" /volume1/docker/ai/.env | cut -d= -f2-); \
  curl -s -X POST -H "X-API-Key: $KEY" -H "Content-Type: application/json" \
  -d "{\"query\":\"what maintenance has been done on the Corolla?\"}" \
  http://localhost:<MRPORT>/query' | python3 -m json.tool | head -40
```

(`/query` request/response shapes: `rag-stack-reference`. If THIS fails, the problem is the
index, not MCP — back to Phase 4 branches.)

Then run a temporary lightrag-mcp against MiniRAG. **Flag on the spec's command:** the spec
uses `--network container:lightrag` with `--mcp-port 3003` — but ports published inside
lightrag's namespace are NOT reachable from the LAN (lightrag only publishes 9621), so an
external client can never reach that temp MCP as written. Use the compose network and
publish the port instead (NAS host :3003 was free as of 2026-07-02 — re-verify). The temp
MCP on :3003 is **Class E (new service/port, temporary) — gate per
`home-infra-change-control`**:

```bash
$NAS 'KEY=$(sudo grep "^LIGHTRAG_API_KEY=" /volume1/docker/ai/.env | cut -d= -f2-); \
  sudo /usr/local/bin/docker run --rm -d --name mcp-minirag-test \
  --network ai_ai-net -p 3003:3003 \
  lightrag-mcp:latest lightrag-mcp \
  --host minirag --port 9721 \
  --api-key "$KEY" \
  --mcp-transport streamable-http \
  --mcp-host 0.0.0.0 --mcp-port 3003 \
  --mcp-streamable-http-path /mcp --mcp-stateless-http'
$NAS "$DK logs mcp-minirag-test"
```

Exercise it with the two representative queries (per `home-infra-validation-and-qa`):
1. "what maintenance has been done on the Corolla?"
2. "what's my current home network topology?"

Client options:
- **Lightest (no live changes):** add the temp endpoint as an MCP server in a Claude Code
  session (`claude mcp add --transport http minirag-test http://10.0.0.250:3003/mcp`) and
  ask the two queries via the exposed query tool.
- **Full parity (touches LibreChat → change control):** point the LibreChat Vault Assistant
  at `http://10.0.0.250:3003/mcp`. **TRAP:** LibreChat's `mcpSettings.allowedDomains`
  (in `compose/desktop/librechat.yaml`) currently allows only `http://10.0.0.250:3002` on
  the NAS — without adding `http://10.0.0.250:3003`, LibreChat **silently blocks** the
  server (SSRF protection). Revert both edits after the test.

EXPECTED: grounded answers — concrete maintenance events / actual machine+network facts
from the vault, not empty results, refusals, tool errors, or hallucinated generalities.

BRANCH — garbage/errors (the decision ladder, cheapest first):

| # | Fix | Effort (estimate) |
|---|---|---|
| 1 | Diff API surfaces: `curl -s http://10.0.0.250:9621/openapi.json > /tmp/lr.json; curl -s http://10.0.0.250:<MRPORT>/openapi.json > /tmp/mr.json` (add `-H "X-API-Key: ..."` if 401) then `diff <(python3 -m json.tool /tmp/lr.json) <(python3 -m json.tool /tmp/mr.json)` — focus on `/query` response fields and `/documents/track_status`. If the mismatch maps to an existing lightrag-mcp flag, patch the flags. | minutes–1h |
| 2 | Patch/fork lightrag-mcp's response mapping (pip package; `mcp/lightrag/Dockerfile` pip-installs it) and rebuild the image. | hours |
| 3 | Evaluate a `minirag-mcp` package (existence UNVERIFIED — search PyPI first). | hours, if it exists |
| 4 | Write a thin FastMCP wrapper exposing a `query` tool over MiniRAG `/query` (template: `mcp/vision/server.py` is already a small FastMCP server in this repo). | ~half a day |

Cleanup either way: `$NAS "$DK stop mcp-minirag-test"` (auto-removes; `--rm`).

Record the outcome (pass, or which fix was applied) — Phase 7 needs it for the spec's
Step 3 TBD and possibly a new ADR.

### Phase 6 — Cutover (HUMAN GATE + rollback rehearsal first)

PRECONDITIONS: Phase 5 passed; Phase 4 ≥97% PROCESSED; **Preston explicitly approves the
cutover** (change control — this swaps the RAG Engine everything else points at).

**Rollback rehearsal (mandatory, before touching anything):**

```bash
$NAS "ls -l /volume1/docker/ai/lightrag/ /volume1/docker/ai/vault-indexer/hashes.json"  # LightRAG storage + state intact
$NAS "cp -a /volume1/docker/ai/docker-compose.yml /volume1/docker/ai/docker-compose.yml.pre-minirag-$(date +%F)"  # compose backup = the rollback artifact
```

Write the rollback commands (section 3 below) into your working notes NOW, verbatim, so
they are executable without thinking under pressure.

**Cutover edits** (spec Step 4, exact list, applied to
`/volume1/docker/ai/docker-compose.yml` and mirrored into repo
`compose/nas/docker-compose.yml`):

```bash
$NAS "cd /volume1/docker/ai && $DK compose stop lightrag vault-indexer"
```

1. Remove (or comment out) the `lightrag` service.
2. minirag ports: `<MRPORT>:9721` → `9621:9721` (MiniRAG takes over LightRAG's public port).
3. `lightrag-mcp` command args: `--host lightrag --port 9621` → `--host minirag --port 9721`.
4. **`lightrag-mcp` `depends_on`: `- lightrag` → `- minirag`** — the spec omits this; with
   the lightrag service removed, compose refuses to start on a dangling `depends_on`.
5. `vault-indexer` env: `LIGHTRAG_URL=http://lightrag:9621` → `LIGHTRAG_URL=http://minirag:9721`.
6. Remove any `STATE_FILE` override from the vault-indexer service (default is `/state/hashes.json`).
7. If Phase 5 ended with a patched/replacement MCP image, deploy that image here too.

```bash
$NAS "mv /volume1/docker/ai/vault-indexer/hashes-minirag.json /volume1/docker/ai/vault-indexer/hashes.json.minirag-pending && \
      mv /volume1/docker/ai/vault-indexer/hashes.json /volume1/docker/ai/vault-indexer/hashes.json.lightrag-retired && \
      mv /volume1/docker/ai/vault-indexer/hashes.json.minirag-pending /volume1/docker/ai/vault-indexer/hashes.json"
$NAS "cd /volume1/docker/ai && $DK compose up -d minirag lightrag-mcp vault-indexer"
```

(The three-step mv keeps the LightRAG state file as `hashes.json.lightrag-retired` for
rollback, instead of the spec's overwrite-style single `mv`.)

EXPECTED post-cutover checks:

```bash
$NAS "$DK ps --format '{{.Names}}\t{{.Status}}\t{{.Ports}}'" | grep -Ei 'minirag|lightrag|vault'
# EXPECT: minirag Up on 0.0.0.0:9621->9721; lightrag-mcp Up on :3002; vault-indexer Up; NO plain 'lightrag'
$NAS 'KEY=$(sudo grep "^LIGHTRAG_API_KEY=" /volume1/docker/ai/.env | cut -d= -f2-); \
  curl -s -o /dev/null -w "%{http_code}\n" -H "X-API-Key: $KEY" http://localhost:9621/documents/pipeline_status'
# EXPECT: 200
```

Then: a LibreChat Vault Assistant query (unchanged config — still :3002/mcp) returns a
grounded answer; and the next 4am cron run (`vault-indexer/crontab`) completes cleanly —
check `$NAS "tail -50 /volume1/docker/ai/vault-indexer/indexer.log"` the following morning:
EXPECT `To index: 0–small | Unchanged (skip): ~380`, no auth errors, no mass re-index
(mass re-index ⇒ the state-file rename went wrong — stop and reconcile before it duplicates
documents).

BRANCH: any post-cutover check fails and isn't fixed within your change window → execute
rollback (section 3), then debug offline. lightrag-trading, whatever Gate 0a decided, is
out of scope here — do not touch it during cutover.

### Phase 7 — Repo sync + docs

PRECONDITIONS: cutover stable (at least one clean nightly run). All of this routes through
`home-infra-change-control` (commit discipline) and `home-infra-docs-and-writing`
(vocabulary, ADR/spec house style). Commits are authored by Preston only — no Claude
attribution lines in this repo (project owner standing instructions).

Checklist (spec Step 5 + doc debt):
1. `compose/nas/docker-compose.yml`: mirror the live post-cutover state exactly (minirag on
   `9621:9721`, lightrag removed, lightrag-mcp args + depends_on, vault-indexer URL, no
   STATE_FILE override, registry per Gate 0c outcome).
2. `docs/specs/minirag-migration.md`: resolve Step 3 TBD with the Phase 5 outcome; record
   the Gate 0a port decision.
3. `docs/specs/ai-stack.md`: update models (LLM → qwen2.5:14b, embedding → bge-m3) — the
   file is badly stale overall (raw :11434, old ports); fix at least the model lines, flag the rest.
4. Drift register (`home-infra-architecture-contract`): close "repo has registry+minirag,
   live runs neither"; update/annotate the lightrag-trading entry per Gate 0a.
5. ADR status notes: ADR 0010/0011 get an "implemented YYYY-MM-DD" note; ADR 0001 already
   superseded by 0011 — verify the supersession is marked.
6. ~~Commit the migration worktree (ADRs 0010–0012, spec, compose, indexer.py changes,
   wiki-ingest.py) into history.~~ **Already done** — committed `ebc8e9e`/`521df55`
   2026-07-03, well before cutover. This step is only relevant again if new
   migration-related files accumulate uncommitted before Phase 5.
7. If Phase 5 required a new MCP solution (menu items 2–4), write a new ADR for it.

---

## 3. Rollback (per phase, verified against spec Rollback section)

| After phase | Rollback | Blast radius |
|---|---|---|
| 1 (models) | Nothing required (`ollama rm qwen2.5:14b bge-m3` on the desktop only to reclaim ~10 GB disk) | none |
| 2 (image) | `$NAS "$DK rmi 10.0.0.250:5000/minirag:latest"`; stop registry if Route A and abandoning | none |
| 3 (parallel deploy) | `$NAS "cd /volume1/docker/ai && $DK compose stop minirag"` — LightRAG never stopped serving | none |
| 4 (initial index) | Stop/stop-retrying the run; to restart clean: wipe `/volume1/docker/ai/minirag/` + delete `hashes-minirag.json` — **Class D (index-destructive): human approval required per `home-infra-change-control`, even for the staging index**. `hashes.json` and `/volume1/docker/ai/lightrag/` are untouched by design | none, IF the Phase 4 precondition-2 image check was done |
| 5 (MCP test) | `$NAS "$DK stop mcp-minirag-test"`; revert any librechat.yaml test edits on the desktop | none |
| 6 (cutover) | `$NAS "cd /volume1/docker/ai && $DK compose stop minirag"`; restore compose from the `.pre-minirag-*` backup (or re-add lightrag service + revert edits 2–6); `mv hashes.json hashes.json.minirag-parked && mv hashes.json.lightrag-retired hashes.json`; `$DK compose up -d lightrag lightrag-mcp vault-indexer`; verify :9621 pipeline_status = 200 | minutes of RAG downtime |

Rollback stays cheap ONLY while LightRAG's storage (`/volume1/docker/ai/lightrag/`) and
retired state file survive — hence the retention rule in the fence below.

---

## 4. FENCED-OFF wrong paths (do not do these — each has a reason)

- **Do NOT patch LightRAG instead of migrating** — no chunk-size tuning, no GLEANING
  passes, no 32k-context workarounds, no qwen2.5:32b attempt (won't fit 16GB VRAM). All
  explicitly rejected in ADR 0010. If you're tempted, re-read it.
- **Do NOT reuse `hashes.json` for MiniRAG before cutover** — separate
  `STATE_FILE=/state/hashes-minirag.json` until Phase 6. Sharing state would mark files
  "already indexed" against the wrong engine and silently produce an empty MiniRAG index —
  and corrupt LightRAG's doc_id bookkeeping.
- **Do NOT index `_raw/`** — ADR 0012: the RAG Engine indexes compiled wiki pages;
  `_raw/` is transient Capture staging. `EXCLUDE_DIRS` in `indexer.py` enforces it —
  which is why Phase 4 precondition 2 (deployed image has the exclusion) is a hard gate.
- **Do NOT point anything at `:11434`** — raw Ollama is fenced; all lanes go through the
  broker (`:11435` interactive, `:11436` batch/embeddings). Repo-wide invariant (commit
  f2565b4; project owner standing instructions; rationale in `rag-stack-reference`).
- **Do NOT delete LightRAG storage (`/volume1/docker/ai/lightrag/`) or
  `hashes.json.lightrag-retired` until N clean days post-cutover** — proposed N = 14 days
  (**CANDIDATE**, not agreed; confirm with Preston before any deletion). Until then they
  are the entire rollback path.
- **Do NOT touch `lightrag-trading` or reassign :9622 unilaterally** — Gate 0a is a human
  decision; the container appears in no repo file and its owner/purpose is unrecorded.

---

## 5. Success criteria (measurable; thresholds are CANDIDATES per `home-infra-validation-and-qa`)

| # | Criterion | Measure | Threshold |
|---|---|---|---|
| 1 | MiniRAG serving on :9621 | authed `GET /documents/pipeline_status` HTTP code | 200 |
| 2 | Index completeness | PROCESSED / total vault files (Phase 4 monitor commands) | ≥ 97% (LightRAG baseline 369/379 = 97.4%; goal is ≥ baseline) |
| 3 | Retrieval quality | the two representative queries via lightrag-mcp/LibreChat | both grounded (cite real vault facts, judge per `rag-evaluation-methodology`) |
| 4 | NAS memory | `free -m` swap-used delta vs Gate 0b baseline, steady-state | ≤ +1 GB (CANDIDATE — first-ever MiniRAG measurement) |
| 5 | Nightly pipeline | next ≥1 cron runs in `indexer.log` | 0 auth errors; `Unchanged (skip)` ≈ vault size; no mass re-index |
| 6 | Repo ↔ live convergence | diff repo compose vs `/volume1/docker/ai/docker-compose.yml` | no service-level drift; drift register updated |
| 7 | Rollback retention | LightRAG storage + retired state present until day 14 | intact (CANDIDATE window) |

---

## When NOT to use this skill

- Day-to-day operation of the (pre- or post-migration) stack — logs, cron, manual indexer
  runs, SSH details → `home-infra-run-and-operate`.
- RAG Engine API endpoints, auth, query modes, embeddings/MCP-transport theory → `rag-stack-reference`.
- Port/env-var/model lookup tables → `home-infra-config-reference`.
- Generic image build/ship/deploy mechanics beyond this campaign → `home-infra-build-and-deploy`.
- Debugging a symptom not caused by this migration → `home-infra-debugging-playbook`.
- Whether the migration is the right call, drift register, invariants → `home-infra-architecture-contract` (+ ADR 0010/0011 full text).
- What counts as passing evidence, query rubrics → `home-infra-validation-and-qa` and `rag-evaluation-methodology`.
- Deciding whether a change needs a gate at all → `home-infra-change-control`.

## Provenance and maintenance

- Facts verified 2026-07-02 against repo state (commit 6cbd3a1 + committed (ebc8e9e/521df55/8fcc49c/34988d1) MiniRAG-migration changes: ADR 0010/0011/0012, `docs/specs/minirag-migration.md`,
  minirag stanza in `compose/nas/docker-compose.yml`, `STATE_FILE`/`_raw` changes in
  `vault-indexer/indexer.py`) and live containers observed via SSH 2026-07-02.
- Explicitly UNVERIFIED as of 2026-07-02: MiniRAG memory footprint and image size; MiniRAG
  build success (never built); insecure-registry daemon config on MacBook and NAS; Synology
  `docker compose` plugin presence; lightrag-mcp↔MiniRAG compatibility (Phase 5's whole
  purpose); `minirag-mcp` package existence; `/documents/paginated` response field names on
  MiniRAG; model download sizes (approx from Ollama library).
- Re-verification one-liners for the volatile facts in the status snapshot:
  - Containers/ports (`lightrag-trading` on :9622, no minirag, no registry):
    `ssh -i ~/.ssh/agent_ed25519 agent@10.0.0.250 "sudo /usr/local/bin/docker ps -a --format '{{.Names}}\t{{.Status}}\t{{.Ports}}'" | grep -Ei 'lightrag|minirag|registry'`
  - Registry down: `curl -s --max-time 5 http://10.0.0.250:5000/v2/_catalog` (connection refused = down)
  - No MiniRAG storage yet: `ssh -i ~/.ssh/agent_ed25519 agent@10.0.0.250 "ls /volume1/docker/ai/minirag 2>&1"`
  - Migration changes committed, working tree clean: `git -C ~/dev/home-infra status --short`
  - Models absent/present on desktop: `ssh -i ~/.ssh/agent_ed25519 agent@10.0.0.243 "ollama list" | grep -Ei 'qwen2.5:14b|bge-m3'`
  - LightRAG baseline 369/379: `grep -n '369/379' ~/dev/home-infra/docs/specs/lightrag-vault-indexer.md`
- Maintenance rule: after each executed phase, update section 1's table (this skill is the
  campaign's home); after Phase 7, mark this skill COMPLETED at the top and keep it as the
  post-mortem index, or fold lessons into `home-infra-failure-archaeology` if anything blew up.
