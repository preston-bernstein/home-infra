---
name: home-infra-failure-archaeology
description: Load this when you need to know WHY something in home-infra is the way it is — the history behind a config value, a rejected alternative, a stale doc, a dead end, or an open mystery. Triggers - "why is it configured like this", "was X already tried", "should we switch back to nomic/mxbai/Open WebUI/Traefik/mcpo", "why not just use :11434", "why CPU for SigLIP", "what happened with the API key", "why is ai-stack.md wrong", "what is lightrag-trading", "why is the migration stalled", any proposal that might re-litigate a settled ADR. Provides every major incident, investigation, revert, and rejected alternative as Symptom → Root cause → Evidence → Status → Lesson, plus the list of open mysteries.
---

# home-infra Failure Archaeology

The complete incident and dead-end chronicle for the `home-infra` repo
(`/Users/prestonbernstein/dev/home-infra`) — Preston Bernstein's Personal AI Stack across a
desktop ("multimedia", 10.0.0.243) and a Synology NAS ("house-of-light", 10.0.0.250).

Purpose: **understand why things are the way they are, and avoid re-litigating settled
decisions or re-hitting known traps.** Before proposing any architectural change, check the
summary table below. If your proposal matches a "settled" entry, read that entry's full story
before arguing against it.

Jargon used throughout (full vocabulary in `CONTEXT.md` at repo root):

- **RAG Engine** — the service that builds/queries an entity graph + vector store from vault
  content (currently LightRAG, migrating to MiniRAG).
- **Vault** — the Obsidian vault at `/volume1/obsidian-vault` on the NAS; source of truth.
- **Broker** — `ollama-resource-broker` on the desktop; arbitrates all Ollama/GPU access
  (lanes :11435 interactive, :11436 batch, :11437 jobs, :11438 embed). Never use raw `:11434`.
- **ADR** — one-dense-paragraph architecture decision records in `docs/adr/0001`–`0012`.

Repo history is short and fully known — five commits on `main` plus an uncommitted
MiniRAG-migration worktree (as of 2026-07-02):

| Commit | Date | Subject |
|---|---|---|
| `cda7fec` | 2026-06-11 | Initial scaffold — specs, ADRs 0001–0007, compose stubs |
| `e778699` | 2026-06-11 | Add vault-indexer implementation |
| `f2565b4` | 2026-06-21 | Wire all Ollama consumers through ollama-resource-broker |
| `3ec836f` | 2026-06-21 | Fix secrets hygiene, add `.env.example` files, ADRs 0008–0009 |
| `6cbd3a1` | 2026-06-30 | Add embed-stack: Infinity SigLIP CPU server |
| (branch) `654891a` | 2026-06-27 | Fail-hard on missing `LIGHTRAG_API_KEY` — **on `add-embed-stack` AND `origin/main` (origin/main tip IS 654891a); local `main` is a divergent rewrite without it** (see F5) |
| (uncommitted) | ~2026-06-27+ | ADRs 0010–0012, `docs/specs/minirag-migration.md`, `wiki-ingest.py`, minirag compose service, crontab 2am→4am |

## Summary table

Chronological. "Settled" means: do not re-litigate without new evidence.

| ID | One-liner | Status |
|---|---|---|
| F1 | nomic-embed-text 768-dim vs 1024-dim store blocked ALL indexing → mxbai | Resolved (settled), superseded by F9/ADR 0011 |
| F2 | Open WebUI has no MCP client → removed entirely, LibreChat instead | Resolved (settled) |
| F3 | mcpo gateway, Traefik, Nginx Proxy Manager all rejected | Settled |
| F4 | Raw Ollama `:11434` everywhere → broker lanes wired repo-wide | Resolved; standing invariant |
| F5 | Secrets in repo (`OVERSEERR_KEY`, `LIGHTRAG_API_KEY=changeme`) → hygiene commit; fail-hard fix stranded on branch | Partially resolved; rotation caution stands |
| F6 | ADR 0006 says SSE; everything actually runs streamable-http | Superseded in practice; ADR text stale |
| F7 | Infinity ROCm image unsupported on RDNA4 → CPU fallback; `/embeddings` vs `/embeddings_image` trap | Resolved (settled) |
| F8 | LightRAG SLM extraction fails ~35% at 8b → MiniRAG pivot; workarounds rejected | Open until migration completes |
| F9 | mxbai-embed-large truncates past ~1k tokens, silently losing long-doc tails → bge-m3 | Resolved by migration in flight |
| F10 | `wiki-ingest.py --semantic-lint` alone runs a full ingest (entry-point bug) | CLOSED — fixed 2026-07-03 |
| F11 | `lightrag-trading` live on NAS :9622 — in no repo file; conflicts with planned minirag port | OPEN MYSTERY — flag, do not touch |
| F12 | registry + minirag in repo compose but not running live — migration stalled | OPEN — the hardest live problem |
| F13 | `docs/specs/ai-stack.md` rot — written as plan, never synced after execution | OPEN process failure |
| F14 | Crontab 2am→4am uncommitted; watchtower also at 4am | Minor, open |
| F15 | `indexer.py --cleanup` sends uppercase `"FAILED"` → 422 on current LightRAG; failed-doc census silently errors | CLOSED — fixed 2026-07-03 |

