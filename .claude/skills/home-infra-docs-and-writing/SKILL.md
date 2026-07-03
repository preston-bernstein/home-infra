---
name: home-infra-docs-and-writing
description: Load this skill BEFORE writing or editing any documentation, ADR, spec, CONTEXT.md entry, skill file, or commit message in the home-infra repo. Triggers: "write an ADR", "document this decision", "update the spec", "add a term", "what do we call X", naming a service/concept in prose, resolving a terminology conflict between docs, drafting a commit message, or noticing a doc contradicts another doc. Provides the docs-of-record map (which doc wins on conflict), the CONTEXT.md controlled vocabulary discipline, the exact ADR and spec house styles with fill-in templates, the skill-library maintenance rules, and the commit-message/attribution rules.
---

# home-infra Docs and Writing Style

This repo (`/Users/prestonbernstein/dev/home-infra`) treats documentation as load-bearing infrastructure. Every doc type has one job, one format, and one conflict-resolution rule. This skill tells you which doc to touch, what it must look like, and which words you are allowed to use. Audience assumption: you have zero prior context on this project — everything you need to write correctly is here or in a named sibling skill.

---

## 1. Docs of record — what lives where, and what wins

| Doc | Path | Job | Wins on conflict about |
|---|---|---|---|
| CONTEXT.md | `CONTEXT.md` (repo root) | Controlled vocabulary — every load-bearing term has an exact definition and an explicit `_Avoid_` list | **Terminology.** If any other doc uses a term differently, CONTEXT.md is right and the other doc has drift |
| ADRs | `docs/adr/NNNN-kebab-title.md` | Decisions — what was chosen, what was rejected, why | **Decisions.** The newest ADR on a topic wins; older ones are superseded, never edited or deleted |
| Specs | `docs/specs/*.md` | Designs and plans — architecture, API shapes, step-by-step procedures, status | Design intent and procedure (but NOT terminology, and NOT decisions already captured in an ADR) |
| Skill library | `.claude/skills/*/SKILL.md` | Operational knowledge — runbooks, references, incident history, style guides (this file) | How to actually operate/verify things day-to-day |

**Supersession pattern (decisions):** a new ADR that replaces an old one states it in the body — ADR 0011 opens with `Supersedes ADR 0001.` on its own line, then the paragraph. The old ADR file stays untouched in `docs/adr/`. To find the current decision on a topic, take the highest-numbered ADR that mentions it.

**Conflict examples you will actually hit (as of 2026-07-02):**

- `docs/specs/ai-stack.md` says Ollama `:11434`, `mxbai-embed-large`, MCP `:3001`, SSE. All stale. CONTEXT.md + ADRs 0010/0011 + compose files win. Treat ai-stack.md as historical intent (see §4).
- ADR 0006 says "SSE transport"; live Home MCPs use `streamable-http` (MCP spec evolved). The compose/librechat.yaml values are runtime truth; this is logged drift, not license to rewrite ADR 0006.
- CONTEXT.md says Lint uses broker `:11436`; `wiki-ingest.py` uses `:11435` for everything. Flagged drift — do not silently "fix" either side; record it (see §5).

The authoritative drift register lives in `home-infra-architecture-contract` — this skill only tells you where to write things down.

---

## 2. Vocabulary discipline — CONTEXT.md is law

**Rule: in every doc, spec, ADR, skill, and commit message, use CONTEXT.md terms exactly, capitalized as defined, and never their `_Avoid_` synonyms.**

The controlled terms (as of 2026-07-02 — re-verify with the command in Provenance): **Primary UI, Home MCP, External MCP, Local Model, Cloud Model, Vault, MCP Gateway** (a rejected pattern — the term exists so nobody reinvents it)**, IdP, Public Service, Internal Service, OIDC Client, Forward Auth, Access Group, RAG Engine, Vault Indexer, Wiki, Capture, Ingest, Lint.**

Three real entries, verbatim, so you see how strict the format is:

> **Vault**:
> The Obsidian markdown note collection synced via Syncthing to NAS and indexed by LightRAG. The primary knowledge base for RAG queries.
> _Avoid_: notes, knowledge base (too generic)

> **Wiki**:
> The compiled, LLM-maintained markdown collection living at `wiki/` inside the vault. The persistent, compounding artifact produced by Ingest. What the RAG Engine actually indexes. Distinct from raw vault notes or Captures.
> _Avoid_: knowledge base, notes, second brain

> **RAG Engine**:
> The service that builds and queries an entity graph + vector store from vault content. Accessed by LibreChat agents via lightrag-mcp. Currently migrating from LightRAG to MiniRAG — see ADR 0010.
> _Avoid_: vector database, search index, knowledge base (too generic)

