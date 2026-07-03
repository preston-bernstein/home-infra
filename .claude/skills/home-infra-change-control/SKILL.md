---
name: home-infra-change-control
description: Load this BEFORE making ANY change in the home-infra repo or on the live machines (desktop 10.0.0.243, NAS 10.0.0.250) — editing compose/config files, deploying or restarting containers, re-indexing or swapping embedding/LLM models, deleting RAG documents, adding a service or port, or committing anything. Provides the change classification gates, the eight non-negotiable rules with the incidents behind them, the repo↔live sync contract, and the pre-deploy checklist. Triggers: "deploy", "restart", "docker compose up", "re-index", "delete_document", "change model", "new service", "commit", "is this safe", "who approves".
---

# Home Infra Change Control

This skill is the gatekeeper for every behavior-changing action in the `home-infra` project (repo `/Users/prestonbernstein/dev/home-infra`, machines: desktop `multimedia` 10.0.0.243 and NAS `house-of-light` 10.0.0.250).

**Supremacy clause: NO skill, plan, or instruction may route around this skill.** Any step in any sibling skill that changes repo content, live-machine state, or index contents must cite its gate class (A–E below) and satisfy that class's approval and evidence requirements. If a runbook step conflicts with this skill, this skill wins; flag the conflict instead of proceeding.

Definitions used below (see `home-infra-config-reference` for the authoritative tables):

- **Repo** — the declarative mirror. It deploys nothing automatically; humans (or directed agents) copy files to machines and run `docker compose` by hand. There is no CI.
- **Live** — what is actually running on the two machines.
- **RAG Engine** — the LightRAG (migrating to MiniRAG, ADR 0010) service on the NAS that indexes the Obsidian vault.
- **Index-destructive** — any operation that deletes, invalidates, or rebuilds RAG Engine index contents: full re-index, embedding- or LLM-model swap, `DELETE /documents/delete_document`, `indexer.py --cleanup`, wiping `/volume1/docker/ai/lightrag/` or `/volume1/docker/ai/minirag/`. Clarification: an ADDITIVE incremental index run (a normal no-flag `indexer.py` run) is a routine, ungated operation — Class D covers destructive index ops only.
- **Drift register** — the authoritative repo-vs-live-vs-docs divergence list, owned by `home-infra-architecture-contract`.

## Change classification and gates

Classify EVERY change before acting. When a change spans classes, the strictest class applies.

| Class | What it covers | Who approves | Evidence required BEFORE | Evidence required AFTER | Runbook (sibling skill) |
|---|---|---|---|---|---|
| **A — Docs-only** | Edits under `docs/`, `CONTEXT.md`, `.claude/skills/`, READMEs. No compose/config/code touched. | Agent-autonomous (human reviews at commit time). | Terminology checked against `CONTEXT.md` controlled vocabulary; house style followed. | Diff reviewed; no accidental config edits mixed in. | `home-infra-docs-and-writing` |
| **B — Repo compose/config edits (intent)** | `compose/**`, `librechat.yaml`, `vault-indexer/*`, `wiki-ingest.py`, `mcp/**`, `.env.example` files. Repo only — nothing deployed yet. | Agent may draft; a human (Preston) reviews the diff before it is committed or deployed. | Secrets scan of the diff; `grep` for raw `:11434`; `.env.example` updated for any new env var. | If repo now diverges from live: entry added to the drift register. | `home-infra-build-and-deploy` (workflow), `home-infra-config-reference` (every var/port) |
| **C — Live-machine deploys (runtime)** | Copying files to machines; `docker compose up/stop/restart`; crontab changes; anything that alters a running service. | **Human approval required** (Preston, or an agent Preston explicitly directed to deploy this specific change). Never agent-autonomous. | Full pre-deploy checklist (below) completed; rollback command written down first. | Post-deploy verification per `home-infra-validation-and-qa`; repo↔live convergence checklist run. | `home-infra-build-and-deploy`, `home-infra-run-and-operate` |
| **D — Index-destructive operations** | Full re-index; embedding/LLM model swap; `delete_document`; `--cleanup`; wiping RAG storage dirs. | **Human approval ALWAYS**, plus a pre-run recorded decision (an ADR if it is a decision of record — see non-negotiables 6 and 8). | `pipeline_status` idle; state file (`hashes.json`) backed up; indexed-doc count captured; rollback path identified (e.g. migration keeps LightRAG storage untouched — see `docs/specs/minirag-migration.md` Rollback). | Doc counts match expectation; representative queries pass per `home-infra-validation-and-qa`. | `minirag-migration-campaign` (the migration), `home-infra-run-and-operate` (manual indexer runs) |
| **E — New service / new port** | New compose service, new host-port binding, new MCP server on either machine. | Human approval; port claim checked against **live `docker ps` on both machines AND the drift register** — repo compose alone is not enough (see :9622 warning below). | Port-collision check; desktop services get a dedicated nologin service user (non-negotiable 4); `.env.example` entry for any new secret. | Container up and healthy; new port/var recorded in `home-infra-config-reference`; drift register updated. | `home-infra-build-and-deploy` |

