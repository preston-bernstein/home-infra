# Golden Queries — Vault RAG gold set

**Status of this file: CANDIDATE home for the gold set (proposed 2026-07-02 by the skill-authoring agent). Preston decides the permanent location.** Procedure for adding/promoting rows: `SKILL.md` §3 in this directory.

Statuses: `seed` (came with the repo docs, expected sources not yet pinned) → `candidate` (expected sources verified to exist and contain the answer) → `certified` (human-approved threshold query). **Only a human promotes to `certified`.**

| # | Query (exact text) | Expected source file(s) (vault-relative) | Grounded answer must mention | Added | Status |
|---|---|---|---|---|---|
| 1 | `what maintenance has been done on the Corolla?` | TBD — likely under a vehicle/automobile area of the Vault (an `Automobile/` area is referenced in `docs/specs/lightrag-vault-indexer.md` TODO). **Human must pin the exact file path(s).** | Specific maintenance events (dates/services) that appear verbatim-adjacent in the source note — not generic car-maintenance advice | 2026-07-02 | seed |
| 2 | `what's my current home network topology?` | TBD — likely under a `Network/` area of the Vault (`Network/AI Infrastructure.md` appears as an example path in `docs/specs/lightrag-vault-indexer.md`). **Human must pin the exact file path(s).** | Actual home-network specifics from the Vault (e.g. the real devices/subnets recorded there) — not a generic topology explanation | 2026-07-02 | seed |

Both queries above are verbatim from `docs/specs/minirag-migration.md` Step 3 (the lightrag-mcp ↔ MiniRAG verification step).

## Groundedness check (how to score a row)

1. Run the query via the LibreChat Vault Assistant (production path: LibreChat → lightrag-mcp `:3002` → RAG Engine) or directly against the RAG Engine `/query` API (endpoint details: `rag-stack-reference`).
2. Open the expected source file(s) in the Vault (read-only!).
3. PASS = the answer's substantive claims are traceable to the source file content. FAIL = generic/hallucinated answer, wrong source, or "no results".
4. Record PASS/FAIL per query in the sign-off block (`SKILL.md` §6). A previously passing row that fails after a change = regression.