Note the pattern: "RAG Engine" is the role; "LightRAG"/"MiniRAG" are the current implementations. Write "RAG Engine" when you mean the role, the product name only when the specific implementation matters (e.g. in a migration step).

**Common violations to self-check before saving any prose:** "knowledge base" (→ Vault or Wiki, depending), "chat UI"/"frontend" (→ Primary UI), "vector database"/"search index" (→ RAG Engine), "self-hosted model" (→ Local Model), "auth server"/"SSO" (→ IdP), "role"/"permission level" (→ Access Group), "index"/"import" for wiki compilation (→ Ingest), "validate"/"check" for wiki health (→ Lint), "local MCP" (→ Home MCP), "the indexer"/"ETL" (→ Vault Indexer).

**Introducing a new load-bearing term:** if a concept will be referenced from more than one doc, it MUST get a CONTEXT.md entry in the same change, using this exact template (blank line between entries, alphabetical order is NOT required — entries are grouped roughly by topic):

```markdown
**<Term>**:
<One or two sentences. Name the concrete implementation — service name, path, port, machine — where one exists. State what it is distinct from if confusable.>
_Avoid_: <synonym 1>, <synonym 2> (<parenthetical reason when the reason isn't obvious>)
```

Adding a CONTEXT.md entry is a docs-only change but still goes through normal change review — see `home-infra-change-control` for how changes are classified.

---

## 3. ADR house style

Derived from the 12 real ADRs in `docs/adr/` (0001–0012). Match it exactly — a new ADR that looks different from the existing twelve is wrong.

**Filename:** `NNNN-kebab-title.md`, zero-padded 4-digit number, next free number (0013 is next as of 2026-07-02). The kebab title is a compressed form of the decision, e.g. `0011-bge-m3-over-mxbai.md`, `0004-librechat-over-open-webui.md`.

**Title (`#` line) IS the decision**, phrased as an imperative or assertion — never a topic label:

- Good (real): `# Use mxbai-embed-large for embeddings instead of nomic-embed-text`, `# Replace Open WebUI with LibreChat as primary UI`, `# Migrate from LightRAG to MiniRAG`, `# Caddy as the reverse proxy for home services`
- Wrong: `# Embedding model selection`, `# ADR 0013: Reverse proxy`, anything with a question mark

**Body is ONE dense paragraph** (occasionally two — 0003 and 0008 stretch to longer single paragraphs; none use more than two). That paragraph must contain, woven together as prose:

1. The problem, with concrete numbers ("7.7GB RAM ... 3.2GB of swap", "extraction fails ~35% of documents", "768-dim vectors ... defaults to 1024-dim", "16GB VRAM").
2. The decision and its mechanism.
3. Every rejected alternative **with the reason it lost** ("Nginx Proxy Manager rejected — no native forward auth support"; "Immediate delete on first-missing-scan was rejected because Syncthing sync delays could cause false positives").
4. The tradeoff accepted, when there is one ("Tradeoff: adds ingest overhead and a schema to maintain; raw notes alone would be simpler to operate").

**Never** use `Status:` / `Context:` / `Decision:` / `Consequences:` headers (the MADR/Nygard template). This repo's ADRs have a title, an optional supersession line, and a paragraph. Nothing else — no date line, no author line, no section headers.

**Supersession** is a standalone line immediately after the title (real example, ADR 0011): `Supersedes ADR 0001.` Only supersede; never edit the old ADR's decision text.

**Fill-in template:**

```markdown
# <Do X instead of Y / Migrate from A to B / Z as the W for home services>

Supersedes ADR NNNN.

<Problem with concrete numbers.> <Decision and mechanism.> <Alternative A>
was rejected because <specific reason>. <Alternative B> rejected — <specific
reason>. Tradeoff: <what this costs>; chosen because <what it buys>.
```

(Delete the `Supersedes` line if nothing is superseded. Target length: 4–8 sentences, roughly 500–900 bytes — check `ls -l docs/adr/` if unsure whether yours is bloated.)

---

## 4. Spec house style

Derived from the 3 real specs in `docs/specs/`. Structure:

