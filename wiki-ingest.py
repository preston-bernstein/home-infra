#!/usr/bin/env python3
"""
wiki-ingest.py — LLM Wiki ingest + lint for Obsidian vault.

Follows Karpathy's LLM Wiki pattern:
  - Incremental by default (one capture per LLM call) so wiki updates compound
  - Passes full content of relevant existing pages so merges are real merges
  - Structural lint after every ingest
  - Semantic lint (--semantic-lint): LLM checks contradictions, stale claims, missing links

Usage:
  python3 wiki-ingest.py                    # ingest _raw/ one file at a time, then lint
  python3 wiki-ingest.py --lint             # structural lint only
  python3 wiki-ingest.py --semantic-lint    # structural + semantic (LLM) lint
  BATCH_SIZE=3 python3 wiki-ingest.py       # bulk mode: faster, weaker merging
"""

import os
import re
import sys
import time
from pathlib import Path

import requests

# --- Config ---

VAULT = Path(os.environ.get(
    "VAULT_PATH",
    os.path.expanduser("~/dev/Obsidian/Home Network Vault"),
))
RAW_DIR = VAULT / "_raw"
WIKI_DIR = VAULT / "wiki"
SCHEMA_FILE = VAULT / "schema.md"

OLLAMA_URL = os.environ.get("OLLAMA_URL", "http://10.0.0.243:11435")
INGEST_MODEL = os.environ.get("INGEST_MODEL", "qwen3:8b")
BATCH_SIZE = int(os.environ.get("BATCH_SIZE", "1"))
MAX_RETRIES = 5
RETRY_DELAYS = [10, 30, 60, 120, 180]

# Budget for relevant existing page content passed to LLM during ingest.
# Leaves room for system prompt (~800 chars) + schema (~1KB) + capture (~3KB).
RELEVANT_PAGE_CHAR_BUDGET = 10_000

# Pages per LLM call during semantic lint.
SEMANTIC_LINT_PAGE_BATCH = 8

# --- Ollama ---

def chat(system: str, user: str) -> str:
    for attempt, delay in enumerate(RETRY_DELAYS[:MAX_RETRIES], start=1):
        try:
            resp = requests.post(
                f"{OLLAMA_URL}/api/chat",
                json={
                    "model": INGEST_MODEL,
                    "stream": False,
                    "options": {"num_ctx": 8192},
                    "messages": [
                        {"role": "system", "content": system},
                        {"role": "user", "content": user},
                    ],
                },
                timeout=360,
            )
            resp.raise_for_status()
            return resp.json()["message"]["content"]
        except requests.HTTPError as e:
            if e.response is not None and e.response.status_code == 503 and attempt < MAX_RETRIES:
                print(f"  503 from broker (attempt {attempt}/{MAX_RETRIES}) — retrying in {delay}s...")
                time.sleep(delay)
                continue
            raise
        except requests.RequestException as e:
            if attempt < MAX_RETRIES:
                print(f"  Request error (attempt {attempt}/{MAX_RETRIES}): {e} — retrying in {delay}s...")
                time.sleep(delay)
                continue
            raise
    raise RuntimeError("Max retries exceeded")

# --- Wiki helpers ---

_STOPWORDS = {'the', 'a', 'an', 'and', 'or', 'of', 'in', 'to', 'for',
              'is', 'was', 'with', 'on', 'at', 'by', 'from', 'this', 'that'}

def find_relevant_pages(capture_text: str, capture_filename: str) -> dict[str, str]:
    """Return full content of existing wiki pages most relevant to this capture.

    Relevance = how many words from the page's name appear in the capture text.
    Capped at RELEVANT_PAGE_CHAR_BUDGET total chars so context stays in budget.
    """
    if not WIKI_DIR.exists():
        return {}
    pages = {p.stem: p for p in WIKI_DIR.glob("*.md")}
    if not pages:
        return {}

    haystack = (capture_text + " " + capture_filename).lower()
    scored: list[tuple[int, str, Path]] = []

    for stem, path in pages.items():
        words = [w for w in re.split(r"[\s\-_/]+", stem.lower())
                 if len(w) > 3 and w not in _STOPWORDS]
        hits = sum(1 for w in words if w in haystack)
        if hits:
            scored.append((hits, stem, path))

    scored.sort(reverse=True)

    relevant: dict[str, str] = {}
    budget = RELEVANT_PAGE_CHAR_BUDGET
    for _, stem, path in scored:
        content = path.read_text(encoding="utf-8", errors="replace")
        if len(content) > budget:
            break
        relevant[stem] = content
        budget -= len(content)

    return relevant

def all_page_titles() -> str:
    if not WIKI_DIR.exists():
        return "(none yet)"
    stems = sorted(p.stem for p in WIKI_DIR.glob("*.md"))
    return "\n".join(f"- [[{s}]]" for s in stems) if stems else "(none yet)"