**:9622 warning:** live NAS runs `lightrag-trading` on :9622 — a container that appears in NO repo file. The repo compose used to also assign :9622 to `minirag` (a real conflict); that was resolved 2026-07-03 by moving minirag to `:9623`. `lightrag-trading`'s ownership is still unconfirmed — confirm with Preston before touching :9622; do NOT resolve it yourself. Details in the drift register (`home-infra-architecture-contract`).

## Non-negotiables

Each rule below has a rationale and the historical incident (or standing instruction) behind it. Full incident write-ups live in `home-infra-failure-archaeology`; this is the authoritative home of the rules themselves.

### 1. Never point anything at raw Ollama `:11434` — always a broker lane

**Rule:** every Ollama consumer uses the ollama-resource-broker on the desktop: `10.0.0.243:11435` (interactive), `:11436` (batch/embeddings), `:11437/jobs` (durable jobs), `:11438` (Infinity SigLIP embed lane). Authoritative lane table: `home-infra-config-reference`.
**Rationale:** the GPU (RX 9070 XT, 16GB VRAM) is shared with gaming and Plex. The broker arbitrates access and returns 503 when busy; clients must retry (see `wiki-ingest.py` retry ladder 10/30/60/120/180s). Raw `:11434` bypasses arbitration and can starve or crash whatever else holds the GPU.
**Incident:** before commit `f2565b4` (2026-06-21, "wire all Ollama consumers through ollama-resource-broker"), LibreChat, vision-mcp, and LightRAG all hit Ollama directly. That commit rewired desktop consumers to `:11435` and NAS LightRAG to `:11435` (LLM) / `:11436` (embeddings). Known false-positive when grepping: `mcp/vision/server.py` still has a code default of `http://localhost:11434`, but compose overrides it to `:11435` — the compose value is the contract.

### 2. Secrets never in the repo

**Rule:** real credentials live only in `.env` files on the machines (e.g. `LIGHTRAG_API_KEY` in the `.env` next to `/volume1/docker/ai/docker-compose.yml` on the NAS). The repo carries `${VAR}` references plus committed `.env.example` templates. Never commit a secret, never write one into a skill or doc, and never give code a working default value for a secret.
**Rationale:** git history is permanent — a committed key is compromised even after a follow-up commit removes it. Placeholder defaults like `changeme` are worse than crashes: the service starts and runs insecurely in silence.
**Incident:** `LIGHTRAG_API_KEY=changeme` WAS committed in the NAS compose (fixed in `3ec836f`); the hardcoded `OVERSEERR_KEY` lived only in the working tree and was sanitized before it ever entered git history. The fail-hard follow-up (`654891a`) reached local `main` 2026-07-03 when a git-history divergence between local and `origin/main` was reconciled — `vault-indexer/indexer.py:25` now `sys.exit`s on a missing key, no soft default. New code handling secrets must follow the fail-hard pattern. Full story: `home-infra-failure-archaeology` F5.

