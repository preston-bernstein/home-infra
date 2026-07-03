---
name: home-infra-diagnostics
description: Measurement toolkit for the home-infra Personal AI Stack — run these scripts instead of eyeballing. Load when you need to check overall stack health, inspect vault-indexer state (hashes.json, archived files, failed documents), detect repo-vs-live compose drift, or lint the LLM Wiki safely. Triggers - "is the stack healthy", "health check", "count/measure FAILED docs and index coverage", "how many documents indexed/failed", "what's archived", "did the compose drift", "check everything before/after a change", "run diagnostics", "baseline the system", "wiki lint". Provides four read-only scripts with per-script interpretation guides (expected output as of 2026-07-02, known-benign deviations, and what each FAIL implies).
---

# home-infra Diagnostics

Measure, don't eyeball. Every script in `scripts/` is **strictly read-only**: pings, curl
GETs, `docker ps`, `ssh ... cat`, diffs. Nothing restarts, writes, or mutates. Run them
from the MacBook on the home LAN (or Tailscale); they SSH as `agent@` with
`~/.ssh/agent_ed25519` (see `home-infra-run-and-operate` for the access pattern).

Secrets: scripts take `LIGHTRAG_API_KEY` from the environment if set, otherwise read it at
runtime from `/volume1/docker/ai/.env` on the NAS. The key is never printed and never stored.

| Script | Run when | Runtime |
|---|---|---|
| `scripts/stack-health.sh` | Before/after ANY change; start of any debugging session; baseline | ~30 s |
| `scripts/index-state.py` | Index questions: coverage, archived files, missing doc_ids, FAILED docs | ~5 s (+ a few s with `--failed`) |
| `scripts/drift-check.sh` | Before editing compose anywhere; after any live deploy; drift-register upkeep | ~10 s |
| `scripts/wiki-lint-safe.sh` | After any wiki Ingest; periodic wiki QA | seconds (structural) / minutes (`--semantic`) |

Baseline discipline: run `stack-health.sh` and `index-state.py` BEFORE a change and save
the output; run again after. The diff is your evidence (see `home-infra-validation-and-qa`
for thresholds and the sign-off block).

---

## 1. stack-health.sh — whole-stack PASS/WARN/FAIL sweep

```bash
cd /Users/prestonbernstein/dev/home-infra/.claude/skills/home-infra-diagnostics/scripts
./stack-health.sh        # exit 0 = no FAILs; exit 1 = at least one FAIL
./stack-health.sh -v     # show raw docker ps / curl bodies on anomalies
```

Checks in order: ping both machines → SSH both → broker lanes (:11435/:11436/:11437/:11438)
→ NAS containers → RAG Engine `/health` + `pipeline_status` → lightrag-mcp :3002 → desktop
containers.

### Interpretation guide (healthy baseline as of 2026-07-02)

Live-tested 2026-07-02: `22 PASS, 4 WARN, 2 FAIL` — the 4 WARNs below are the expected
steady-state; the 2 FAILs were a real transient (see broker note).

**Known-benign WARNs (do not chase):**
- `registry` / `minirag` in repo compose but not running — expected until the MiniRAG
  migration executes (see `minirag-migration-campaign`).
- `lightrag-trading` running on :9622 — undocumented in this repo; PORT CONFLICT with the
  planned minirag mapping. Flag only; confirm ownership with Preston. Never touch it.
- `fashion-monitor-*` crash-looping — owned by the fashion-monitor repo, not home-infra.

**FAIL meanings:**
- `ping`/`ssh` FAIL → you are off-LAN/off-Tailscale, or the machine is down. Everything
  downstream will cascade; fix reachability first.