def parse_pages(raw: str) -> list[tuple[str, str]]:
    stripped = re.sub(r"^```[a-zA-Z]*\n?", "", raw.strip(), flags=re.MULTILINE)
    stripped = re.sub(r"\n?```$", "", stripped.strip(), flags=re.MULTILINE)
    results = []
    parts = re.split(r"^### PAGE: ", stripped, flags=re.MULTILINE)
    for part in parts[1:]:
        lines = part.split("\n")
        filename = lines[0].strip()
        body_lines = []
        for line in lines[1:]:
            if line.strip() == "### END":
                break
            body_lines.append(line)
        content = "\n".join(body_lines).strip()
        if filename and content:
            results.append((filename, content))
    return results

def sanitize_filename(filename: str) -> str:
    name = filename.replace("\\", "/").split("/")[-1].strip()
    if not name.endswith(".md"):
        name += ".md"
    return name

def write_pages(pages: list[tuple[str, str]]) -> list[str]:
    WIKI_DIR.mkdir(parents=True, exist_ok=True)
    written = []
    for filename, content in pages:
        safe = sanitize_filename(filename)
        if safe != filename:
            print(f"    Flattened: {filename} → {safe}")
        dest = WIKI_DIR / safe
        action = "Updated" if dest.exists() else "Created"
        dest.write_text(content + "\n", encoding="utf-8")
        print(f"    {action}: wiki/{safe}")
        written.append(safe)
    return written

# --- Ingest ---

INGEST_SYSTEM = """\
You are a wiki compiler maintaining a personal second brain in Obsidian markdown.

TASK: Given a capture document, create or UPDATE wiki pages. For each entity in the \
capture, check RELEVANT EXISTING PAGES — if a page already exists for that entity, \
output an updated version that merges old facts with new ones. Do not lose any existing \
facts. Create new pages for entities not yet in the wiki.

ENTITY TYPES: Person, Project, Tool/Service, Concept, Decision, Reference

RULES:
- Use [[Page Name]] for all cross-references (no .md extension, no path prefix)
- Filenames: flat, "Entity Name.md" — no subfolders
- Dense with facts — no padding, no meta-commentary
- Q&A captures (filenames starting with qa-) → "Q&A: Topic.md" Concept page
- The capture filename encodes its original source domain path — use it for context

ALL KNOWN WIKI PAGE TITLES (for writing correct cross-references):
{all_titles}

RELEVANT EXISTING PAGES — read these carefully and MERGE their content with the capture:
{relevant_pages}

OUTPUT FORMAT — output ONLY these blocks, nothing before or after:
### PAGE: Exact Filename.md
(full merged markdown content)
### END
"""

def ingest_one(capture: Path, idx: int, total: int):
    print(f"\n[{idx}/{total}] {capture.name}")
    capture_text = capture.read_text(encoding="utf-8", errors="replace")
    schema = SCHEMA_FILE.read_text(encoding="utf-8", errors="replace") if SCHEMA_FILE.exists() else ""

    relevant = find_relevant_pages(capture_text, capture.name)
    if relevant:
        rel_block = "\n\n".join(
            f"=== {stem}.md ===\n{content}" for stem, content in relevant.items()
        )
        print(f"  Merging into: {', '.join(relevant.keys())}")
    else:
        rel_block = "(no existing pages match this capture — create new pages as needed)"

    system = INGEST_SYSTEM.format(
        all_titles=all_page_titles(),
        relevant_pages=rel_block,
    )
    user = f"SCHEMA:\n{schema}\n\nCAPTURE ({capture.name}):\n{capture_text}"

    print(f"  Calling {INGEST_MODEL} via broker...")
    try:
        response = chat(system, user)
    except Exception as e:
        print(f"  ERROR after retries: {e} — file remains in _raw/")
        return

    pages = parse_pages(response)
    if not pages:
        debug = RAW_DIR / f"{capture.stem}-debug.txt"
        debug.write_text(response, encoding="utf-8")
        print(f"  WARNING: no pages parsed — saved to _raw/{debug.name}")
        return

    write_pages(pages)
    capture.unlink()
    print(f"  Deleted capture: {capture.name}")