---

## F1 — Embedding dimension mismatch blocked ALL indexing

- **Symptom:** No document would index into LightRAG at all — every insert failed
  (pre-repo, early June 2026, before the first successful index run).
- **Root cause:** `nomic-embed-text` produces 768-dim vectors; LightRAG's vector store
  defaults to 1024-dim. Dimension mismatch → indexing pipeline rejects everything.
- **Evidence:** `docs/adr/0001-mxbai-embed-large.md`. The very first commit already carries
  the fix: `git show cda7fec:compose/nas/docker-compose.yml` line 17 has
  `EMBEDDING_MODEL=mxbai-embed-large` — the decision predates the repo and was made
  deliberately *before* the first run, because switching embedding models after seeding
  requires a full re-index.
- **Alternative rejected:** setting an `EMBEDDING_DIM=768` override to keep nomic. ADR 0001
  chose mxbai because it matches the 1024 default with no override AND is a stronger
  retrieval model regardless.
- **Status:** Resolved. Later **superseded by ADR 0011** (bge-m3 — see F9); the 1024-dim
  reasoning is historical, not current guidance.
- **Lesson:** Embedding dimension is load-bearing, silent-until-total-failure config. Any
  embedding model change = full re-index; decide before seeding, or piggyback on a
  migration that re-indexes anyway (exactly what ADR 0011 did).

## F2 — Open WebUI dead end (no MCP client)

- **Symptom:** MCP tool use — a first-class requirement of the stack — was impossible from
  the then-deployed UI (Open WebUI).
- **Root cause:** Open WebUI is not an MCP client; it has its own Python-function tool
  system. No amount of configuration fixes an absent protocol implementation.
- **Evidence:** `docs/adr/0004-librechat-over-open-webui.md`; `docs/specs/ai-stack.md`
  ("Replaces Open WebUI (removed from NAS compose)").
- **Status:** Resolved (settled). Open WebUI removed from NAS compose **entirely** — not
  demoted, removed. LibreChat (desktop, host network, :3080) is the primary UI with native
  MCP support in its Agents feature. Its former LightRAG Ollama-compatible connection is
  superseded by lightrag-mcp accessed through LibreChat agents.
- **Lesson:** Verify a first-class requirement against the actual feature matrix before
  deploying. When the gap is protocol-level, replace, don't patch.
- **NOTE:** drift register #11 in `home-infra-architecture-contract` reports an
  open-webui container still running on NAS :3000 as of 2026-07-02 — removal from
  compose (ADR 0004) evidently never included stopping the live container; flag to
  Preston.

## F3 — Gateway and reverse-proxy rejections (mcpo, Traefik, NPM)

- **Symptom:** Needed (a) a pattern for exposing multiple custom Home MCP servers, and
  (b) a reverse proxy for services spread across desktop, NAS, and HA Pi.
- **Rejected alternatives and why:**
  - **mcpo gateway** (`docs/adr/0007-one-service-per-mcp-nginx.md`): wraps stdio MCPs
    behind one port, but is designed for third-party stdio packages — the custom Home MCPs
    are services that naturally run their own HTTP servers. Chosen instead: one Docker
    service per MCP, own port, nginx path routing. Port proliferation explicitly judged a
    non-issue at this scale.
  - **Traefik** (`docs/adr/0009-caddy-as-reverse-proxy.md`): label-per-container config
    gets unwieldy when proxying across multiple machines (NAS 10.0.0.250, HA Pi 10.0.0.5)
    rather than co-located containers; its strength is same-host Docker orchestration.
  - **Nginx Proxy Manager** (same ADR): no native forward auth support.
  - Chosen: **Caddy** on the desktop — `forward_auth` for Authentik, explicit upstreams
    good for cross-host routing, readable Caddyfile.