- Broker lane `no response` (HTTP 000) → **read carefully before declaring the broker dead.**
  000 can be connect-refused OR a held/hung connection. Worked example (observed
  2026-07-02): :11435 and :11436 returned 000 from BOTH the Mac and desktop-localhost while
  :11437 and :11438 answered 200 — hours earlier :11435 had answered instantly with 404.
  Interpretation: the interactive/batch lanes were wedged or deliberately holding requests
  during GPU contention (the broker arbitrates against gaming/Plex). Discriminate with:
  `ssh -i ~/.ssh/agent_ed25519 agent@10.0.0.243 'systemctl list-units | grep -i -e ollama -e broker'`
  then read (read-only) `journalctl -u <unit> -n 50`. Retry in 15–30 min before escalating.
  NEVER "fix" this by pointing clients at raw :11434 (invariant — `home-infra-change-control`).
- NAS container FAIL → `sudo /usr/local/bin/docker logs --tail 50 <name>` (note the full
  docker path — plain `sudo docker` is "command not found" on Synology), then
  `home-infra-debugging-playbook`.
- `pipeline BUSY` WARN → indexing in progress (nightly cron 04:00 NAS-time or a manual
  run). Benign; do not start another ingest; re-check later.
- lightrag-mcp: **HTTP 406 on a plain GET is the healthy answer** (streamable-http server
  rejecting a non-MCP request proves the listener is up). 000 is the failure.

---

## 2. index-state.py — vault-indexer state + failed documents

```bash
./index-state.py                      # tracked/active/archived/missing-doc_id summary
./index-state.py --failed             # + RAG Engine failed-doc census via /documents/paginated
./index-state.py --json               # raw hashes.json dump
# During the MiniRAG migration (parallel index, separate state) — <MINIRAG_PORT> once
# MiniRAG is deployed (Gate 0a); as of 2026-07-02 :9622 answers as lightrag-trading —
# do not probe it with authed writes:
./index-state.py --state-file /volume1/docker/ai/vault-indexer/hashes-minirag.json \
                 --rag-url http://10.0.0.250:<MINIRAG_PORT> --failed
```

### Interpretation guide

- Baseline (from `docs/specs/lightrag-vault-indexer.md`, as of 2026-07-02): ~379 vault
  files, 369 indexed ≈ 97.4% coverage; ~10 retried nightly. A `without doc_id` count near
  10 is therefore normal; a sudden jump is not — check `indexer.log` on the NAS and rerun
  with `--failed`.
- `archived` entries: files missing from the vault, in the 30-day two-stage delete window
  (ADR 0003). Entries "past window" delete on the next nightly run — if that's wrong,
  restore the file in the vault before 04:00 or use the indexer's `--cleanup` (interactive;
  see `home-infra-run-and-operate`).
- `--failed` API quirk (live-verified 2026-07-02 against LightRAG core 1.4.16/api 0291):
  `status_filter` must be **lowercase** (`"failed"`) and `page_size >= 10`, else HTTP 422.
  The script handles this; remember it when hand-rolling curl.
- Growth of FAILED docs after a model/engine change is the #1 regression signal — thresholds
  in `home-infra-validation-and-qa`.

---

## 3. drift-check.sh — repo intent vs live runtime

```bash
./drift-check.sh          # all: NAS compose + desktop compose + embed-stack
./drift-check.sh nas
./drift-check.sh desktop
```

Diffs repo compose files against `ssh ... cat` of the live ones
(`/volume1/docker/ai/docker-compose.yml` on the NAS; `/opt/docker/librechat-stack/` and
`/opt/docker/embed-stack/` on the desktop).

### Interpretation guide

- Drift is EXPECTED right now: the repo carries the uncommitted MiniRAG migration (minirag
  service, registry) that is not deployed. Repo-has/live-lacks `minirag`+`registry` = the
  migration pending, not an error.
