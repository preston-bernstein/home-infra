#!/usr/bin/env python3
"""
Vault indexer for LightRAG.
Reads Obsidian vault, strips syntax, POSTs to LightRAG API.
Hash-based incremental — unchanged files are skipped.
See docs/specs/lightrag-vault-indexer.md.
"""
import argparse
import hashlib
import json
import logging
import logging.handlers
import os
import re
import sys
import time
from datetime import datetime, timezone, timedelta
from pathlib import Path

import requests

# --- Config ---

LIGHTRAG_URL = os.environ.get("LIGHTRAG_URL", "http://lightrag:9621").rstrip("/")
LIGHTRAG_API_KEY = os.environ.get("LIGHTRAG_API_KEY") or sys.exit("LIGHTRAG_API_KEY env var is required")
# RAG_ENGINE=minirag switches insert/delete to MiniRAG's API shape (found 2026-07-03: MiniRAG
# has no bulk /documents/texts, no track_status, no per-doc delete_document — only
# /documents/text (one doc, no doc_id returned) and a nuclear DELETE /documents that wipes
# everything). Default is unchanged so the nightly LightRAG cron path is not affected.
RAG_ENGINE = os.environ.get("RAG_ENGINE", "lightrag").lower()
VAULT_PATH = Path(os.environ.get("VAULT_PATH", "/vault"))
STATE_DIR = Path(os.environ.get("STATE_DIR", "/state"))
STATE_FILE = Path(os.environ.get("STATE_FILE", str(STATE_DIR / "hashes.json")))
LOG_FILE = STATE_DIR / "indexer.log"

BATCH_SIZE = 10
BATCH_SLEEP_S = 2
TRACK_TIMEOUT_S = 60
# MiniRAG's /documents/text is synchronous — the request blocks until LLM entity
# extraction + embedding finish server-side (unlike LightRAG's async submit-then-poll,
# where TRACK_TIMEOUT_S only bounds the *poll*, not the underlying work). A single doc
# can legitimately take minutes under broker contention; 30s (the old default _post
# timeout) caused every insert to fail as a false timeout, found live 2026-07-03.
MINIRAG_INSERT_TIMEOUT_S = 240
ARCHIVE_DAYS = 30
LOG_MAX_BYTES = 1 * 1024 * 1024

EXCLUDE_DIRS = frozenset({".agents", ".claude", ".obsidian", "_raw"})

# --- Logging ---

def setup_logging():
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    fmt = logging.Formatter("%(asctime)s %(levelname)-8s %(message)s")
    root = logging.getLogger()
    root.setLevel(logging.INFO)

    stdout_handler = logging.StreamHandler(sys.stdout)
    stdout_handler.setFormatter(fmt)
    root.addHandler(stdout_handler)

    file_handler = logging.handlers.RotatingFileHandler(
        LOG_FILE, maxBytes=LOG_MAX_BYTES, backupCount=1
    )
    file_handler.setFormatter(fmt)
    root.addHandler(file_handler)

log = logging.getLogger(__name__)

# --- HTTP ---

def _headers():
    return {"X-API-Key": LIGHTRAG_API_KEY, "Content-Type": "application/json"}

def _get(path: str, timeout: int = 10) -> dict:
    r = requests.get(f"{LIGHTRAG_URL}{path}", headers=_headers(), timeout=timeout)
    r.raise_for_status()
    return r.json()

def _post(path: str, body: dict, timeout: int = 30) -> dict:
    r = requests.post(f"{LIGHTRAG_URL}{path}", headers=_headers(), json=body, timeout=timeout)
    r.raise_for_status()
    return r.json()

def _delete(path: str, body: dict, timeout: int = 30) -> dict:
    r = requests.delete(f"{LIGHTRAG_URL}{path}", headers=_headers(), json=body, timeout=timeout)
    r.raise_for_status()
    return r.json()

# --- State ---

def load_state() -> dict:
    if STATE_FILE.exists():
        try:
            return json.loads(STATE_FILE.read_text())
        except Exception as e:
            log.error(f"Could not load state file: {e} — starting fresh")
    return {}