- **Wrinkle:** the ADR-0007 nginx `/mcp/<name>` path-routing pattern was never actually
  activated — the location blocks in `compose/nas/nginx.conf` (lines 37–45) are
  **commented out** ("Phase 3 — uncomment when services are up"), and clients hit
  `http://10.0.0.250:3002/mcp` directly per `compose/desktop/librechat.yaml`. The
  one-service-per-MCP half of the ADR is live; the nginx-routing half is dormant intent.
- **Status:** Settled. Do not propose mcpo, Traefik, or NPM without new evidence.
- **Lesson:** Decisions can be half-implemented; check which half is live before citing an
  ADR as describing reality (drift register: see `home-infra-architecture-contract`).

## F4 — Raw `:11434` era → broker wiring

- **Symptom:** Every Ollama consumer (LightRAG LLM + embeddings, LibreChat, vision-mcp)
  pointed at raw Ollama `:11434`, with no arbitration on a GPU shared with gaming and Plex.
  (Contention rationale per project owner standing instructions; the commits record the fix,
  not a specific outage.)
- **Root cause:** Stack was scaffolded before the `ollama-resource-broker` existed/was
  adopted; raw port was the default everywhere.
- **Evidence:** `git show cda7fec:compose/nas/docker-compose.yml` lines 15/18
  (`http://10.0.0.243:11434`), initial desktop compose `OLLAMA_BASE_URL=http://localhost:11434`;
  fixed by commit `f2565b4` (2026-06-21): NAS LLM → `:11435` (interactive), embeddings →
  `:11436` (batch), LibreChat + vision-mcp → `:11435`.
- **Status:** Resolved; now a **standing invariant** — never point anything at `:11434`
  (non-negotiable; rationale and enforcement in `home-infra-change-control`). Broker 503s
  when the GPU is busy; clients must retry (see `wiki-ingest.py` retry ladder
  10/30/60/120/180s).
- **Residual trap:** `mcp/vision/server.py:6` still has code default
  `OLLAMA_HOST=http://localhost:11434`; the compose env override to `:11435` is the
  contract. Reading code defaults alone will mislead you.
- **Lesson:** Invariants adopted mid-project leave stale defaults behind in code. Compose
  env is the contract; code defaults are archaeology.

## F5 — Secrets committed to the repo (and a fix stranded on a branch)

- **Symptom:** Credential material in a public-facing git repo: `LIGHTRAG_API_KEY=changeme`
  committed in NAS compose (with `# TODO: rotate` comments), and a hardcoded
  `OVERSEERR_KEY` in `media-ip-migrate.sh`.
