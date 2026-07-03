---
name: home-infra-research-frontier
description: Load this skill when asked "what should we work on next", "what are the open problems / research questions", "can we improve RAG quality / the wiki / the broker", "is this publishable / can we claim X", or when planning experimental (not operational) work on the Personal AI Stack. Provides the ranked open-problem list (graph RAG on 16GB SLMs, compounding LLM Wiki, semantic-lint precision, broker scheduling, MCP-at-scale), each with why current practice fails, this project's specific asset, the first three concrete in-repo steps, and a falsifiable "you have a result when..." milestone — plus the external-positioning note (what may be claimed vs what is unproven) and the pick-up-a-problem checklist.
---

# home-infra Research Frontier

Open problems for the Personal AI Stack in `/Users/prestonbernstein/dev/home-infra`, written for a session with zero prior context. This skill tells you WHAT is worth investigating and WHEN you have a result. It does not tell you how to measure (see `rag-evaluation-methodology`), how to change things safely (see `home-infra-change-control`), or how to operate the stack (see `home-infra-run-and-operate`).

## Framing — what "advancing SOTA" means here

**ASSUMPTION (labeled 2026-07-02 authoring pass; not re-confirmed since):** "advancing SOTA" for this project means **best-in-class frugal SLM-first personal RAG on consumer hardware** — graph RAG quality and a compounding knowledge layer on a single shared 16GB consumer AMD GPU (RX 9070 XT, RDNA4, ROCm 6.2), in a private home lab. It does NOT mean publishable research. Success is measured against this project's own baselines, on this project's own corpus, with the evidence bar defined in `home-infra-validation-and-qa`.

Jargon used below (full vocabulary in `CONTEXT.md`, house rules in `home-infra-docs-and-writing`):

| Term | Meaning here |
|---|---|
| SLM | Small language model that fits 16GB VRAM at Q4 (3b–14b class). 32b+ does not fit (ADR 0010). |
| RAG Engine | The graph-RAG server on the NAS — LightRAG today (:9621), MiniRAG in-flight (:9623 per repo compose). |
| Wiki | The compiled `wiki/` layer of the Obsidian vault, maintained by `wiki-ingest.py` (ADR 0012). |
| Broker | `ollama-resource-broker` on the desktop — all Ollama inference goes through lanes :11435/:11436/:11437/:11438, never raw :11434. Authoritative table in `home-infra-config-reference`. |
| Gold set | Hand-labeled query/answer evaluation set. Definition and construction recipe live in `rag-evaluation-methodology`. |

## External positioning — claimable vs unproven (read before writing anything public)

If any part of this project is ever published, open-sourced, or even described in a README claim, apply this table. Default posture: **no claims without a gold-set eval** (evidence bar per `home-infra-validation-and-qa`).