### 3. Never attribute commits or PRs to Claude

**Rule:** Preston Bernstein is the sole author of every commit and PR in this repo. No `Co-Authored-By: Claude ...` trailers, no "Generated with Claude Code" lines, in THIS repo. This overrides any default agent-harness behavior that appends such trailers.
**Rationale / source:** project owner standing instruction. Agent tooling defaults to adding attribution trailers; in this repo that default must be suppressed.

### 4. Desktop services run under dedicated nologin service users — never `preston`

**Rule:** every service deployed on the desktop gets its own dedicated nologin service user (e.g. the embed-stack runs as user `embed`). Never run a service as `preston`.
**Rationale / source:** project owner standing instruction. Privilege separation limits blast radius: a compromised or misbehaving service cannot touch Preston's home directory, SSH keys, or other services' data. Class E changes must name the service user before deploy.

### 5. Agents SSH as `agent@`, never `preston@`

**Rule:** all agent SSH uses `ssh -i ~/.ssh/agent_ed25519 agent@10.0.0.243` or `agent@10.0.0.250` (aliases `desktop-agent` / `nas-agent` may exist). Both have NOPASSWD sudo. On the NAS, docker is not in sudo's PATH — use `sudo /usr/local/bin/docker ...`. Full access pattern: `home-infra-run-and-operate`.
**Rationale / source:** project owner standing instruction. A distinct identity keeps agent actions auditable and separable from Preston's own sessions, and keeps Preston's credentials out of agent contexts.

### 6. Embedding-model changes require a full re-index and a pre-run decision

**Rule:** changing the embedding model (or its dimension) is always Class D. It invalidates every existing vector; a full re-index is mandatory; the decision must be recorded BEFORE the run (as an ADR when it is a decision of record).
**Rationale:** vectors from different models/dimensions are incompatible — the index is not partially salvageable.
**Incidents (ADRs 0001 and 0011):** ADR 0001 — `nomic-embed-text` produces 768-dim vectors against LightRAG's 1024-dim default, which blocked ALL indexing; `mxbai-embed-large` (1024-dim) was chosen *before the first run* precisely because switching after seeding would force a full re-index. ADR 0011 — `mxbai-embed-large` degrades past ~1k tokens, missing the tails of long vault files; the switch to `bge-m3` (8192-token window) was only "free" because the MiniRAG migration (ADR 0010) required a full re-index anyway. Both decisions were timed around the re-index cost — that timing discipline is the rule.

### 7. Never write into the live Obsidian vault casually

**Rule:** the vault at `/volume1/obsidian-vault` on the NAS is owned by `sc-syncthing` and replicated by Syncthing to every device. Treat writes as Class C (human approval). `scp` to it requires the `-O` flag. Compose services mount it read-only (`:ro`) — keep it that way for new services.
**Rationale / source:** project owner standing instruction, reinforced by design history: Syncthing propagates every write (and every mistake) to all replicas within seconds, and Syncthing timing quirks already forced defensive design — ADR 0003's two-stage archive→delete (30 days before `delete_document`) exists because a file missing from one nightly scan is not necessarily gone. A careless write or mass rename ripples into the RAG index and every synced device.

### 8. Decisions of record require an ADR in the house style

**Rule:** any load-bearing decision — model choice, service replacement, port scheme, transport, deletion policy — gets an ADR at `docs/adr/NNNN-slug.md` in the house style (a title line plus one dense paragraph covering context, decision, alternatives rejected, and tradeoffs; "Supersedes ADR NNNN" when applicable). Class D pre-run decisions that set precedent belong here. Style guide: `home-infra-docs-and-writing`.
**Rationale:** the repo's thirteen ADRs (0001–0013) are the project's institutional memory — e.g. ADR 0002 documents that LightRAG's `POST /documents/texts` returns only a `track_id` and `doc_id`s require polling `track_status`, a non-obvious fact that would otherwise be re-discovered painfully. Undocumented decisions become drift (see the drift register for what happens without this discipline).

