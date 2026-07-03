---
name: home-infra-validation-and-qa
description: Load when you need to VALIDATE a change to the home-infra stack or decide whether work is "done" — after deploying/restarting a service, editing compose files, re-indexing the vault, or completing a MiniRAG-migration step. Provides the evidence standard (measured numbers, never "looks fine"), acceptance thresholds, the golden/representative query set, per-change-class smoke checklists, and the 6-line sign-off evidence block for commits and ADRs. Triggers: "is it working", "verify the deploy", "did the re-index succeed", "acceptance criteria", "smoke test", "sign off", "index coverage", "FAILED-doc thresholds when validating a change".
---

# home-infra Validation & QA

**Honest premise: this repo has NO test suite and NO CI.** There is no `pytest`, no GitHub Actions, no pre-commit hooks — nothing runs automatically when you change code or compose files. Validation here means **live smoke checks against the running stack plus measured numbers**. Every claim of "it works" must be backed by a number or a command output you actually ran. If you cannot run the check (no SSH, machine down), say so explicitly — do not infer success.

Jargon used below (full definitions in `CONTEXT.md`, house style in `home-infra-docs-and-writing`):
- **RAG Engine** — the service (LightRAG today, MiniRAG mid-migration) that indexes the Obsidian **Vault** and answers queries. NAS `:9621` (LightRAG), `:9622` reserved for MiniRAG in repo compose but **occupied live by an undocumented `lightrag-trading` container as of 2026-07-02 — confirm with Preston before touching :9622** (see `home-infra-architecture-contract` drift register).
- **vault-indexer** — nightly container on the NAS that POSTs vault files to the RAG Engine (cron `0 4 * * *` per `vault-indexer/crontab`; some spec prose still says 2am — the crontab file wins).
- **`LIGHTRAG_API_KEY`** — auth secret. Lives only in the on-machine `.env` next to `/volume1/docker/ai/docker-compose.yml` on the NAS. Never copy its value into files.

SSH access pattern (authoritative copy in `home-infra-run-and-operate`): `ssh -i ~/.ssh/agent_ed25519 agent@10.0.0.250` (NAS) / `agent@10.0.0.243` (desktop); on the NAS docker is `sudo /usr/local/bin/docker` (plain `sudo docker` fails — not in sudo PATH).

---

## 1. What counts as evidence here (numbers, not vibes)

"Looks fine", "seems to work", "no obvious errors" — **never acceptance**. Evidence is one of these five measurables:

| # | Evidence type | What it is | How to get it (read-only) |
|---|---|---|---|
| 1 | **Index coverage** | Files indexed / files eligible in the vault. Baseline **369/379 files ≈ 97.4% as of the Status section of `docs/specs/lightrag-vault-indexer.md`** (10 files retried nightly). | Count state entries vs. eligible vault files — commands below. |
| 2 | **FAILED-document census** | Count of docs the RAG Engine holds in `FAILED` status. Queryable via `POST /documents/paginated` with `{"status_filter": "failed"}` (lowercase — request shape + quirks: `rag-stack-reference`). Note: `indexer.py --cleanup`'s own version of this query sends uppercase `"FAILED"` and silently errors on current LightRAG — open bug, see `home-infra-failure-archaeology`. | curl command below. |
| 3 | **Representative-query groundedness** | The golden queries (§3) return answers grounded in the correct vault source files — the answer cites/uses content that actually lives in the expected file, not hallucination. | Run query via LibreChat Vault Assistant or `/query` API; compare against `golden-queries.md`. |
| 4 | **Container health** | Every expected container `Up` (not `Restarting`, not missing) on both machines. | `docker ps` below. |
| 5 | **Log absence-of-errors over a full nightly cycle** | Zero new `ERROR` lines (and explained `WARNING` lines) in `indexer.log` covering at least one 4am cron run after your change. | log grep below. |

### Evidence-gathering commands (all read-only, copy-pasteable)