def run_ingest():
    RAW_DIR.mkdir(parents=True, exist_ok=True)
    captures = sorted(p for p in RAW_DIR.glob("*.md") if not p.stem.endswith("-debug"))
    if not captures:
        print("No captures in _raw/ — nothing to ingest.")
        return

    total = len(captures)
    if BATCH_SIZE > 1:
        print(f"{total} capture(s) — bulk mode (BATCH_SIZE={BATCH_SIZE}, weaker merging)")
    else:
        print(f"{total} capture(s) — incremental mode (one at a time, full merge context)")

    if BATCH_SIZE == 1:
        for i, capture in enumerate(captures, start=1):
            ingest_one(capture, i, total)
    else:
        # Bulk mode: group files, one LLM call per group (less accurate merging)
        batches = [captures[i:i + BATCH_SIZE] for i in range(0, total, BATCH_SIZE)]
        for bi, batch in enumerate(batches, start=1):
            names = ", ".join(f.name for f in batch)
            print(f"\nBatch {bi}/{len(batches)}: {names}")
            schema = SCHEMA_FILE.read_text(encoding="utf-8", errors="replace") if SCHEMA_FILE.exists() else ""
            system = INGEST_SYSTEM.format(
                all_titles=all_page_titles(),
                relevant_pages="(bulk mode — relevant page lookup disabled)",
            )
            captures_text = "".join(
                f"\n\n--- CAPTURE: {f.name} ---\n{f.read_text(encoding='utf-8', errors='replace')}"
                for f in batch
            )
            user = f"SCHEMA:\n{schema}{captures_text}"
            print(f"  Calling {INGEST_MODEL} via broker...")
            try:
                response = chat(system, user)
            except Exception as e:
                print(f"  ERROR: {e} — files remain in _raw/")
                continue
            pages = parse_pages(response)
            if not pages:
                for f in batch:
                    debug = RAW_DIR / f"{f.stem}-debug.txt"
                    debug.write_text(response, encoding="utf-8")
                print(f"  WARNING: no pages parsed — debug files saved")
                continue
            write_pages(pages)
            for f in batch:
                f.unlink()
                print(f"  Deleted: {f.name}")

# --- Structural lint ---

WIKILINK_RE = re.compile(r"\[\[([^\]|]+?)(?:\|[^\]]+)?\]\]")

def run_structural_lint():
    print("\n--- Structural Lint ---")
    if not WIKI_DIR.exists():
        print("wiki/ does not exist.")
        return
    pages = {p.stem: p for p in WIKI_DIR.glob("*.md")}
    if not pages:
        print("Wiki is empty.")
        return

    incoming: dict[str, list[str]] = {name: [] for name in pages}
    broken: list[tuple[str, str]] = []

    for name, path in pages.items():
        text = path.read_text(encoding="utf-8", errors="replace")
        for link in WIKILINK_RE.findall(text):
            target = link.strip()
            stem = target[:-3] if target.endswith(".md") else target
            if stem in pages:
                incoming[stem].append(name)
            else:
                broken.append((name, target))

    orphans = [n for n, inc in incoming.items() if not inc]
    issues = 0

    if orphans:
        issues += len(orphans)
        print(f"Orphan pages ({len(orphans)}) — no incoming links:")
        for o in sorted(orphans):
            print(f"  [[{o}]]")
    if broken:
        issues += len(broken)
        print(f"Broken wikilinks ({len(broken)}):")
        for page, link in broken:
            print(f"  [[{link}]] in {page}.md")

    if not issues:
        print("Structurally clean.")
    else:
        print(f"\n{issues} structural issue(s) found.")

# --- Semantic lint ---

SEMANTIC_LINT_SYSTEM = """\
You are auditing a personal knowledge wiki for semantic quality issues.

Review the wiki pages below and report ONLY real problems — skip pages with none.

ISSUE TYPES:
- CONTRADICTION: two pages state conflicting facts about the same entity
- STALE: a claim uses "currently", "now", or "latest" in a way that is likely outdated
- MISSING-LINK: an entity is mentioned by name but not wrapped in [[brackets]]

OUTPUT FORMAT (one issue per line):
CONTRADICTION | PageA.md | PageB.md | what conflicts
STALE | Page.md | the stale claim
MISSING-LINK | Page.md | entity name | suggested fix: [[Entity Name]]

If no issues in this batch, output exactly: CLEAN
"""

def run_semantic_lint():
    print("\n--- Semantic Lint ---")
    if not WIKI_DIR.exists() or not list(WIKI_DIR.glob("*.md")):
        print("Wiki empty — nothing to lint.")
        return

    pages = sorted(WIKI_DIR.glob("*.md"))
    batches = [pages[i:i + SEMANTIC_LINT_PAGE_BATCH]
               for i in range(0, len(pages), SEMANTIC_LINT_PAGE_BATCH)]

    total_issues = 0
    for bi, batch in enumerate(batches, start=1):
        print(f"  Semantic batch {bi}/{len(batches)} ({len(batch)} pages)...")
        combined = "\n\n".join(
            f"=== {p.stem}.md ===\n{p.read_text(encoding='utf-8', errors='replace')[:1500]}"
            for p in batch
        )
        try:
            result = chat(SEMANTIC_LINT_SYSTEM, combined)
        except Exception as e:
            print(f"  ERROR: {e}")
            continue

        lines = [l.strip() for l in result.strip().splitlines() if l.strip()]
        issues = [l for l in lines if not l.upper().startswith("CLEAN")]
        if issues:
            total_issues += len(issues)
            for issue in issues:
                print(f"  {issue}")

    if total_issues == 0:
        print("No semantic issues found.")
    else:
        print(f"\n{total_issues} semantic issue(s) found.")

# --- Entry point ---

if __name__ == "__main__":
    args = set(sys.argv[1:])
    lint_only = "--lint" in args
    semantic = "--semantic-lint" in args

    if not lint_only and not semantic:
        run_ingest()

    run_structural_lint()

    if semantic:
        run_semantic_lint()