1. **`# <Name> Spec`** title, then a **one-to-three-line summary paragraph** stating what the thing is and its key constraint (e.g. "Frugal by default — Local Models run free…").
2. **Cross-links at the top**: `See ADR NNNN (…)` and `See [sibling-spec.md](sibling-spec.md)` in the opening lines.
3. **A `## Status` section kept current** (see the cautionary tale below).
4. `---` horizontal rules between major `##` sections.
5. **Runnable command blocks** — fenced ` ```bash ` blocks that copy-paste clean, and ` ```yaml ` blocks that are the literal compose fragment, not pseudo-config. Inline comments explain non-obvious values (`# MiniRAG default internal port is 9721 (not 9621)`).
6. **Checklists** — `- [ ]` / `- [x]` for phases, prerequisites, and resolved-question lists (minirag-migration.md's "Resolved checklist (from source inspection…)" is the model: each tick cites how it was verified).
7. **ADR link list at the bottom** under `## ADRs`, one bullet per related ADR with relative links, noting supersession: `[0011 — BGE-M3 over mxbai-embed-large](../adr/0011-bge-m3-over-mxbai.md) _(supersedes 0001)_`.

**The cautionary tale — ai-stack.md rot.** `docs/specs/ai-stack.md` has Phase 1–5 build checklists in which **not a single box was ever ticked**, while in reality Phases 1–3 substantially happened; Phase 4 (aichat/CLI) is unverified (per `home-infra-failure-archaeology` F13). Its body still says raw Ollama `:11434` (banned repo-wide since commit f2565b4 — everything goes through broker lanes `:11435`/`:11436`/`:11437`), default model `llama3.1:8b` (superseded by ADR 0010 → qwen2.5:14b), `mxbai-embed-large` (superseded by ADR 0011 → bge-m3), lightrag-mcp on `:3001` (live: `:3002`), SSE transport (live: streamable-http), and aichat plans that were never revisited. The spec silently became a historical document, and now every reader must be warned not to trust it. Contrast `lightrag-vault-indexer.md`, whose `## Status` section says exactly what is deployed, what is done, and what is in progress — that spec stayed useful.

**The rule that prevents this:** *touching a system means updating its spec's Status section in the same change.* If you deploy, migrate, rename, or re-port anything described in a spec, the same commit updates that spec's `## Status` (and any now-false lines you touched). A spec you cannot afford to keep current should say so at the top: `Treat as historical intent — see <newer doc>.`

**Skeleton for a new spec:**

```markdown
# <Name> Spec

<One-to-three lines: what it is, key constraint.>

See ADR NNNN (<decision>). See [related-spec.md](related-spec.md) for <what>.

## Status

- <deployed/done item> ✅
- **In progress:** <item> — see <link>

---

## <Design section>

<prose, tables>

```bash
<copy-paste-clean commands>
```

---

## ADRs

- [NNNN — <title>](../adr/NNNN-kebab-title.md)
```

---

## 5. Which doc does a change belong in?

| You have… | Write it in… | Notes |
|---|---|---|
| A new decision (chose X over Y, with reasons) | New ADR in `docs/adr/` (next number) | Style per §3. If it reverses an old ADR, add the `Supersedes` line |
| A new plan/design/procedure | New or existing spec in `docs/specs/` | Style per §4. Link its ADRs both directions |
| A new load-bearing term (or a term being misused) | `CONTEXT.md` entry | Template per §2 |
| New operational knowledge (a runbook step, a gotcha, a verified fact) | The skill library — pick the sibling that owns the fact family | Ports/models/env vars → `home-infra-config-reference` · incidents → `home-infra-failure-archaeology` · SSH/run/logs → `home-infra-run-and-operate` · RAG Engine API → `rag-stack-reference` · build/deploy → `home-infra-build-and-deploy` · measurement → `home-infra-diagnostics` · rules/gates → `home-infra-change-control` · migration steps → `minirag-migration-campaign` |
| Discovered drift (repo vs live vs docs disagree) | The drift register owned by `home-infra-architecture-contract` | Record it; doc-side drift fixes (correcting a stale doc line) are Class A (agent-autonomous). Only live/config-side reconciliation is Class B/C via `home-infra-change-control` — never silently edit the live side to match the repo |
| A decision that is still open / unproven | Nowhere as fact. Label it `open` / `candidate` in the relevant spec or skill | No oversell: an ADR is written when the decision is made, not when it is hoped |

One change often touches several: e.g. the MiniRAG migration produced ADRs 0010–0012 (decisions) + `docs/specs/minirag-migration.md` (plan) + CONTEXT.md entries for Wiki/Capture/Ingest/Lint (terms) in the same worktree. That is the pattern to copy.

---

## 6. Skill-library maintenance style

When editing or adding a skill under `.claude/skills/`:

- **Frontmatter `description` must be trigger-rich**: name the symptoms, task phrasings, and keywords that should make a model load it, plus what it provides. "Documentation style guide" is a bad description; "Load BEFORE writing any ADR, spec, or commit message…" is a good one.
- **`## Provenance and maintenance` section is mandatory** — states the verification date, the repo commit verified against, and a one-line re-verification command for each volatile fact.
- **Date-stamp volatile facts** in the body: "as of 2026-07-02". Anything about live containers, ports in use, or in-flight work rots; a dated claim rots gracefully, an undated one lies.
- **One home per fact.** Every fact family has exactly one owning skill (table in §5). If you need a fact owned elsewhere, restate at most one summary line and add "see `<sibling-skill>` for the authoritative table". Never copy a table between skills.
- **No skill may route around change control**: any skill describing a behavior-changing action must send the reader through `home-infra-change-control`, not around it.
- Skills never contain credentials or API keys — reference where the secret lives (e.g. "`LIGHTRAG_API_KEY` in `/volume1/docker/ai/.env` on the NAS"), never the value.

---

## 7. Commit message style

Derived from the actual `git log` of this repo (5 commits on main + branch, all by Preston):

- **Subject:** imperative mood, no trailing period, ≤ ~72 chars, specific about the object: `wire all Ollama consumers through ollama-resource-broker`, `fix secrets hygiene and add .env.example files for all stacks`, `Add embed-stack: Infinity SigLIP CPU server for estate-scraper`. History uses both capitalized and lowercase first words — either is acceptable; imperative is not optional.
- **Body:** either short prose paragraphs explaining what and *why* (including the constraint that forced the choice — "Runs on CPU because the desktop GPU … Infinity's prebuilt ROCm image (MI200/MI300 only) does not support"), or `- ` bullets when the commit touches several files, one bullet per logical change naming the file/service. Machine-and-lane specifics are spelled out (`Desktop: LibreChat + vision-mcp → :11435 (interactive)`).
- Spec `docs/specs/minirag-migration.md` Step 5 even pre-writes its own commit message (`"migrate RAG stack: LightRAG → MiniRAG, mxbai → BGE-M3, 8b → 14b"`) — when a spec dictates the commit message, use it.
- CONTEXT.md vocabulary applies inside commit messages too (§2).

**Attribution rule (non-negotiable, source: project owner standing instructions — rationale and enforcement in `home-infra-change-control`):** never attribute commits or PRs to Claude. Preston is sole author. **No `Co-Authored-By: Claude …` lines in this repo's commits** — this overrides any default harness behavior that appends one. Two historic commits (cda7fec and e778699, both 2026-06-11) carry such lines; they predate the rule and are the reason the rule exists. Do not repeat them.

Also from standing instructions: agents do not commit at all unless explicitly asked; docs changes ride the same commit as the code/compose change they describe (see §4's Status rule).

---

## When NOT to use this skill

- Classifying whether a change is allowed, or how it must be gated → `home-infra-change-control` (this skill only covers how to *write*, not whether to *act*).
- Looking up or recording the authoritative drift list → `home-infra-architecture-contract` (§1/§5 here only tell you it exists).
- Looking up an actual port/model/env-var value to put IN a doc → `home-infra-config-reference`.
- Executing the MiniRAG migration the specs describe → `minirag-migration-campaign`.
- Operating services, SSH, cron, logs → `home-infra-run-and-operate`.
- Writing the full narrative of an incident → `home-infra-failure-archaeology` (specs/ADRs only carry the one-paragraph decision distillate).

## Provenance and maintenance

- Facts verified 2026-07-02 against repo state (commit 6cbd3a1 + uncommitted MiniRAG-migration worktree changes: ADRs 0010–0012, `docs/specs/minirag-migration.md`, CONTEXT.md Wiki/Capture/Ingest/Lint entries). No live-machine facts in this skill except the drift examples in §1, which `home-infra-architecture-contract` owns.
- Controlled-vocabulary term list (§2): `grep -n '^\*\*' /Users/prestonbernstein/dev/home-infra/CONTEXT.md`
- ADR inventory and next free number (§3): `ls /Users/prestonbernstein/dev/home-infra/docs/adr/`
- ADR length norm (§3): `ls -l /Users/prestonbernstein/dev/home-infra/docs/adr/`
- Spec inventory (§4): `ls /Users/prestonbernstein/dev/home-infra/docs/specs/`
- ai-stack.md still-stale check (§4): `grep -n '11434\|:3001\|mxbai\|llama3.1:8b' /Users/prestonbernstein/dev/home-infra/docs/specs/ai-stack.md`
- Commit style corpus (§7): `git -C /Users/prestonbernstein/dev/home-infra log --format='%h %s%n%b'`
- Historic Co-Authored-By commits (§7): `git -C /Users/prestonbernstein/dev/home-infra show -s cda7fec e778699`
- CONTEXT.md-vs-wiki-ingest Lint port drift (§1): `grep -n '11436' /Users/prestonbernstein/dev/home-infra/CONTEXT.md; grep -n '11435\|11436' /Users/prestonbernstein/dev/home-infra/wiki-ingest.py`