- Live-has/repo-lacks a whole service → it may belong to ANOTHER compose file or repo
  (lightrag-trading, immich, financial-pipeline are not home-infra's). Check
  `/volume1/docker/*/docker-compose.yml` before recording drift.
- Real drift (same service, different env/ports/image) goes in the
  `home-infra-architecture-contract` drift register and is reconciled via
  `home-infra-change-control` (class b/c). Exit 2 = fetch failed (reachability/ssh), not drift.

---

## 4. wiki-lint-safe.sh — lint the LLM Wiki without triggering an ingest

```bash
./wiki-lint-safe.sh              # structural: orphan pages, broken wikilinks
./wiki-lint-safe.sh --semantic   # + LLM lint: CONTRADICTION / STALE / MISSING-LINK
```

Exists because of a live bug: `wiki-ingest.py --semantic-lint` ALONE also runs a full
ingest (processes and **deletes** `_raw/` captures). The wrapper always passes `--lint`,
which short-circuits the ingest branch (verified against the entry point in
`wiki-ingest.py`). Full story: `home-infra-failure-archaeology`.

### Interpretation guide

- Structural: "Structurally clean." is the target. Orphans right after early ingests are
  common (few pages, few links) — chronic orphans mean the ingest prompt isn't
  cross-referencing; see `rag-stack-reference` (LLM Wiki pattern).
- Semantic (`--semantic`): calls qwen3:8b via broker :11435; minutes-long; 503s retried
  automatically (10/30/60/120/180 s ladder). Treat findings as CANDIDATE issues — measured
  precision of this lint is an open problem (`home-infra-research-frontier`). Verify each
  reported CONTRADICTION by reading both pages before editing anything.
- Requires the vault present locally (default `~/dev/Obsidian/Home Network Vault`,
  override `VAULT_PATH`). It reads the wiki only; it never writes pages.

---

## Observation → next skill

| You observe | Go to |
|---|---|
| Any FAIL you can't classify with the guides above | `home-infra-debugging-playbook` (symptom table) |
| FAILED docs growing / coverage dropping | `home-infra-debugging-playbook` rows 4/6, then `rag-evaluation-methodology` to measure |
| Drift that is real (not migration-pending) | `home-infra-architecture-contract` drift register + `home-infra-change-control` |
| Everything green and you're validating a change | `home-infra-validation-and-qa` (thresholds, sign-off) |
| :9622 / lightrag-trading questions | `home-infra-architecture-contract` (flag only — ask Preston) |

## When NOT to use this skill

- You already know WHAT is broken and need the fix procedure → `home-infra-debugging-playbook`.
- You need to change/deploy something → `home-infra-change-control` then `home-infra-build-and-deploy`.
- You need value lookups (ports, env vars, models) → `home-infra-config-reference`.
- You want to design an experiment or compare engines → `rag-evaluation-methodology`.

## Provenance and maintenance

- Facts verified 2026-07-02 against repo commit 6cbd3a1 + uncommitted MiniRAG-migration
  worktree, and against live machines via read-only SSH.
- Live-tested 2026-07-02: `stack-health.sh` full run (22 PASS / 4 WARN / 2 FAIL — broker
  transient documented above); `index-state.py` API-quirk behavior (lowercase
  `status_filter`, `page_size>=10`) verified against live LightRAG by the original author;
  `drift-check.sh` and `wiki-lint-safe.sh` syntax-checked (`bash -n`) — full live run of
  these two is UNVERIFIED as of 2026-07-02.
- Expected-container lists in `stack-health.sh` mirror the compose files; when services are
  added/removed, update `NAS_EXPECTED`/`NAS_MIGRATION`/`DESKTOP_EXPECTED` in the script.
- Re-verification one-liners:
  - Scripts still syntax-clean: `bash -n scripts/*.sh && python3 -m py_compile scripts/index-state.py`
  - Coverage baseline still 369/379: `grep -n "369/379" /Users/prestonbernstein/dev/home-infra/docs/specs/lightrag-vault-indexer.md`
  - Wiki-ingest bug still present (wrapper still needed): `grep -n "elif semantic and not lint_only" /Users/prestonbernstein/dev/home-infra/wiki-ingest.py`
  - Broker lanes: `curl -s -m 3 -o /dev/null -w '%{http_code}\n' http://10.0.0.243:11437/jobs`
  - Migration still pending: `ssh -i ~/.ssh/agent_ed25519 agent@10.0.0.250 'sudo /usr/local/bin/docker ps --format "{{.Names}}" | grep -c minirag' (0 = pending)`