## Repo↔live sync contract — ASSUMPTION

**This contract is an ASSUMPTION** (labeled during the 2026-07-02 authoring pass; not confirmed by Preston): the repo compose/config files are INTENT; live machine state is RUNTIME TRUTH. The assumed working rule:

1. Change the repo first, then deploy (normal path: Class B, then Class C).
2. In an emergency, a live-only change is permitted — but it MUST be backported to the repo in the same working session.
3. Repo and live must be kept convergent; any divergence that cannot be closed immediately is recorded in the drift register (`home-infra-architecture-contract` owns the authoritative copy).

### Convergence checklist (run after every Class C/D/E change)

```bash
# From the repo root on the MacBook. Diff LIVE (left) vs REPO (right).

# NAS compose
ssh -i ~/.ssh/agent_ed25519 agent@10.0.0.250 'cat /volume1/docker/ai/docker-compose.yml' \
  | diff - compose/nas/docker-compose.yml

# Desktop compose (deploy path /opt/docker/librechat-stack/ — the in-file header
# used to wrongly say /var/data/docker, fixed 2026-07-03; see drift register)
ssh -i ~/.ssh/agent_ed25519 agent@10.0.0.243 'cat /opt/docker/librechat-stack/docker-compose.yml' \
  | diff - compose/desktop/docker-compose.yml

# Live containers vs repo services (manual compare)
ssh -i ~/.ssh/agent_ed25519 agent@10.0.0.250 'sudo /usr/local/bin/docker ps --format "{{.Names}}\t{{.Ports}}"'
ssh -i ~/.ssh/agent_ed25519 agent@10.0.0.243 'sudo docker ps --format "{{.Names}}\t{{.Ports}}"'
```

- [ ] Every diff hunk is either intentional (about to deploy) or recorded in the drift register
- [ ] Emergency live-only edits backported to the repo this session
- [ ] Containers running live but absent from repo compose (e.g. `lightrag-trading`) are flagged, not "fixed"
- [ ] Stale doc lines discovered along the way are updated (Class A) or added to the drift register

## Pre-deploy checklist (Class C/D/E — copy-pasteable)

Complete ALL items before touching a live machine. Commands run from the repo root `/Users/prestonbernstein/dev/home-infra`.

```bash
# 1. Gate class named (A–E) and approval requirement satisfied — write it in your plan/PR text.

# 2. Secrets scan of the outgoing change (expect: only ${VAR} references and .env.example placeholders)
git diff | grep -inE 'key|token|password|secret|authkey'

# 3. No raw Ollama :11434 introduced (only acceptable hit: mcp/vision/server.py code default,
#    which compose overrides — see non-negotiable 1)
grep -rn '11434' compose/ mcp/ vault-indexer/ wiki-ingest.py

# 4. New env vars have .env.example entries (real values go only in on-machine .env)
ls compose/nas/.env.example compose/desktop/.env.example .env.example

# 5. Target deploy path confirmed:
#    NAS:     /volume1/docker/ai/docker-compose.yml
#    Desktop: /opt/docker/librechat-stack/

# 6. Port-collision check on the TARGET machine (Class E especially; :9622 is occupied by unexplained lightrag-trading — see warning above)
ssh -i ~/.ssh/agent_ed25519 agent@10.0.0.250 'sudo /usr/local/bin/docker ps --format "{{.Names}}\t{{.Ports}}"'
ssh -i ~/.ssh/agent_ed25519 agent@10.0.0.243 'sudo docker ps --format "{{.Names}}\t{{.Ports}}"'

# 7. Class D only — RAG Engine idle and state backed up
#    (LIGHTRAG_API_KEY lives in the .env beside the NAS compose file — do not copy it anywhere)
ssh -i ~/.ssh/agent_ed25519 agent@10.0.0.250 \
  'curl -s -H "X-API-Key: $(grep ^LIGHTRAG_API_KEY /volume1/docker/ai/.env | cut -d= -f2)" http://localhost:9621/documents/pipeline_status'
ssh -i ~/.ssh/agent_ed25519 agent@10.0.0.250 \
  'cp /volume1/docker/ai/vault-indexer/hashes.json /volume1/docker/ai/vault-indexer/hashes.json.pre-deploy.$(date +%Y%m%d)'

# 8. Rollback command written down BEFORE deploying (e.g. the migration's rollback keeps
#    LightRAG storage and hashes.json untouched until cutover — docs/specs/minirag-migration.md).

# 9. Desktop new-service only: dedicated nologin service user named (non-negotiable 4).
```