def save_state(state: dict):
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    tmp = STATE_FILE.with_suffix(".tmp")
    tmp.write_text(json.dumps(state, indent=2, sort_keys=True))
    tmp.rename(STATE_FILE)

# --- Obsidian stripping ---

_FRONTMATTER = re.compile(r"^---\s*\n.*?\n---\s*\n", re.DOTALL)
_DATAVIEW = re.compile(r"```dataview\b.*?```", re.DOTALL | re.IGNORECASE)
_IMAGE_EMBED = re.compile(r"!\[\[[^\]]+\]\]")
_COMMENT = re.compile(r"%%.*?%%", re.DOTALL)
_WIKI_LINK = re.compile(r"\[\[(?:[^\]|]+\|)?([^\]|]+)\]\]")
_TAG = re.compile(r"(?<!\S)#[a-zA-Z][\w/\-]*")

def strip_obsidian(text: str) -> str:
    text = _FRONTMATTER.sub("", text)
    text = _DATAVIEW.sub("", text)
    text = _IMAGE_EMBED.sub("", text)
    text = _COMMENT.sub("", text)
    text = _WIKI_LINK.sub(r"\1", text)
    text = _TAG.sub("", text)
    return text.strip()

# --- Hashing ---

def file_hash(path: Path) -> str:
    return "sha256:" + hashlib.sha256(path.read_bytes()).hexdigest()

# --- Vault walk ---

def collect_vault_files() -> dict[str, Path]:
    return {
        str(p.relative_to(VAULT_PATH)): p
        for p in VAULT_PATH.rglob("*.md")
        if p.relative_to(VAULT_PATH).parts[0] not in EXCLUDE_DIRS
    }

# --- LightRAG ops ---

def pipeline_is_idle() -> bool:
    if RAG_ENGINE == "minirag":
        # No /documents/pipeline_status on MiniRAG, and inserts are synchronous
        # (no async pipeline to be "busy" on) — nothing to check.
        return True
    try:
        status = _get("/documents/pipeline_status")
        # Treat any truthy 'busy'/'is_processing' flag as busy
        if status.get("busy") or status.get("is_processing"):
            log.warning("LightRAG pipeline is busy — skipping run to avoid double-queuing")
            return False
    except Exception as e:
        log.warning(f"Could not check pipeline status ({e}) — proceeding")
    return True

def insert_batch_lightrag(texts: list[str], file_sources: list[str]) -> list[dict]:
    """POST batch, poll track_status, return per-file doc records (may be empty on failure)."""
    try:
        resp = _post("/documents/texts", {"texts": texts, "file_sources": file_sources})
    except Exception as e:
        log.error(f"Batch POST failed: {e}")
        return []

    track_id = resp.get("track_id")
    if not track_id:
        log.error(f"No track_id in insert response: {resp}")
        return []

    deadline = time.monotonic() + TRACK_TIMEOUT_S
    while time.monotonic() < deadline:
        time.sleep(2)
        try:
            ts = _get(f"/documents/track_status/{track_id}")
            docs = ts.get("documents", [])
            total = ts.get("total_count", len(docs))
            summary = ts.get("status_summary", {})
            done = sum(
                v for k, v in summary.items()
                if "FAILED" in k.upper() or "PROCESSED" in k.upper()
            )
            if total > 0 and done >= total:
                return docs
        except Exception as e:
            log.warning(f"track_status poll error: {e}")

    log.warning(f"track_status timeout ({TRACK_TIMEOUT_S}s) for {track_id} — saving partial results")
    try:
        return _get(f"/documents/track_status/{track_id}").get("documents", [])
    except Exception:
        return []