**Index coverage — numerator (state file entries with doc_ids, minus archived):**
```bash
ssh -i ~/.ssh/agent_ed25519 agent@10.0.0.250 \
  "sudo cat /volume1/docker/ai/vault-indexer/hashes.json" \
  | python3 -c 'import json,sys; s=json.load(sys.stdin); live=[v for v in s.values() if "archived_at" not in v]; print(f"indexed (live entries): {len(live)}  archived: {len(s)-len(live)}")'
```

**Index coverage — denominator (eligible `.md` files: vault minus top-level `.agents`, `.claude`, `.obsidian`, `_raw` — the `EXCLUDE_DIRS` in `vault-indexer/indexer.py`):**
```bash
ssh -i ~/.ssh/agent_ed25519 agent@10.0.0.250 \
  'sudo find /volume1/obsidian-vault -name "*.md" | grep -vcE "^/volume1/obsidian-vault/(\.agents|\.claude|\.obsidian|_raw)/"'
```

**FAILED census** (source the key from the NAS `.env` first — never paste its value):
```bash
# on the NAS (after: ssh -i ~/.ssh/agent_ed25519 agent@10.0.0.250)
export LIGHTRAG_API_KEY=$(sudo grep '^LIGHTRAG_API_KEY=' /volume1/docker/ai/.env | cut -d= -f2)
curl -s -X POST http://10.0.0.250:9621/documents/paginated \
  -H "X-API-Key: ${LIGHTRAG_API_KEY}" -H "Content-Type: application/json" \
  -d '{"page": 1, "page_size": 50, "status_filter": "failed"}' \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print("FAILED docs:", len(d.get("documents",[])))'
```
(Request shape + quirks — lowercase `status_filter`, `page_size >= 10`, live-verified 2026-07-02: `rag-stack-reference`. For MiniRAG, same call against `<MINIRAG_PORT>` once MiniRAG is deployed (Gate 0a); as of 2026-07-02 `:9622` answers as `lightrag-trading` — do not probe it with authed writes. API compatibility is **unverified** — migration Step 3, see `minirag-migration-campaign`.)

**Container health (NAS; same idea on desktop with plain `docker ps`):**
```bash
ssh -i ~/.ssh/agent_ed25519 agent@10.0.0.250 \
  "sudo /usr/local/bin/docker ps --format 'table {{.Names}}\t{{.Status}}'"
```

**Log absence-of-errors (must span at least one 4am cron run):**
```bash
ssh -i ~/.ssh/agent_ed25519 agent@10.0.0.250 \
  "sudo grep -E 'ERROR|WARNING' /volume1/docker/ai/vault-indexer/indexer.log | tail -50"
```
Interpretation of known log lines (`No doc_id for ...`, `pipeline is busy`, etc.) belongs to `home-infra-diagnostics` and `home-infra-debugging-playbook`.

---

## 2. Acceptance-threshold discipline: predict, then measure

Rule (mirrors the hypothesis-predicts-numbers method in `rag-evaluation-methodology`):

1. **BEFORE any change: write down the predicted post-change numbers.** In the commit message draft, the ADR, or your working notes — but written, with units, before you touch anything. "It should improve" is not a prediction; "FAILED census drops from 10 to ≤3" is.
2. **AFTER the change: measure** using the commands above and/or the measurement scripts owned by `home-infra-diagnostics`.
3. **A change is validated only when measured ≥ predicted** (or ≤, for counts you predicted would drop). Measured worse than predicted = not validated: either roll back or write down why the prediction was wrong and get a human decision before proceeding.

### CANDIDATE thresholds — MiniRAG cutover (migration Step 4)

**Label: CANDIDATE, not certified. The human (Preston) sets the final numbers.** These are the authoring agent's proposal as of 2026-07-02, derived from the 369/379 ≈ 97.4% LightRAG baseline:

| # | Threshold (CANDIDATE) | Measured how |
|---|---|---|
| C1 | **≥ 97% of eligible files reach `PROCESSED` on the full re-index into MiniRAG** (i.e. MiniRAG must at least match the LightRAG baseline) | Coverage numerator/denominator commands (§1), pointed at the MiniRAG state file `/volume1/docker/ai/vault-indexer/hashes-minirag.json` and `<MINIRAG_PORT>` once MiniRAG is deployed (Gate 0a); as of 2026-07-02 `:9622` answers as `lightrag-trading` — do not probe it with authed writes |
| C2 | **Both representative queries (§3) return answers grounded in the correct source files** via lightrag-mcp → MiniRAG | Run each golden query; check groundedness against `golden-queries.md` |
| C3 | **No growth in FAILED-status count over 3 consecutive nightly runs** post-cutover | FAILED census (§1) after each 4am run, 3 days running |