- **Root cause:** Scaffold-speed shortcuts; no `.env` pattern existed yet.
- **Evidence:**
  - `git show 3ec836f` (2026-06-21): replaces `changeme` with `${LIGHTRAG_API_KEY}` across
    lightrag, vault-indexer, and lightrag-mcp; adds `.env.example` files for all stacks;
    tightens `.gitignore` (block `.env`, whitelist `*.env.example`).
  - Nuance on OVERSEERR_KEY: the commit message says "Remove hardcoded OVERSEERR_KEY from
    media-ip-migrate.sh", but the script is a **new file** in `3ec836f` and
    `git log -S OVERSEERR_KEY --all` finds no earlier commit — the hardcoded-key version
    lived uncommitted on disk and was sanitized before it ever entered git history. The
    `changeme` placeholder, by contrast, WAS in committed history (`cda7fec`..`3ec836f`).
  - Follow-up hardening `654891a` (2026-06-27, "Security: fail-hard on missing
    LIGHTRAG_API_KEY, expand .gitignore") — changes the indexer to
    `os.environ.get("LIGHTRAG_API_KEY") or sys.exit(...)` and adds `*.key/*.pem/*.crt/*.log`
    to `.gitignore`.
- **Status:** **Partially resolved.** The `.env` pattern is resolved and standing
  (secrets live only in `.env` on the machines; `.env.example` committed — project owner
  standing instruction). `654891a` exists on **`add-embed-stack` AND `origin/main`** —
  the `origin/main` tip IS `654891a` (`git branch -a --contains 654891a`). But the
  **local `main` is a divergent rewrite**: the embed-stack commit was re-created locally
  as `6cbd3a1` *without* the fix, so local `main` (and the current worktree)
  still has the soft default `LIGHTRAG_API_KEY = os.environ.get("LIGHTRAG_API_KEY", "changeme")`
  at `vault-indexer/indexer.py:25`, and its `.gitignore` lacks the `*.key/*.pem/*.crt/*.log`
  lines. Pushing local `main` would conflict with a remote that already contains the
  security fix — reconciling local `main` with `origin/main` is an open TODO (route
  through `home-infra-change-control`).
- **Standing caution:** the live key was later rotated off `changeme`
  (`docs/specs/lightrag-vault-indexer.md:11`); real values live in `.env` on the machines
  (e.g. `/volume1/docker/ai/.env` on the NAS — never copy values into files). Anything that
  was ever committed or hardcoded should be treated as rotation-worthy.
- **Related footnote:** the two 2026-06-11 commits carry
  `Co-Authored-By: Claude Sonnet 4.6` trailers; the standing rule since then is that
  commits/PRs in this repo are attributed to Preston only — no Claude co-author trailers
  (project owner standing instructions).
- **Lesson:** Hygiene fixes made on a side branch don't exist until merged. When a branch
  is squash/re-created onto main, diff the branches for stranded commits.

## F6 — SSE → streamable-http transport evolution (ADR text vs reality)

- **Symptom:** `docs/adr/0006-sse-transport-for-home-mcps.md` says all Home MCPs use SSE
  transport; but everything actually running uses `streamable-http`.
- **Evidence:** `git log -S streamable-http` → the lightrag-mcp compose command has used
  `--mcp-transport streamable-http` since `f2565b4` (2026-06-21);
  `compose/desktop/librechat.yaml` declares all three MCP servers (lightrag
  `http://10.0.0.250:3002/mcp`, vision `:3003`, proton-email `:3004`) as
  `type: "streamable-http"`; `mcp/lightrag/Dockerfile` CMD uses streamable-http.
- **Root cause:** MCP spec evolution — streamable HTTP replaced SSE as the recommended
  remote transport after ADR 0006 was written (UNVERIFIED against the MCP spec itself from
  inside this repo; the repo files only show the switch, not the motivation).
- **Status:** Superseded in practice; **ADR 0006 not yet updated.** The ADR's real decision —
  networked HTTP transport hosted once on the NAS, instead of stdio installed per client —
  is still fully valid; only the transport name is stale.
- **Related stale docs:** `mcp/lightrag/README.md` still says package `daniel-lightrag-mcp`
  and port 3001; the Dockerfile pip-installs `lightrag-mcp` (and its `EXPOSE 3001` is
  unused); compose runs it on **:3002**. Compose wins.
- **Lesson:** Read ADRs for the decision *shape*, not the literal parameter values —
  cross-check parameters against compose (see drift register in
  `home-infra-architecture-contract`).

## F7 — Infinity ROCm unsupported on RDNA4 → CPU fallback + endpoint trap

- **Symptom:** Wanted GPU serving of SigLIP image embeddings (for estate-scraper) via
  Infinity on the desktop's RX 9070 XT.
- **Root cause:** Infinity's prebuilt ROCm image targets MI200/MI300 datacenter GPUs only —
  it does not support RDNA4/gfx1201 (ROCm 6.2 consumer card).
- **Resolution:** CPU fallback, deliberately bounded: image `michaelf34/infinity:latest-cpu`,
  `cpus: "8.0"` cap (of 32 cores) plus `OMP_NUM_THREADS=8`, `MKL_NUM_THREADS=8`,
  `OPENBLAS_NUM_THREADS=8` so torch/BLAS can't oversubscribe past the cap; bound to
  loopback `127.0.0.1:7997`; reached **only** via the broker embed lane `:11438`. CPU is
  sub-second per image — fine for the weekly ~6k batch.
- **Endpoint trap (the actual investigation):** image embeddings must hit
  `/embeddings_image`, not the unified `/embeddings` — the unified route **tokenizes a
  `data:` URI as text** and silently returns a text embedding of the URI string. The broker
  embed lane rewrites `/embeddings` → `/embeddings_image` so callers can't hit the trap.
- **Evidence:** commit `6cbd3a1` message; comments in
  `compose/desktop/embed-stack/docker-compose.yml` (deploy path
  `/opt/docker/embed-stack/`, owner: `embed` service user).
- **Status:** Resolved (settled). Don't propose "just use the ROCm image" — it was tried
  conceptually and ruled out by hardware support matrix.
- **Lesson:** "Wrong endpoint still returns 200 with plausible-shaped vectors" is the worst
  failure mode. Guard traps at the infrastructure layer (broker rewrite) rather than by
  convention.

## F8 — LightRAG SLM extraction failure (~35%) → MiniRAG pivot

- **Symptom:** Sparse/incorrect entity graph and poor query quality from the RAG Engine;
  extraction fails on roughly **35% of documents** when indexing with an 8b model.
- **Root cause:** LightRAG's indexing pipeline requires the LLM to emit structured JSON
  (entity + relationship extraction). HKUDS recommends 32b+ for reliable output. The
  desktop GPU (16GB VRAM) fits qwen2.5:14b at Q4 comfortably but **not 32b**. Small models
  simply cannot hold the JSON contract often enough.
- **Rejected workarounds** (explicitly, per `docs/adr/0010-minirag-over-lightrag.md`):
  chunk-size tuning, GLEANING passes, 32k context — "no Phase 1 workarounds ... are
  applied". A 32b model was rejected on VRAM. The pivot is architectural: **MiniRAG**
  (same HKUDS lab, designed for small SLMs, no structured-JSON extraction requirement,
  comparable accuracy, near-identical API — `/query`, `/documents`, same `X-API-Key` auth,
  so lightrag-mcp is expected to be reusable, compat still unverified: migration Step 3 TBD).
- **Measurement nuance:** the ~35% figure was measured on **llama3.1:8b** (ADR 0010's
  text), but the committed compose has run `LLM_MODEL=llama3.2:3b` since `f2565b4` — an
  even smaller model. Direction is consistent ("extraction quality bad"), but do not quote
  35% as the current production failure rate; it belongs to the 8b configuration. To
  re-measure, see `rag-evaluation-methodology`.
- **Status:** **Open until the migration completes** (ADR 0010 itself is uncommitted;
  MiniRAG is not deployed — see F12). LightRAG is being **replaced, not patched**.
- **Lesson:** When a component's minimum viable model doesn't fit your hardware, tuning
  around it re-litigates physics. Swap for a component designed for your constraint
  (SLM-first). This is the founding decision of the stack's "frugal SLM-first" identity.

## F9 — mxbai-embed-large ~1k-token truncation silently losing long-document tails

- **Symptom:** Retrieval quietly misses content that lives in the tail of long vault files
  (maintenance logs, deployment docs, development notes). Nothing errors; recall is just
  bad for tail content.
- **Root cause:** `mxbai-embed-large` degrades significantly past ~1k tokens; many vault
  files exceed that, so their embeddings under-represent everything past the effective
  window.
- **Fix:** `bge-m3` — handles up to 8192 tokens (covers the full content of all vault
  files), stronger on long-form retrieval, fits in 16GB VRAM. Cost of switching is zero
  *because* the MiniRAG migration (F8) forces a full re-index anyway — the two decisions
  are deliberately coupled.
- **Evidence:** `docs/adr/0011-bge-m3-over-mxbai.md` (supersedes ADR 0001); uncommitted
  minirag service in `compose/nas/docker-compose.yml` has `EMBEDDING_MODEL=bge-m3` while
  the running lightrag service still has `mxbai-embed-large`.
- **Status:** **Resolved by migration in flight** — decided, not yet live. As of 2026-07-02
  production embeddings are still mxbai (truncation issue still live in production).
- **Lesson:** Embedding failure modes are silent quality degradation, not errors. Check the
  model's effective token window against your actual document length distribution, not
  against the marketing context length.

## F10 — `wiki-ingest.py --semantic-lint` runs a full ingest (CLOSED)

- **Symptom:** Running `python3 wiki-ingest.py --semantic-lint` — which the docstring
  (line 14) documents as "structural + semantic (LLM) lint" — **also performs a full
  ingest**: it processes `_raw/` captures into wiki pages and deletes the captures.
- **Root cause:** entry-point conditional bug at `wiki-ingest.py:394-397`:

  ```python
  if not lint_only and not semantic:
      run_ingest()
  elif semantic and not lint_only:
      run_ingest()
  ```

  The `elif` branch fired for `--semantic-lint` alone and called `run_ingest()` again —
  contradicting the docstring. (`wiki-ingest.py` sits at the repo root; it runs
  on the MacBook against the local vault, model qwen3:8b via broker `:11435`.)
- **Fix (2026-07-03):** removed the erroneous `elif` branch — `run_ingest()` now only
  fires when neither `--lint` nor `--semantic-lint` is passed, matching the docstring.
  Verified all 4 flag combinations against expected `(ingest, structural, semantic)` call
  behavior. `--semantic-lint` alone is now safe to run — the "pass both flags" workaround
  below is no longer required, but still works identically (harmless no-op double-lint).
- **Status:** **CLOSED** 2026-07-03.
- **Why it matters:** ingest is destructive-ish — it mutates wiki pages and **deletes**
  `_raw/` captures (per ADR 0012's designed flow). An unintended ingest triggered by "just
  a lint" can consume captures before you meant to.
- **Lesson:** Test each documented flag combination against the entry-point conditionals;
  docstrings drift from `argv` parsing exactly like specs drift from compose.

## F11 — `lightrag-trading` on NAS :9622 (OPEN MYSTERY)

- **Symptom:** Live container `lightrag-trading` observed on the NAS
  (`0.0.0.0:9622→9621`, Up 5h at observation time 2026-07-02) that **appears in no file in
  this repo** — not in compose, not in any spec or ADR.
- **Conflict:** the (uncommitted) repo compose assigns **:9622 to minirag**
  (`9622:9721`, `compose/nas/docker-compose.yml`). Deploying minirag as written will
  collide with whatever lightrag-trading is.
- **Status:** **OPEN MYSTERY — flag only.** Do NOT stop, restart, or reuse :9622.
  **Confirm ownership and purpose with Preston before touching anything on :9622.** It is
  plausibly owned by a different project entirely (name suggests trading; ASSUMPTION — no
  repo evidence). Resolution options (pick a different minirag port vs. relocate
  lightrag-trading) are a decision for Preston via `home-infra-change-control`, not for an
  agent to make unilaterally.
- **Lesson:** The repo is intent; the machine is runtime truth (sync-contract assumption —
  see `home-infra-architecture-contract`). Always `docker ps` before assuming a port from
  compose is free.

## F12 — Migration stalled: registry + minirag in compose, neither running live

- **Symptom:** `compose/nas/docker-compose.yml` declares `registry` (:5000) and `minirag`
  (:9622); live NAS (`docker ps`, observed 2026-07-02) runs **neither**. LightRAG still
  serves production on :9621.
- **Root cause (state analysis, not a single bug):** the MiniRAG migration
  (`docs/specs/minirag-migration.md`, 5 steps + rollback) is stalled between Step 0 and
  Step 1:
  1. MiniRAG image not built/pushed — must be **built from source** (HKUDS/MiniRAG
     publishes no GHCR image; its Dockerfile requires a dummy `.env` — `touch` one before
     `docker buildx build`).
  2. The NAS registry that the image push targets (`10.0.0.250:5000/minirag:latest`) is
     itself not running yet.
  3. Planned port :9622 is occupied by lightrag-trading (F11).
  4. Step 3 is explicitly TBD in the spec: lightrag-mcp ↔ MiniRAG API compatibility
     unverified.
- **Status:** **OPEN — the hardest live problem** (ASSUMPTION, 2026-07-02 authoring pass;
  not re-assessed since).
  ADRs 0010/0011/0012, the migration spec, `wiki-ingest.py`, and the compose changes are
  all **uncommitted** worktree state as of 2026-07-02 — the entire migration exists only
  on the MacBook's disk.
- **Do not** attempt to "clean up" the unused registry/minirag compose entries — they are
  the migration plan, not cruft. To execute the migration, use `minirag-migration-campaign`
  (the executable step-by-step home).
- **Lesson:** A migration is not "in progress" because compose says so; it's in progress
  when containers run. Track migration state by live observation, and commit decision
  records before they can be lost with a laptop.

## F13 — `docs/specs/ai-stack.md` rot (process failure)

- **Symptom:** The stack's flagship spec is badly wrong about nearly every operational
  parameter: raw `:11434` Ollama endpoints, LightRAG MCP on `:3001` with SSE, package
  `daniel-lightrag-mcp`, default model `llama3.1:8b`, aichat rollout plans, and Phase 1–5
  checklists entirely unticked — although Phases 1–3 substantially happened; Phase 4
  (aichat/CLI) is unverified.
- **Root cause:** The spec was written 2026-06-11 (`cda7fec`) as a **plan**, then never
  synced after execution. Decisions got recorded (new ADRs were added), but the spec
  document was never revisited — a docs-as-plan process failure, not a knowledge failure.
- **Evidence:** compare `docs/specs/ai-stack.md` against `compose/nas/docker-compose.yml`
  and `compose/desktop/librechat.yaml` (broker ports, :3002, streamable-http,
  llama3.2:3b). Contrast with `docs/specs/lightrag-vault-indexer.md`, which has a
  maintained Status section (369/379 files indexed; key rotated) and is mostly current —
  same author, same repo, different maintenance habit.
- **Status:** **OPEN.** Treat `ai-stack.md` as *historical intent only*; never quote it as
  current truth. (Migration spec Step 5 includes updating it.) The authoritative repo-vs-
  live-vs-docs drift register lives in `home-infra-architecture-contract`.
- **Lesson (feeds `home-infra-docs-and-writing`):** specs need either a maintained Status
  header (like the vault-indexer spec) or an explicit "historical — superseded by X"
  banner. A doc without a sync trigger will rot; ADR-per-decision alone doesn't keep
  narrative specs true.

## F14 — Crontab 2am→4am uncommitted; watchtower also at 4am (minor)

- **Symptom:** `vault-indexer/crontab` in the worktree says `0 4 * * *`; committed `main`
  still says `0 2 * * *` (`git show main:vault-indexer/crontab`), and spec prose still
  references the 2am cron (`docs/specs/lightrag-vault-indexer.md:164`).
- **Timing coincidence to know about:** watchtower's schedule in the same compose is
  `--schedule "0 0 4 * * *"` — the **same 4am hour** as the new indexer cron. If watchtower
  updates/restarts the lightrag (or future minirag) container while the nightly index run
  is mid-flight, the run fails or half-completes. This collision is a *risk inference*
  from the two schedules, not an observed incident (UNVERIFIED as an actual failure).
  Note: watchtower was **not observed running** on the NAS 2026-07-02 despite being in
  compose, which currently makes the collision theoretical twice over.
- **Status:** Minor, open — the change is uncommitted, the spec prose is stale, and the
  4am/4am overlap is unexamined.
- **Lesson:** When moving a cron, grep the compose for every other scheduler in the same
  window before picking the new time.

## F15 — `--cleanup` failed-doc census silently errors (uppercase `status_filter`) (CLOSED)

- **Symptom:** `indexer.py --cleanup`'s failed-document report ("Querying LightRAG for
  failed docs") silently errors against the current LightRAG — the census produces no
  usable FAILED list.
- **Root cause:** the live API's `status_filter` enum is **lowercase**
  (`pending`/`processing`/`preprocessed`/`processed`/`failed`; live-verified 2026-07-02,
  which also confirmed `page_size` must be >= 10), while `vault-indexer/indexer.py:298-300`
  sends `"status_filter": "FAILED"` — the server answers HTTP 422 with an enum error.
- **Evidence:** live `POST /documents/paginated` on `:9621` (2026-07-02): lowercase
  `"failed"` → 200 with documents; uppercase `"FAILED"` → 422 enum error.
  `grep -n 'status_filter' vault-indexer/indexer.py` shows the uppercase literal at
  ~line 299. The diagnostics script
  (`.claude/skills/home-infra-diagnostics/scripts/index-state.py`) already sends
  lowercase and is correct.
- **Fix (2026-07-03):** `vault-indexer/indexer.py:299` now sends lowercase
  `"status_filter": "failed"`, matching `index-state.py` and the live API enum.
- **Status:** **CLOSED** 2026-07-03.
- **Lesson:** verify enum case against `/openapi.json` when hand-rolling status filters —
  a 422 inside a wrapper that swallows errors surfaces as a silently empty report.

---

## Settled decisions — do not re-litigate without new evidence

Quick list of "someone already thought about this" (full stories above; invariants and
enforcement live in `home-infra-change-control`; other settled-but-uneventful ADRs — 0002
batch-insert/track_status, 0003 two-stage archive→delete, 0005 LibreChat on desktop,
0008 Cloudflare Tunnel, 0012 LLM Wiki layer — are cataloged in
`home-infra-architecture-contract`):

| Proposal you might be tempted to make | Answer | See |
|---|---|---|
| "Switch back to nomic-embed-text" | No — 768-dim mismatch; also weaker | F1 |
| "Use Open WebUI, it's simpler" | No — no MCP client; removed entirely | F2 |
| "Wrap MCPs in mcpo / use Traefik / use NPM" | No — rejected with reasons | F3 |
| "Just hit Ollama on :11434 directly" | Never — broker invariant | F4 |
| "Tune LightRAG chunk size / GLEANING / 32k ctx to fix extraction" | No — explicitly rejected; the answer is MiniRAG | F8 |
| "Keep mxbai to avoid re-indexing" | No — re-index happens anyway; mxbai truncates | F9 |
| "Use Infinity's ROCm image on the 9070 XT" | No — RDNA4/gfx1201 unsupported | F7 |

## Open items at a glance (as of 2026-07-02)

- F5 — `654891a` fail-hard fix absent from local `main` (present on `add-embed-stack` and `origin/main`; local `main` is a divergent rewrite).
- F8/F12 — MiniRAG migration stalled pre-Step-1; everything about it uncommitted. Phase 0
  gates resolved 2026-07-03 (minirag → :9623, Route B shipping, NAS memory: free first);
  campaign now proceeding — see `minirag-migration-campaign`.
- F10 — `wiki-ingest.py --semantic-lint` entry-point bug. **CLOSED 2026-07-03.**
- F11 — `lightrag-trading` on :9622 — undocumented; ask Preston.
- F13 — `ai-stack.md` rot.
- F14 — crontab change uncommitted; 4am watchtower overlap unexamined.
- F15 — `indexer.py --cleanup` failed-doc census silently errors (uppercase `status_filter`). **CLOSED 2026-07-03.**

## When NOT to use this skill

- **Something is broken right now** → `home-infra-debugging-playbook` (symptom→triage
  table, discriminating experiments). This skill explains history, not live triage.
- **You need the authoritative repo-vs-live-vs-docs drift table or the invariants list** →
  `home-infra-architecture-contract`.
- **You want to actually execute the MiniRAG migration** → `minirag-migration-campaign`.
- **You need current port/env/model values** → `home-infra-config-reference`.
- **You're about to change behavior on a live machine** → `home-infra-change-control`
  first, always.
- **You want to re-measure the extraction failure rate or retrieval quality** →
  `rag-evaluation-methodology` (recipes) and `home-infra-diagnostics` (scripts).

## Provenance and maintenance

- Facts verified 2026-07-02 against repo state: `main` at commit `6cbd3a1` plus the
  uncommitted MiniRAG-migration worktree changes (ADRs 0010–0012, migration spec,
  `wiki-ingest.py`, compose/crontab/indexer edits). Live-container facts (F11, F12, F14
  watchtower absence) are from `docker ps` observation over SSH on 2026-07-02
  (authoring-pass observation; not re-observed since) — **volatile; re-verify before
  relying on them.**
- All 12 ADRs, all 3 specs, and full `git log`/`git show` output for every commit were
  read directly; every quoted line number checked against the working tree on 2026-07-02.
- Re-verification one-liners (run from `/Users/prestonbernstein/dev/home-infra` unless
  noted):
  - Live NAS containers/ports (F11, F12, F14):
    `ssh -i ~/.ssh/agent_ed25519 agent@10.0.0.250 'sudo /usr/local/bin/docker ps --format "{{.Names}}\t{{.Ports}}\t{{.Status}}"'`
  - Uncommitted migration state still uncommitted (F12): `git status --short && git log --oneline -1`
  - Fail-hard fix still absent from local main (F5): `git branch -a --contains 654891a`
    (expect `add-embed-stack` and `remotes/origin/main`, NOT local `main`) and
    `git show main:vault-indexer/indexer.py | sed -n '25p'`
  - wiki-ingest bug fix still in place (F10): `sed -n '389,398p' wiki-ingest.py` (expect
    no `elif semantic and not lint_only` branch)
  - Production LLM/embedding models (F8, F9): `grep -n 'LLM_MODEL\|EMBEDDING_MODEL' compose/nas/docker-compose.yml`
  - Crontab drift (F14): `git diff HEAD -- vault-indexer/crontab && grep -n schedule compose/nas/docker-compose.yml`
  - Transport reality (F6): `grep -n 'type:\|url:' compose/desktop/librechat.yaml`
- Maintenance: when an open item closes (migration completes, bug fixed, mystery
  identified), update the entry's **Status** and the two summary tables — do not delete
  the entry; the story is the point. New incidents get the next F-number, chronological
  placement, and the same five-field format.