def insert_batch_minirag(texts: list[str], file_sources: list[str]) -> list[dict]:
    """MiniRAG has no bulk endpoint and returns no doc_id — POST one at a time via
    /documents/text and synthesize a stable id from the content hash so incremental
    state tracking still works. InsertResponse only has status/message/document_count,
    so "status": "processing" from a 200 response is the only success signal available."""
    docs = []
    for text, rel in zip(texts, file_sources):
        try:
            resp = _post("/documents/text", {"text": text, "description": rel},
                         timeout=MINIRAG_INSERT_TIMEOUT_S)
            ok = str(resp.get("status", "")).lower() not in ("failed", "error", "")
        except Exception as e:
            log.error(f"/documents/text failed for {rel}: {e}")
            ok = False
        if ok:
            synthetic_id = f"minirag:{hashlib.sha256(text.encode()).hexdigest()[:16]}"
            docs.append({"file_path": rel, "id": synthetic_id, "status": "PROCESSED"})
        else:
            docs.append({"file_path": rel, "status": "FAILED", "error_msg": "insert failed"})
    return docs

def insert_batch(texts: list[str], file_sources: list[str]) -> list[dict]:
    if RAG_ENGINE == "minirag":
        return insert_batch_minirag(texts, file_sources)
    return insert_batch_lightrag(texts, file_sources)

def delete_from_lightrag(doc_ids: list[str]):
    if RAG_ENGINE == "minirag":
        # MiniRAG has no per-document delete — only a nuclear DELETE /documents that wipes
        # everything (Class D / index-destructive, human approval required per
        # home-infra-change-control). Refuse rather than guess; entries stay in state
        # (harmless — they're already past the archive window, just not purged server-side).
        log.warning(
            f"MiniRAG mode: cannot selectively delete {len(doc_ids)} doc(s) — "
            "no per-document delete endpoint exists. Leaving them in state; "
            "requires a human decision (full DELETE /documents wipes everything)."
        )
        return
    try:
        _delete("/documents/delete_document", {"doc_ids": doc_ids})
        log.info(f"Deleted {len(doc_ids)} doc(s) from LightRAG")
    except Exception as e:
        log.error(f"LightRAG delete failed: {e}")

# --- Index run ---

def run_index(state: dict) -> dict:
    if not pipeline_is_idle():
        return state

    vault_files = collect_vault_files()
    log.info(f"Vault: {len(vault_files)} .md files found")

    to_index = []
    for rel, path in sorted(vault_files.items()):
        new_hash = file_hash(path)
        if state.get(rel, {}).get("hash") != new_hash:
            to_index.append((rel, path, new_hash))

    skipped = len(vault_files) - len(to_index)
    log.info(f"To index: {len(to_index)}  |  Unchanged (skip): {skipped}")

    total_batches = (len(to_index) + BATCH_SIZE - 1) // BATCH_SIZE
    indexed = failed = 0

    for batch_num, i in enumerate(range(0, len(to_index), BATCH_SIZE), start=1):
        batch = to_index[i : i + BATCH_SIZE]

        texts, sources, meta = [], [], []
        for rel, path, new_hash in batch:
            try:
                raw = path.read_text(encoding="utf-8", errors="replace")
                stripped = strip_obsidian(raw)
                if not stripped:
                    log.warning(f"Empty after strip: {rel} — skipping")
                    continue
                texts.append(stripped)
                sources.append(rel)
                meta.append((rel, new_hash))
            except Exception as e:
                log.error(f"Read error {rel}: {e}")
                failed += 1

        if not texts:
            continue

        docs = insert_batch(texts, sources)
        doc_by_source = {d.get("file_path"): d for d in docs}

        for rel, new_hash in meta:
            doc = doc_by_source.get(rel)
            if doc and doc.get("id"):
                state[rel] = {"hash": new_hash, "doc_id": doc["id"]}
                status = str(doc.get("status", "")).upper()
                if "FAILED" in status:
                    err = doc.get("error_msg", "")
                    log.warning(f"Processing failed {rel}: {err}")
                indexed += 1
            else:
                log.warning(f"No doc_id for {rel} — will retry next run")
                failed += 1

        log.info(f"Batch {batch_num}/{total_batches} complete")
        # Checkpoint after every batch — a multi-hour run (esp. RAG_ENGINE=minirag, where
        # each doc blocks synchronously and can take minutes) previously only saved state
        # once at the very end via main()'s save_state() call, so any interruption lost
        # ALL progress from the run, not just the current batch. Found live 2026-07-03.
        save_state(state)

        if i + BATCH_SIZE < len(to_index):
            time.sleep(BATCH_SLEEP_S)

    log.info(f"Indexing: {indexed} succeeded, {failed} failed")

    # Mark missing files as archived
    now_iso = datetime.now(timezone.utc).isoformat()
    newly_archived = [
        rel for rel in state
        if rel not in vault_files and "archived_at" not in state[rel]
    ]
    for rel in newly_archived:
        state[rel]["archived_at"] = now_iso
    if newly_archived:
        log.info(f"Archived {len(newly_archived)} file(s) missing from vault")

    # Auto-delete docs archived > ARCHIVE_DAYS
    cutoff = datetime.now(timezone.utc) - timedelta(days=ARCHIVE_DAYS)
    auto_delete = [
        (rel, entry)
        for rel, entry in list(state.items())
        if "archived_at" in entry
        and datetime.fromisoformat(entry["archived_at"]) < cutoff
    ]
    if auto_delete:
        ids = [e["doc_id"] for _, e in auto_delete if e.get("doc_id")]
        if ids:
            delete_from_lightrag(ids)
        for rel, _ in auto_delete:
            del state[rel]
            log.info(f"Auto-deleted (>{ARCHIVE_DAYS}d archived): {rel}")

    return state