Do not present a cutover as "done" against these until Preston has confirmed or amended them. The cutover procedure itself lives in `docs/specs/minirag-migration.md` and `minirag-migration-campaign`; the go/no-go gate lives in `home-infra-change-control`.

---

## 3. Golden / certified inventory

This repo's closest thing to a certified test set: **two representative queries** named in `docs/specs/minirag-migration.md` Step 3 (verbatim):

1. `what maintenance has been done on the Corolla?`
2. `what's my current home network topology?`

These, plus their expected source files, are seeded in [`golden-queries.md`](golden-queries.md) **in this skill directory** — proposed as the candidate home for the gold set (`.claude/skills/home-infra-validation-and-qa/golden-queries.md`). The human decides the permanent location; if it moves, update this pointer.

**How to grow the gold set** (one row at a time, human-approved):
1. Pick a query a real user actually asks the Vault Assistant.
2. Identify the **expected source file(s)** — the exact vault-relative `.md` path(s) whose content must ground the answer. Verify the file exists and contains the answer before adding the row.
3. Add a row to `golden-queries.md`: query text (exact), expected source file(s), what a grounded answer must mention, date added, status (`seed`/`candidate`/`certified` — only a human promotes to `certified`).
4. A golden query that starts failing after a change is a **regression**, not noise. Record it in the sign-off block (§6) and route through `home-infra-change-control` before shrugging it off.

---

## 4. Post-change smoke checklist, per change class

Change classes are defined and gated by `home-infra-change-control` — classify there first, then run the matching checklist here. All commands below are read-only.

### docs-only (README/spec/ADR/CONTEXT.md edits)
Nothing live to check. Optional: confirm intra-repo links you touched still resolve (open the files). Done.

### repo-compose (compose/config edits in the repo, not yet deployed)
```bash
# From the repo root. Dummy env values only — this validates syntax/interpolation, nothing live.
LIGHTRAG_API_KEY=dummy docker compose -f compose/nas/docker-compose.yml config -q && echo NAS-COMPOSE-OK
docker compose -f compose/desktop/docker-compose.yml config -q && echo DESKTOP-COMPOSE-OK
```
(If `yamllint` is installed, `yamllint compose/` is a bonus, not a substitute. `docker compose config -q` exits non-zero on syntax errors — that exit code is your evidence.)

### live-deploy (a service was actually (re)started on a machine)
1. Run the stack-health script from `home-infra-diagnostics` (that skill owns the script and its interpretation).
2. Container health check (§1 command) — the touched service is `Up`, and nothing else flipped to `Restarting`.
3. Logs of the touched service, since deploy:
   ```bash
   ssh -i ~/.ssh/agent_ed25519 agent@10.0.0.250 \
     "sudo /usr/local/bin/docker logs --since 30m <container-name> 2>&1 | tail -60"
   ```
4. If the RAG path was touched (lightrag, minirag, lightrag-mcp, vault-indexer): run **one representative query** from `golden-queries.md` and confirm groundedness.

### index-destructive (re-index, state-file change, RAG Engine storage wipe, model swap)
1. **Monitor the full re-index** (hours for ~380 files): watch the state file grow and tail the log — see `home-infra-run-and-operate` for the run mechanics.
2. **Coverage number** (§1, numerator + denominator) once the run completes — compare against the 369/379 ≈ 97.4% baseline and your written prediction (§2).
3. **FAILED census** (§1) — record the absolute count.
4. **No FAILED growth over 3 consecutive nightly runs** before declaring stable (threshold C3, §2).
5. Both golden queries grounded (§3).

---

## 5. How to add a new check