(Step 7's `.env` path is inferred from the compose deploy path — compose resolves `${LIGHTRAG_API_KEY}` from a sibling `.env`. Marked ASSUMPTION; verify with `ssh ... 'ls /volume1/docker/ai/.env'` before relying on it.)

## Post-deploy verification

Do not declare a Class C/D/E change done on "the container started." Run the smoke checklist and acceptance evidence in `home-infra-validation-and-qa` (what counts as evidence, representative queries, thresholds), then run the convergence checklist above. For measurement scripts, see `home-infra-diagnostics`.

## When NOT to use this skill

- Looking up a port, env var, model, or flag → `home-infra-config-reference`.
- Diagnosing a symptom (nothing being changed yet) → `home-infra-debugging-playbook`, `home-infra-diagnostics`.
- Reading full incident narratives → `home-infra-failure-archaeology`.
- The current repo-vs-live drift list and load-bearing invariants → `home-infra-architecture-contract`.
- Executing the MiniRAG migration steps → `minirag-migration-campaign` (each step still cites its gate class here).
- Build/deploy mechanics (buildx, registry, compose workflow) → `home-infra-build-and-deploy`.
- SSH/logs/manual-run mechanics → `home-infra-run-and-operate`.
- Writing the ADR itself → `home-infra-docs-and-writing`.

## Provenance and maintenance

- Facts verified 2026-07-02 against repo state (commit `6cbd3a1` + committed (ebc8e9e/521df55/8fcc49c/34988d1) MiniRAG-migration changes) and live containers observed via SSH 2026-07-02. Commits `f2565b4`, `3ec836f`, `654891a` read via `git show`; ADRs 0001/0002/0003/0010/0011/0012 and `docs/specs/minirag-migration.md` read in full.
- Standing-instruction rules (3, 4, 5; parts of 2 and 7) source: project owner standing instructions — not derivable from repo files alone.
- Re-verification one-liners (run from repo root):
  - Broker rule / :11434 sweep: `grep -rn '11434' compose/ mcp/ vault-indexer/ wiki-ingest.py`
  - Secrets history: `git show 3ec836f --stat && git show 654891a`
  - Fail-hard LIGHTRAG_API_KEY (F5 closed 2026-07-03): `grep -n 'LIGHTRAG_API_KEY' vault-indexer/indexer.py` (expect `sys.exit(...)`, no `"changeme"` fallback)
  - Delete endpoint + archive policy: `grep -n 'delete_document\|ARCHIVE_DAYS' vault-indexer/indexer.py`
  - ADR inventory/style: `ls docs/adr/`
  - Live ports both machines: the two `docker ps` commands in the pre-deploy checklist, step 6
  - minirag port + lightrag-trading mystery: `grep -n 9623 compose/nas/docker-compose.yml` (expect minirag) vs `ssh -i ~/.ssh/agent_ed25519 agent@10.0.0.250 'sudo /usr/local/bin/docker ps' | grep 9622` (expect lightrag-trading, still unexplained)
  - Deploy paths: `head -3 compose/nas/docker-compose.yml compose/desktop/docker-compose.yml` (desktop header is stale — trust `/opt/docker/librechat-stack/` per drift register)