# --- Cleanup command ---

def run_cleanup(state: dict) -> dict:
    archived = {rel: e for rel, e in state.items() if "archived_at" in e}
    now = datetime.now(timezone.utc)

    if archived:
        print(f"\n{'Path':<55} {'Age':>5}  {'Archived on':<12}  Doc ID")
        print("-" * 110)
        for rel, entry in sorted(archived.items()):
            dt = datetime.fromisoformat(entry["archived_at"])
            age = (now - dt).days
            print(f"{rel:<55} {age:>4}d  {entry['archived_at'][:10]}  {entry.get('doc_id', '—')}")
    else:
        print("No archived documents.")

    # Report failed docs in LightRAG
    print("\nQuerying LightRAG for failed docs...")
    try:
        page, stuck = 1, []
        while True:
            resp = _post("/documents/paginated", {
                "page": page, "page_size": 200, "status_filter": "failed"
            })
            docs = resp.get("documents", [])
            stuck.extend(docs)
            if len(docs) < 200:
                break
            page += 1
        if stuck:
            print(f"\n{len(stuck)} failed doc(s) in LightRAG:")
            for d in stuck:
                print(f"  {d.get('file_path', '?'):<55} {str(d.get('error_msg', ''))[:60]}")
        else:
            print("No failed docs.")
    except Exception as e:
        print(f"Could not query LightRAG: {e}")

    if not archived:
        return state

    ans = input(f"\nDelete {len(archived)} archived doc(s) from LightRAG and state? [y/N] ").strip().lower()
    if ans != "y":
        print("Aborted — no changes made.")
        return state

    ids = [e["doc_id"] for e in archived.values() if e.get("doc_id")]
    if ids:
        delete_from_lightrag(ids)
    for rel in archived:
        del state[rel]
    print(f"Deleted {len(archived)} archived doc(s).")
    return state

# --- Entry point ---

def main():
    setup_logging()

    parser = argparse.ArgumentParser(description="Obsidian vault indexer for LightRAG")
    parser.add_argument(
        "--cleanup",
        action="store_true",
        help="List archived docs, report failures, prompt to delete",
    )
    args = parser.parse_args()

    state = load_state()

    if args.cleanup:
        state = run_cleanup(state)
    else:
        log.info("=== run start ===")
        state = run_index(state)
        log.info("=== run end ===")

    save_state(state)


if __name__ == "__main__":
    main()
