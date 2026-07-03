---
name: rag-evaluation-methodology
description: Measurement recipes and evidence discipline for evaluating the Personal AI Stack's RAG pipeline. Load when you need to MEASURE something before claiming it — extraction failure rate, embedding truncation, retrieval groundedness, wiki quality, indexing throughput/503 rates — or when comparing two engines/models (LightRAG vs MiniRAG, mxbai vs bge-m3), reproducing or refuting a number cited in an ADR, designing an A/B experiment, or deciding whether evidence is strong enough to write an ADR. Triggers: "how do I measure", "is X actually better", "prove/verify the ~35% claim", "failure rate", "hit rate", "gold set", "eval", "benchmark the index", "compare engines", "is this hypothesis confirmed".
---

# RAG Evaluation Methodology — measure before you claim

This skill is the project's measurement discipline: five runnable recipes, each grounded
in a real measurement from this repo's history, plus the methodology layer that decides
when a measurement counts as evidence. Repo: `/Users/prestonbernstein/dev/home-infra`.

Vocabulary (full definitions in `CONTEXT.md`, the repo's controlled vocabulary):
- **RAG Engine** — the service building/querying an entity graph + vector store from vault
  content. Currently LightRAG on NAS `10.0.0.250:9621`; MiniRAG not deployed as of
  2026-07-02 — its port is `<MINIRAG_PORT>`, pending Gate 0a in `minirag-migration-campaign`
  (ADR 0010, migration in flight).
- **Vault Indexer** — nightly container (`vault-indexer/indexer.py`) that POSTs vault files
  to the RAG Engine; hash-incremental, state in `hashes.json`.
- **Wiki / Capture / Ingest / Lint** — the compiled-layer pattern (ADR 0012): raw Captures in
  `_raw/` are compiled by `wiki-ingest.py` into `wiki/` pages; only `wiki/` reaches the RAG Engine.
- **Broker** — the Ollama resource broker on the desktop (`10.0.0.243:11435` interactive,
  `:11436` batch/embeddings). Never use raw `:11434` (project owner standing instruction).
  Theory in `rag-stack-reference`.

Auth for every RAG Engine call: `X-API-Key` header; the key is `LIGHTRAG_API_KEY` in
`/volume1/docker/ai/.env` on the NAS — never copy its value into files.

```bash
export LIGHTRAG_API_KEY=...        # value from /volume1/docker/ai/.env on the NAS
BASE=http://10.0.0.250:9621        # LightRAG. :9622 answers as lightrag-trading
                                   # (undocumented, do not touch); MiniRAG is :9623, not deployed as of 2026-07-03
```

---

## Recipe 1 — Extraction failure rate

**What it measures.** Fraction of submitted documents the RAG Engine failed to process at
index time. In graph RAG, extraction failure means the document's entities never entered
the graph — queries about it silently fail. This is THE number behind ADR 0010.

**Definition (fix this before measuring):**

```
failure_rate = docs with FAILED status in the engine
               ─────────────────────────────────────
               total docs submitted to the engine
```

**Numerator** — paginate `POST /documents/paginated` with `status_filter: "failed"`
(LOWERCASE, `page_size >= 10` — live-verified 2026-07-02; shape + quirks:
`rag-stack-reference`). The pagination pattern comes from `run_cleanup()` in
`vault-indexer/indexer.py` (the `--cleanup` command's "Querying LightRAG for failed docs"
loop — page_size 200, loop until a page returns fewer than 200) — but note `run_cleanup()`
itself sends uppercase `"FAILED"` and silently errors on current LightRAG (open bug; see
`home-infra-failure-archaeology`). Use the corrected loop:

```bash
# Count FAILED docs (corrected bash port of indexer.py run_cleanup pagination)
page=1; total=0
while :; do
  n=$(curl -s -X POST "$BASE/documents/paginated" \
    -H "X-API-Key: $LIGHTRAG_API_KEY" -H "Content-Type: application/json" \
    -d "{\"page\": $page, \"page_size\": 200, \"status_filter\": \"failed\"}" \
    | jq '.documents | length')
  total=$((total + n))
  [ "$n" -lt 200 ] && break
  page=$((page + 1))
done
echo "FAILED docs: $total"
```

**Denominator** — two options, pick one and state which you used:
1. Count of entries in the indexer state file (what was submitted):
   `sudo /usr/local/bin/docker exec vault-indexer sh -c 'python -c "import json;print(len(json.load(open(\"/state/hashes.json\"))))"'`
   (run on the NAS; includes archived entries — subtract entries carrying `archived_at`
   if you want live-files-only).
2. Paginate `/documents/paginated` with each status filter the engine supports and sum
   (the set of valid `status_filter` values is engine-version-dependent — check
   `$BASE/openapi.json`; UNVERIFIED which values MiniRAG accepts).

**Trap — the log line lies.** `indexer.py` logs `Indexing: N succeeded, M failed`, but its
"failed" counts docs that got **no doc_id** (POST/track_status failures). Docs that got a
doc_id but carry FAILED processing status are counted as *succeeded* there (see
`run_index()` — it logs `Processing failed {rel}` as a warning yet increments `indexed`).
The log line is NOT the extraction failure rate. Use the pagination loop.

**Worked example — ADR 0010's ~35%-at-8b claim.** ADR 0010 states LightRAG extraction
"fails ~35% of documents" at `llama3.1:8b` (structured-JSON entity extraction is too hard
for an 8b model; HKUDS recommends 32b+, which won't fit the 16GB RX 9070 XT). Caveats
before you lean on that number:
- The committed compose now runs LightRAG with `LLM_MODEL=llama3.2:3b` (smaller than the
  8b the number was measured on) — drift item recorded in `home-infra-architecture-contract`.
  A FAILED count from today's live LightRAG is a *3b* measurement, not a reproduction of
  the 8b claim.
- The exact original measurement procedure is not recorded in the ADR — ASSUMPTION: it was
  the `--cleanup` FAILED report over the ~379-file vault corpus
  (`docs/specs/lightrag-vault-indexer.md` records "369/379 files indexed").

**To reproduce/refute on MiniRAG:** index the same corpus into MiniRAG on `<MINIRAG_PORT>`
with a separate state file (the parallel-experiment pattern — see Methodology below and
Step 2 of `docs/specs/minirag-migration.md`).

**PRECONDITIONS (hard):** MiniRAG deployed per `minirag-migration-campaign` Phase 3.
Gate 0a resolved 2026-07-03 — MiniRAG's port is `:9623`, not `:9622` (`:9622` is the
still-unexplained `lightrag-trading` container; never run against it). **Image gate:**
the deployed vault-indexer image may predate `STATE_FILE` support —
if so the env var is silently ignored and the run WRITES PRODUCTION `hashes.json`. Verify
first: `ssh -i ~/.ssh/agent_ed25519 agent@10.0.0.250 'sudo /usr/local/bin/docker exec
vault-indexer grep -c STATE_FILE /app/indexer.py'` (`0` = rebuild the image first; see
`minirag-migration-campaign` Phase 4, which owns the gated procedure).

```bash
# On the NAS — separate STATE_FILE, LightRAG untouched
docker run --rm --network container:lightrag \
  -e LIGHTRAG_URL=http://10.0.0.250:<MINIRAG_PORT> \
  -e LIGHTRAG_API_KEY=${LIGHTRAG_API_KEY} \
  -e VAULT_PATH=/vault -e STATE_FILE=/state/hashes-minirag.json \
  -v /volume1/obsidian-vault:/vault:ro \
  -v /volume1/docker/ai/vault-indexer:/state \
  vault-indexer:latest python /app/indexer.py
```

then run the FAILED pagination loop against `BASE=http://10.0.0.250:<MINIRAG_PORT>`. **Predict
first** (see template below): ADR 0010's mechanism ("MiniRAG does not require structured
JSON extraction") predicts a failure rate near 0% on the same corpus that produced ~35% at
8b. A MiniRAG failure rate ≳10% would *refute* the ADR's mechanism and must be
investigated before cutover. UNVERIFIED: that MiniRAG reports the same FAILED status
vocabulary in `/documents/paginated` — this is part of the Step 3 compatibility check in
`minirag-migration-campaign`; if the endpoint or statuses differ, adapt via
`<MINIRAG_PORT>/openapi.json`.

---

## Recipe 2 — Embedding truncation detection

**Hypothesis (general form).** Facts located past the embedding model's effective token
window are invisible to vector retrieval: the embedding of a long document is dominated by
its head, so a query matching only tail content retrieves nothing.

**Worked example that motivated ADR 0011.** `mxbai-embed-large` "degrades significantly
past ~1k tokens" (ADR 0011); many vault files (maintenance logs, deployment docs) exceed
that, so tail facts were unretrievable. `bge-m3` handles 8192 tokens. The switch was free
because the MiniRAG migration forces a full re-index anyway (ADR 0011). The ~1k figure is
stated in the ADR without a recorded measurement procedure — this recipe is how you would
establish or re-establish it.

**Experiment design:**

1. **Select long documents.** Find vault files over ~4k tokens (heuristic: 1 token ≈ 4
   chars, so >16,000 chars):
   ```bash
   # On the NAS (vault is at /volume1/obsidian-vault, read-only mount for you)
   find /volume1/obsidian-vault -name '*.md' -not -path '*/_raw/*' -size +16k \
     -exec wc -c {} + | sort -n | tail -20
   ```
   Do NOT write planted files into the live vault casually — Syncthing propagates
   everywhere (project owner standing instruction). Prefer *selecting* naturally occurring
   tail facts; if you must plant, use a scratch corpus indexed into the staging engine, not
   the live vault.
2. **Pick fact pairs.** For each doc: one fact from the first ~500 tokens (head), one from
   past the 4k-token mark (tail). Facts must be specific and unique to that doc (a date, a
   part number, an IP).
3. **Write one query per fact** answerable only from that fact.
4. **Run and score.** For each query, `POST /query` (request schema: see
   `rag-stack-reference`, the authoritative API home; confirm fields against
   `$BASE/openapi.json`) and score binary: does the answer contain the fact?
   ```bash
   curl -s -X POST "$BASE/query" \
     -H "X-API-Key: $LIGHTRAG_API_KEY" -H "Content-Type: application/json" \
     -d '{"query": "<the tail-fact question>"}' | jq .
   ```
5. **Compare hit rates**: head vs tail, per embedding model.

**Predicted numbers under the hypothesis** (write yours down before running): with mxbai
(~1k effective window), head hit rate high (≥80%), tail hit rate near floor (≤20%); with
bge-m3 (8192 tokens), head ≈ tail. If tail ≈ head *under mxbai too*, the truncation
hypothesis is refuted for this corpus and ADR 0011's premise needs re-examination.

**Confound to control.** Graph RAG has a second retrieval path: if the index-time LLM
extracted the tail fact into the entity graph, graph traversal can answer even when the
vector misses. To isolate the embedding, run the query in vector-only mode if the engine
exposes one (check `mode` parameter in `$BASE/openapi.json` — mode names UNVERIFIED here;
`rag-stack-reference` owns the API detail), or note that your measurement is
"end-to-end retrievability", not "embedding recall" — say which one you measured.

---

## Recipe 3 — Retrieval groundedness eval

**What it measures.** Whether `/query` answers are grounded in the right vault file — the
end-to-end quality number, and the required protocol for any engine comparison.

**Build a gold set** of `query → expected source file` pairs:
- Seed with the two representative queries already written into Step 3 of
  `docs/specs/minirag-migration.md`: *"what maintenance has been done on the Corolla?"*
  and *"what's my current home network topology?"*.
- Extend to 10–20 pairs covering distinct vault areas. The maintained golden query
  inventory lives in `home-infra-validation-and-qa` — add new pairs there, not here.
- For each pair, record the expected source file path(s) and the 1–3 facts a correct
  answer must contain. Write this down BEFORE running any query.

**Scoring rubric (fix before seeing outputs; two binary criteria per query):**

| Criterion | Pass condition |
|---|---|
| Source correct | Response cites/uses the expected file (check the response's source/references field — field name is engine-version-dependent, confirm via `$BASE/openapi.json`) |
| Answer grounded | Every factual claim in the answer appears in the expected file's actual content (open the file and compare — do not score from memory) |

Score = fraction of gold queries passing both. A grounded-but-wrong-source pass is worth
recording separately: it usually means duplicate content in the corpus, not engine skill.

**A/B protocol for engine comparisons (e.g. LightRAG vs MiniRAG):**
1. **Same corpus** — index the identical vault snapshot into both engines (separate
   `STATE_FILE` per engine, per the parallel-experiment pattern; don't index on different
   days, the vault changes).
2. **Same queries** — the full gold set, run against both.
3. **Blind-ish scoring** — collect all answers into one file with engine labels replaced
   by shuffled `A`/`B`, score against the rubric, then unblind. One person/session builds
   the blind file; scoring happens without access to which engine is which. This is
   "blind-ish" because answer style can leak the engine — the rubric's binary criteria
   limit how much that matters.
4. Report per-engine pass rates plus the per-query table, not just the aggregate.

---

## Recipe 4 — Wiki quality measurement (ADR 0012 pattern)

**Context.** ADR 0012 makes `wiki/` a compiled, LLM-maintained layer: Captures in `_raw/`
are compiled into cross-linked wiki pages; the RAG Engine indexes only the wiki. The ADR's
core bet is that retrieval quality **compounds** as the wiki grows. That bet is measurable.

**Structural lint metrics — already computed for you.** `wiki-ingest.py` (repo root; runs
on the MacBook against `VAULT_PATH`, default `~/dev/Obsidian/Home Network Vault`)
implements `run_structural_lint()`, which reports:
- **Orphan count** — wiki pages with zero incoming `[[wikilinks]]`
- **Broken wikilink count** — `[[links]]` pointing at pages that don't exist

```bash
python3 /Users/prestonbernstein/dev/home-infra/wiki-ingest.py --lint
```

**Semantic lint metrics.** `run_semantic_lint()` in the same file uses a Local Model via
the broker to count CONTRADICTION / STALE / MISSING-LINK issues. Known bug:
`--semantic-lint` alone also runs a full ingest (`home-infra-failure-archaeology` F10) —
the safe lint-only invocation is both flags together:

```bash
python3 /Users/prestonbernstein/dev/home-infra/wiki-ingest.py --lint --semantic-lint
```

(Semantic lint calls the broker at `:11435` per the script's `OLLAMA_URL` default; note
`CONTEXT.md` says Lint uses `:11436` — recorded drift, see `home-infra-architecture-contract`.)

**Time series.** Lint counts are only meaningful as a trend. After every Ingest, append a
dated line to a log you keep outside the vault:

```bash
{ date -u +%F; python3 wiki-ingest.py --lint | grep -iE 'orphan|broken|structurally'; } \
  >> ~/wiki-lint-history.log
```

Healthy compounding predicts: page count grows, orphan/broken counts stay flat or shrink.
Orphans growing linearly with pages means Ingest is creating islands, not compounding.

**The compounding hypothesis itself** (the real test of ADR 0012): retrieval quality on a
wiki-only index beats a raw-notes baseline, and the gap widens over time. Test = Recipe 3
run twice: index `wiki/` into one staging engine instance and the pre-wiki raw notes into
another (separate `STATE_FILE`s and storage dirs), same gold set, blind-ish scoring. As of
2026-07-02 this comparison has **not** been run — the compounding claim is a documented
bet, not a measured result. Label it accordingly.

---

## Recipe 5 — Capacity and latency under the broker

**Indexing throughput.** `indexer.py` logs `Batch N/M complete` with timestamps
(`%(asctime)s` format) to `/state/indexer.log` → `/volume1/docker/ai/vault-indexer/indexer.log`
on the NAS. Each batch is `BATCH_SIZE = 10` files with `BATCH_SLEEP_S = 2` between batches.
Throughput = 10 / (median inter-batch interval):

```bash
# On the NAS
grep 'Batch .* complete' /volume1/docker/ai/vault-indexer/indexer.log | tail -20
# docs/hour ≈ 10 * 3600 / median_seconds_between_lines
```

Bound each measurement by the `=== run start ===` / `=== run end ===` markers so you don't
mix runs.

**503 rate.** The broker returns 503 when the GPU lane is busy; clients must retry
(`wiki-ingest.py`'s `chat()` retries on a 10/30/60/120/180s ladder and prints
`503 from broker (attempt i/5)` lines). 503 rate for a wiki-ingest run = count of those
lines / count of LLM calls — capture stdout to a file and grep. For the indexer path, 503s
surface indirectly as engine-side processing errors; there is no direct 503 counter in
`indexer.log` (the engine, not the indexer, talks to the broker).

**The confound that invalidates naive numbers: GPU contention.** The desktop GPU (RX 9070
XT) is shared with gaming and Plex transcoding. The broker exists precisely to arbitrate
this (see `rag-stack-reference` for broker theory). Consequences for measurement:
- Any throughput/latency number taken while someone is gaming or Plex is transcoding
  measures *contention*, not the pipeline.
- **Protocol: measure off-peak** (the nightly index runs at 4am for this reason —
  `vault-indexer/crontab`: `0 4 * * *`), and **record with every measurement**: wall-clock
  time, broker lane used (`:11435` vs `:11436`), and model. Two numbers taken at different
  hours are not comparable; say so in any report that mixes them.
- Never "fix" slowness by pointing at raw `:11434` to bypass the broker — non-negotiable
  (see `home-infra-change-control`).

---

## Methodology — when a measurement becomes evidence

### The evidence bar

A conclusion is accepted when **one mechanism explains ALL observations — including the
negative ones** — and survives an adversarial refutation pass. "The fix worked" is not
evidence; "the fix worked, AND the mechanism predicts the two cases where it still fails,
AND the strongest rival explanation is ruled out by observation X" is.

**Self-assigned refutation pass** (do this before writing any conclusion into an ADR):
1. Write down the **strongest alternative explanation** for your results — the one a
   skeptical reviewer would raise. (E.g. for Recipe 1: "MiniRAG's failure rate is lower
   because it silently drops hard documents instead of marking them FAILED, not because
   extraction is easier.")
2. Write down the **single observation that would discriminate** between your mechanism
   and the alternative. (E.g.: "doc count in MiniRAG equals docs submitted — check
   `/documents/paginated` totals against the state-file count.")
3. Go take that observation. If you can't, the conclusion ships labeled UNVERIFIED with
   the discriminating observation listed as the open check.

### Hypothesis predicts numbers BEFORE running

Fill this block out **before** executing any recipe — a number you predicted and hit is
evidence; a number you explain after seeing it is a story:

```
HYPOTHESIS:   <mechanism, one sentence>
PREDICTS:     <specific number or range, per measurement>
MEASUREMENT:  <exact command / recipe # you will run>
ACTUAL:       <filled in after — never edit PREDICTS afterward>
VERDICT:      confirmed / refuted / ambiguous (+ what would disambiguate)
```

Worked instance (Recipe 1, MiniRAG): *Hypothesis: MiniRAG needs no structured-JSON
extraction, so SLM extraction failures disappear. Predicts: FAILED rate <5% on the ~379-file
corpus that produced ~35% at 8b under LightRAG. Measurement: Recipe 1 pagination loop
against `<MINIRAG_PORT>` after Step 2 index. Actual: — (not yet run as of 2026-07-02). Verdict: —.*

### Idea lifecycle in this project

The established path from idea to adopted change (the MiniRAG migration is the reference
implementation of the pattern):

1. **Idea** — captured in a spec or ADR draft, never applied directly to the live stack.
2. **Parallel experiment** — run the candidate NEXT TO production, never in place of it:
   separate `STATE_FILE` (`hashes-minirag.json` vs `hashes.json`), parallel port
   (`:9623` vs `:9621`), separate storage dir (`/volume1/docker/ai/minirag/` vs
   `.../lightrag/`). Production stays untouched; rollback = stop the parallel container
   (see `docs/specs/minirag-migration.md` Rollback section). Any experiment you design
   must have this shape before it touches a machine — behavior-changing actions route
   through `home-infra-change-control`.
3. **Measured comparison** — Recipes 1–5 with the prediction block filled in first.
4. **ADR** — one dense paragraph, house style per `home-infra-docs-and-writing`, recording
   decision, mechanism, and numbers.
5. **Adoption or documented retirement.** Rejected alternatives are recorded *inside* the
   ADR that rejected them — that is where retirement lives in this repo. Examples:
   ADR 0004 (Open WebUI retired: no MCP support), ADR 0007 (mcpo gateway rejected:
   designed for stdio packages, not custom services), ADR 0009 (Traefik rejected:
   label-model unwieldy cross-host; Nginx Proxy Manager rejected: no forward auth),
   ADR 0010 (LightRAG-with-workarounds retired: "no Phase 1 workarounds (chunk size,
   GLEANING, 32k context) are applied" — replacement over patching).

### Where good ideas historically came from here

INFERENCE from the ADR record, not a stated policy — two recurring sources:
1. **Pain during operation.** ADR 0001 (embedding dimension mismatch blocked ALL indexing
   — 768-dim nomic vs 1024-dim store), ADR 0011 (mxbai truncation past ~1k tokens making
   long-doc tails unretrievable), ADR 0002 (the non-obvious track_status two-step). The
   pattern: an operational failure gets a mechanism-level diagnosis, and the diagnosis
   becomes the next decision.
2. **Upstream-lab literature.** ADR 0010 (MiniRAG — from HKUDS, the same lab as LightRAG,
   found by following the lab's own SLM-first work), ADR 0012 (Karpathy's LLM Wiki
   pattern). The pattern: adopt an external design when it names the exact problem you
   measured — the measurement comes first, the paper second.

When hunting for the next improvement, those two channels — current operational pain (see
`home-infra-failure-archaeology`) and upstream releases from HKUDS/adjacent labs — are the
historically productive places to look. Open problems live in `home-infra-research-frontier`.

## When NOT to use this skill

- **Starting/stopping/operating the stack, running the indexer or wiki-ingest day-to-day**
  → `home-infra-run-and-operate`.
- **API endpoint/auth details, broker lane theory, graph-RAG concepts** →
  `rag-stack-reference` (authoritative endpoint table lives there).
- **Acceptance thresholds, smoke checklist, sign-off criteria, the golden query inventory**
  → `home-infra-validation-and-qa` (this skill tells you HOW to measure; that one owns
  WHAT passes).
- **Executing the MiniRAG migration itself** → `minirag-migration-campaign`.
- **Ready-made health/drift measurement scripts** → `home-infra-diagnostics`.
- **Debugging a broken stack (symptom → cause)** → `home-infra-debugging-playbook`.

## Provenance and maintenance

- Facts re-verified 2026-07-03 against committed repo state (ADRs 0010/0011/0012,
  `docs/specs/minirag-migration.md`, `wiki-ingest.py`, minirag service in
  `compose/nas/docker-compose.yml`, all committed by `ebc8e9e`/`521df55`/`8fcc49c`).
  No live-machine claims are made here beyond what those files state; container status
  as of 2026-07-02: MiniRAG not yet running, `:9622` occupied by an undocumented
  `lightrag-trading` container — confirm ownership with Preston before using `:9622`
  (see `home-infra-architecture-contract`). MiniRAG itself is `:9623` as of 2026-07-03.
- The ~35% (ADR 0010) and ~1k-token (ADR 0011) figures are quoted from the ADRs; their
  original measurement procedures are not recorded anywhere in the repo — treat Recipes 1
  and 2 as the reproduction protocol, not as confirmation the numbers are current.
- Re-verification one-liners:
  - Pagination pattern: `grep -n 'documents/paginated' /Users/prestonbernstein/dev/home-infra/vault-indexer/indexer.py`
  - Indexer log line semantics: `grep -n 'succeeded' /Users/prestonbernstein/dev/home-infra/vault-indexer/indexer.py`
  - Lint functions + semantic-lint entry-point fix: `grep -n 'run_structural_lint\|run_semantic_lint\|elif semantic' /Users/prestonbernstein/dev/home-infra/wiki-ingest.py` (expect no `elif semantic` match — closed 2026-07-03)
  - Representative queries: `grep -n 'Corolla\|topology' /Users/prestonbernstein/dev/home-infra/docs/specs/minirag-migration.md`
  - Crontab hour: `cat /Users/prestonbernstein/dev/home-infra/vault-indexer/crontab`
  - Compose models/ports: `grep -n 'LLM_MODEL\|EMBEDDING_MODEL\|9621\|9623' /Users/prestonbernstein/dev/home-infra/compose/nas/docker-compose.yml`
  - ADR claims: `cat /Users/prestonbernstein/dev/home-infra/docs/adr/0010-minirag-over-lightrag.md /Users/prestonbernstein/dev/home-infra/docs/adr/0011-bge-m3-over-mxbai.md`