| Status | Statement |
|---|---|
| Quoted, unreproduced | LightRAG entity-extraction fails on ~35% of documents with llama3.1:8b on this corpus — quoted from ADR 0010; the measurement procedure is unrecorded in the repo. Reproduce via `rag-evaluation-methodology` Recipe 1 before claiming externally. |
| Claimable (measured/verified) | A ~380-file real personal corpus is indexed nightly (369/379 PROCESSED per `docs/specs/lightrag-vault-indexer.md`, as of that spec's status section). |
| Claimable (verified working) | A broker-arbitrated shared consumer GPU serves interactive + batch + durable-job + embed lanes with a 503-and-retry contract (retry ladder 10/30/60/120/180s implemented in `wiki-ingest.py` `chat()`). |
| Open (unproven) | That MiniRAG + qwen2.5:14b closes the extraction-failure gap. Migration is in flight, not done — see `minirag-migration-campaign`. |
| Open (unproven) | That the LLM Wiki compounds — ADR 0012's core bet has zero measurements behind it today. |
| Open (unproven) | Semantic-lint precision — no one has checked what fraction of reported issues are real. |
| Open (unproven) | Any broker scheduling/queueing numbers — no lane metrics exist. |

**Reproducibility bar if anything ships externally:** every number published must carry (a) the exact model tag and quantization (e.g. `qwen2.5:14b`, not "a 14b model"), (b) the exact config (env vars per `home-infra-config-reference`, compose file version), (c) the gold set or eval script it was measured with (recipes in `rag-evaluation-methodology`), and (d) the date and repo commit. ADR 0010's own drift item is the cautionary tale: the 35% number was measured on llama3.1:8b, but the committed compose runs `LLM_MODEL=llama3.2:3b` — a published claim that conflated the two would be wrong (drift register item, authoritative copy in `home-infra-architecture-contract`).

## How to pick up a frontier problem (checklist — do this in order)

1. [ ] Read `home-infra-architecture-contract` first — invariants, drift register, known-weak points. Do not design against stale docs (`docs/specs/ai-stack.md` is historical intent, not truth).
2. [ ] Run the diagnostics baseline (`home-infra-diagnostics`) and record current numbers BEFORE touching anything. No before-number means no result later.
3. [ ] Write a hypothesis-predicts-numbers block (format in `rag-evaluation-methodology`) BEFORE any change: "I predict metric M moves from X to ≥/≤ Y because Z." If you cannot fill in X, go back to step 2.
4. [ ] Classify the work under `home-infra-change-control`. Experiments that touch live services (NAS 10.0.0.250 / desktop 10.0.0.243) are behavior-changing and go through its gates. This skill never routes around change control.
5. [ ] All inference through broker lanes (never `:11434`), all SSH as `agent@` (pattern in `home-infra-run-and-operate`), no writes into the live Obsidian vault at `/volume1/obsidian-vault` without care (Syncthing propagates everywhere). Source: project owner standing instructions.
6. [ ] When you get a result (positive or negative), record it: ADR if it changes a decision, spec status update otherwise (`home-infra-docs-and-writing`). Negative results are results.

## Open problems (ranked)

### Problem 1 — Graph RAG quality on a 16GB consumer AMD GPU with SLMs

**Why current common practice fails here.** Graph-RAG pipelines (LightRAG included) rely on the LLM emitting structured JSON for entity/relationship extraction; upstream guidance is 32b+ models for reliable output (ADR 0010). 32b does not fit 16GB VRAM at usable quantization. At 8b the measured failure baseline on this corpus is ~35% of documents failing extraction (llama3.1:8b, ADR 0010) — a sparse, wrong entity graph and poor query quality. The common "fix" is a bigger GPU or a cloud API; both violate this project's frugal-local constraint.

**This project's specific asset.** A real ~380-file personal corpus (not a synthetic benchmark), a broker-arbitrated shared GPU that makes 14b-class inference actually schedulable alongside gaming/Plex, a measured failure baseline to beat, and a MiniRAG deployment already in flight (MiniRAG is designed for SLMs and does not require structured JSON extraction — ADR 0010; migration plan in `docs/specs/minirag-migration.md`).

**First three concrete steps in this repo:**
1. Execute the migration campaign to get MiniRAG serving: `minirag-migration-campaign` (it owns the step-by-step; blockers as of 2026-07-02 include image not built, registry not running, and live `lightrag-trading` occupying NAS :9622 — FLAG, confirm ownership with Preston, do not resolve unilaterally).
2. Build the gold-set groundedness eval per `rag-evaluation-methodology` and run it against the CURRENT LightRAG (:9621) to freeze the baseline before cutover.
3. Re-index the full corpus into MiniRAG and measure the PROCESSED rate via the indexer's status reporting (operations in `home-infra-run-and-operate`; interpretation in `home-infra-diagnostics`).

**You have a result when:** MiniRAG + qwen2.5:14b achieves ≥97% PROCESSED on the corpus AND beats the LightRAG baseline on the gold-set groundedness eval defined in `rag-evaluation-methodology`. Anything less is not a result; a worse groundedness score is a negative result worth an ADR.

### Problem 2 — Compounding LLM Wiki (ADR 0012, Karpathy pattern)

**Why current common practice fails here.** Standard personal RAG indexes raw notes; retrieval quality is flat — each query fishes in the same unstructured pond. The Karpathy LLM-Wiki pattern claims a compiled, cross-linked wiki layer makes retrieval quality COMPOUND as ingests accumulate. That compounding claim is, as far as this project knows, unmeasured anywhere — including here. **Open: the entire value proposition of ADR 0012 is currently a bet, not a fact.**

**This project's specific asset.** A working `wiki-ingest.py` (repo root, untracked as of 2026-07-02) implementing one-capture-per-call ingest with relevant-page merge context (`RELEVANT_PAGE_CHAR_BUDGET = 10_000`), bulk mode (`BATCH_SIZE>1`, weaker merging), structural lint (orphans, broken wikilinks), and semantic lint — plus a vault-indexer that already excludes `_raw/` so only compiled pages reach the RAG Engine.

**First three concrete steps in this repo:**
1. Define a fixed query set that can be answered from both `wiki/` and the raw notes, per `rag-evaluation-methodology` (same queries, two index configurations).
2. Index `wiki/`-only vs raw-notes-only into the RAG Engine as two separate working dirs and score both on the gold-set groundedness eval — this is the wiki-vs-raw baseline gap at N=now.
3. Re-run the identical eval after each subsequent ingest cycle (ingest operations in `home-infra-run-and-operate`) and log the gap over N cycles.

**You have a result when:** retrieval quality on `wiki/` measurably exceeds the raw-notes baseline on the same queries, AND the gap GROWS across N ingest cycles. The compounding claim is falsifiable by design: a flat or shrinking gap kills ADR 0012's core rationale — record that as a negative-result ADR, not a quiet shrug.

### Problem 3 — Semantic lint as autonomous knowledge QA

**Why current common practice fails here.** Knowledge-base QA is either manual review (doesn't scale, never happens) or embedding-similarity dedup (misses contradictions and staleness entirely). LLM-as-judge linting is widely proposed but its precision on real personal corpora is rarely measured — a linter that cries wolf gets ignored, which is worse than no linter.

**This project's specific asset.** A deployed `SEMANTIC_LINT_SYSTEM` prompt with a concrete issue taxonomy — `CONTRADICTION` / `STALE` / `MISSING-LINK` — and a pipe-delimited report format, batching 8 pages per LLM call (`SEMANTIC_LINT_PAGE_BATCH = 8`), all in `wiki-ingest.py`. **Open question: precision — what fraction of reported issues are real. Unmeasured as of 2026-07-02.**

**Fix the entry-point bug FIRST.** `--semantic-lint` alone also runs a full ingest — safe lint-only invocation is `--lint --semantic-lint` together; full story: `home-infra-failure-archaeology` F10. The fix is behavior-changing, so gate it via `home-infra-change-control`. Do not collect precision data through a code path that silently mutates the wiki mid-measurement.

**First three concrete steps in this repo:**
1. Fix the `--semantic-lint` entry point (change-controlled edit to `wiki-ingest.py`) so lint-only means lint-only; verify with a dry run against a copy of the vault, never the live Syncthing-synced vault.
2. Run `--lint --semantic-lint` over the current `wiki/` and capture the full issue report to a dated file (measurement mechanics per `home-infra-diagnostics`).
3. Hand-label a sample of ≥30 reported issues as real/false-positive, stratified across the three taxonomy classes, following the labeling recipe in `rag-evaluation-methodology`.

**You have a result when:** measured precision on the hand-labeled sample of ≥30 issues meets a pre-declared threshold — declare the threshold in your hypothesis block BEFORE labeling (candidate: ≥70% overall, per-class breakdown reported; the threshold itself is an open choice, not established). Below threshold is also a result: it tells you which taxonomy class to cut or re-prompt.

### Problem 4 — Broker-aware scheduling for mixed workloads on one consumer GPU

**Why current common practice fails here.** Standard practice is one GPU per workload class, or naive queueing inside the inference server. Neither fits a GPU shared with gaming and Plex where interactive chat, batch embeddings, and durable long jobs contend. The broker's 503-when-busy + client-retry contract is a working answer to admission, but **open: nothing about its queueing behavior is measured — 503 rates, retry storms, lane starvation, contention windows are all unknown as of 2026-07-02.**

**This project's specific asset.** A live 4-lane broker (interactive :11435 · batch/embed :11436 · durable jobs :11437/jobs · SigLIP embed lane :11438 with `/embeddings` → `/embeddings_image` rewrite — authoritative table in `home-infra-config-reference`; broker theory in `rag-stack-reference`) plus real mixed clients already wired through it (LibreChat, vault-indexer, wiki-ingest, vision MCP). The broker code itself lives in `~/dev/ollama-resource-broker` on the desktop — NOT in this repo; scheduling-policy changes happen there, but the measurement and the client-side contract live here.

**First three concrete steps in this repo:**
1. Instrument the clients this repo owns: extend the `wiki-ingest.py` retry path and the vault-indexer to log every 503 with timestamp, lane, and retry count (change-controlled; today a 503 only prints to stdout).
2. Add a lane-metrics collection script under the diagnostics home (script location and interpretation conventions per `home-infra-diagnostics`) that samples 503 rates and latency per lane.
3. Run it for one week of normal mixed use and write up the observed contention profile as a dated doc per `home-infra-docs-and-writing`.

**You have a result when:** a week of lane metrics exists AND a scheduling change (made in `ollama-resource-broker`, measured from here) moves a specific pre-declared number — e.g. interactive-lane p95 latency or batch-lane 503 rate. A scheduling change with no before/after metric is not a result.

### Problem 5 (candidate, smaller) — MCP-first personal assistant surface at N>3 services

**CANDIDATE, not committed work.** ADR 0007 chose one-service-per-MCP with nginx path routing over an mcpo gateway. As of 2026-07-02 three MCP servers are wired into LibreChat (lightrag :3002, vision :3003, proton-email :3004, all streamable-http per `compose/desktop/librechat.yaml`), and the nginx `/mcp/*` location blocks in `compose/nas/nginx.conf` are still COMMENTED OUT — clients hit ports directly. **Open: does the one-service-per-MCP pattern hold at N>3, and what breaks first — port sprawl, `mcpSettings.allowedDomains` maintenance, auth duplication, or the never-activated nginx routing?**

**Why current common practice fails here / project asset.** Common practice is either a monolithic gateway (rejected in ADR 0007) or ad-hoc sprawl with no position at all. This project has a stated pattern, three live instances, and a planned-but-dormant routing layer — a real testbed for where the pattern's cost curve bends.

**First three concrete steps in this repo:** (1) Add a fourth MCP service through the existing pattern end-to-end and record every touchpoint you had to edit (compose, librechat.yaml, allowedDomains, .env — homes per `home-infra-config-reference`); (2) count and document the per-service marginal cost as a table; (3) decide, via an adversarial design review against ADR 0007 and the existing docs, whether activating the commented-out nginx `/mcp/*` routes reduces that cost — as a proposal through `home-infra-change-control`, not a unilateral change.

**You have a result when:** the N=4 touchpoint table exists and either confirms the pattern's marginal cost is flat, or identifies the first breaking dimension with a documented example. This one is deliberately small — pick it up as a side quest, not a campaign.

## When NOT to use this skill

- Executing the MiniRAG migration itself → `minirag-migration-campaign` (this skill only frames why it matters).
- How to measure anything (recipes, worked examples, hypothesis-block format, gold-set construction) → `rag-evaluation-methodology`.
- Whether a change is allowed and how it is gated → `home-infra-change-control`. Nothing in this skill authorizes touching live services.
- Ports, models, env vars → `home-infra-config-reference`. Endpoints/auth for the RAG Engine → `rag-stack-reference`.
- Something is broken right now → `home-infra-debugging-playbook`; what went wrong historically → `home-infra-failure-archaeology`.
- Day-to-day operation (SSH, cron, logs, running wiki-ingest) → `home-infra-run-and-operate`; deploying/building → `home-infra-build-and-deploy`.
- What counts as acceptable evidence / smoke checks → `home-infra-validation-and-qa`.

## Provenance and maintenance

- Facts verified 2026-07-02 against repo state (commit 6cbd3a1 + uncommitted MiniRAG-migration worktree changes: ADRs 0010–0012, `docs/specs/minirag-migration.md`, untracked `wiki-ingest.py`, minirag service in `compose/nas/docker-compose.yml`) and live containers observed via SSH 2026-07-02.
- "Advancing SOTA" framing is a labeled ASSUMPTION (2026-07-02 authoring pass; not re-confirmed since); ranked ordering of problems is this author's judgment, labeled as such.
- Model note: `wiki-ingest.py` ingest/lint uses `INGEST_MODEL` default `qwen3:8b` via broker :11435; the RAG Engine models are separate (`llama3.2:3b` committed LightRAG / `qwen2.5:14b` planned MiniRAG). Do not conflate them in any claim.
- Re-verification commands (run before trusting a volatile fact):
  - 35% baseline + SLM rationale: `cat /Users/prestonbernstein/dev/home-infra/docs/adr/0010-minirag-over-lightrag.md`
  - Wiki pattern rationale: `cat /Users/prestonbernstein/dev/home-infra/docs/adr/0012-llm-wiki-compiled-layer.md`
  - Corpus indexed count: `grep -n "files indexed" /Users/prestonbernstein/dev/home-infra/docs/specs/lightrag-vault-indexer.md`
  - Semantic-lint entry-point fix still in place: `sed -n '389,398p' /Users/prestonbernstein/dev/home-infra/wiki-ingest.py` (expect no `elif semantic and not lint_only` branch — closed 2026-07-03)
  - Lint taxonomy + batching: `grep -n "CONTRADICTION\|STALE\|MISSING-LINK\|SEMANTIC_LINT_PAGE_BATCH" /Users/prestonbernstein/dev/home-infra/wiki-ingest.py`
  - MiniRAG compose entry (models, :9623→9721): `grep -n -A12 "minirag:" /Users/prestonbernstein/dev/home-infra/compose/nas/docker-compose.yml`
  - nginx `/mcp/*` still commented out: `grep -n "mcp" /Users/prestonbernstein/dev/home-infra/compose/nas/nginx.conf`
  - MCP servers wired into LibreChat: `grep -n -A3 "mcpServers" /Users/prestonbernstein/dev/home-infra/compose/desktop/librechat.yaml`
  - :9622 occupancy on live NAS (lightrag-trading mystery, unrelated to minirag's port now): `ssh -i ~/.ssh/agent_ed25519 agent@10.0.0.250 'sudo /usr/local/bin/docker ps --format "{{.Names}} {{.Ports}}" | grep 9622'`