**Where things go — one home per artifact:**
- **Measurement mechanics** (a script that produces a number): goes in the scripts owned by `home-infra-diagnostics`. Not here.
- **The threshold** (what number counts as pass) and its place in a checklist: goes **in this skill** — add a row to the §1 evidence table or the relevant §4 checklist.
- **Golden queries**: `golden-queries.md` (§3 procedure).
- **Why the threshold is what it is** (methodology, worked examples): `rag-evaluation-methodology`.

**Rule for new services** (authoring proposal — not a standing instruction): **every new service ships with at least (a) one health probe** — a concrete read-only command proving the service is up (HTTP endpoint, `docker ps` status, log line) — **and (b) one representative query or functional check** proving it does its job, not merely that it runs. No probe + no functional check = the service is not "deployed", it is "started". Register both here (threshold) and in `home-infra-diagnostics` (measurement) before calling the deployment done.

---

## 6. Sign-off template

Paste this 6-line evidence block into the commit message (repo commits are authored by Preston only — no Claude attribution, per project owner standing instructions) or into the ADR/notes for the change. Every line filled in, or explicitly `n/a — <why>`:

```
What changed:   <one line — service/file + change class per home-infra-change-control>
Predicted:      <the numbers you wrote down BEFORE the change, with units>
Measured:       <the numbers you actually got, command + output summary>
Queries run:    <which golden queries, grounded? yes/no per query>
Regressions:    <anything that got worse, incl. new FAILED docs / new log ERRORs — or "none observed">
Rollback tested?: <yes (how) / no (why acceptable) — rollback plan is a change-control gate>
```

A block with `Measured:` empty or vaguer than `Predicted:` is not a sign-off. "Looks fine" anywhere in this block fails review.

---

## When NOT to use this skill

- **You need to run a measurement / interpret script output** → `home-infra-diagnostics` (owns the measurement scripts and their interpretation).
- **You want evaluation methodology or theory** — how to design an eval, worked examples, extraction-failure-rate recipes → `rag-evaluation-methodology`.
- **You need to know whether a change is allowed and how it's gated** — change classes, non-negotiables, repo↔live sync contract → `home-infra-change-control`.
- **You're executing the migration itself** → `minirag-migration-campaign` (this skill only supplies its acceptance thresholds).
- **Something is broken and you're triaging** → `home-infra-debugging-playbook`.
- Ports/env-vars/models lookup → `home-infra-config-reference`. RAG Engine API details → `rag-stack-reference`. How to run/SSH/cron → `home-infra-run-and-operate`.

## Provenance and maintenance

- Facts verified 2026-07-02 against repo state (commit 6cbd3a1 + uncommitted MiniRAG-migration worktree changes: `docs/specs/minirag-migration.md`, minirag compose service, `_raw` exclusion + `STATE_FILE` override) and live containers observed via SSH 2026-07-02.
- The three CANDIDATE cutover thresholds (§2) and the golden-query home (§3) are **authoring-agent proposals, not human-certified** — Preston sets the final numbers/location.
- `lightrag-trading` occupying NAS `:9622` is undocumented live reality (observed 2026-07-02); do not resolve, confirm ownership with Preston. Authoritative drift register: `home-infra-architecture-contract`.
- Re-verification one-liners for volatile facts:
  - Baseline 369/379: `grep -n "369/379" docs/specs/lightrag-vault-indexer.md`
  - Golden queries verbatim: `grep -n "Corolla\|topology" docs/specs/minirag-migration.md`
  - `/documents/paginated` request shape: `grep -n -A3 'documents/paginated' vault-indexer/indexer.py`
  - `EXCLUDE_DIRS`: `grep -n "EXCLUDE_DIRS" vault-indexer/indexer.py`
  - Cron hour: `cat vault-indexer/crontab`
  - State path on NAS: `grep -n "vault-indexer:/state" compose/nas/docker-compose.yml` (spec has one stale `/volume1/docker/vault-indexer/` line — compose wins)
  - Live container census: `ssh -i ~/.ssh/agent_ed25519 agent@10.0.0.250 "sudo /usr/local/bin/docker ps"`
- UNVERIFIED items are labeled inline: MiniRAG `/documents/paginated` compatibility (migration Step 3 TBD); the exact stack-health script name/path (owned and defined by `home-infra-diagnostics`).
