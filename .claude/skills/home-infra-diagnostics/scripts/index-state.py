#!/usr/bin/env python3
"""index-state.py — report vault-indexer state and (optionally) RAG Engine failures.

STRICTLY READ-ONLY. Fetches the indexer state file from the NAS over SSH
(`ssh agent@10.0.0.250 sudo cat <state-file>`) and reports:
  - total tracked files
  - archived files with ages (two-stage archive->delete, 30-day window, ADR 0003)
  - files without a doc_id (will be retried next indexer run)
  - with --failed: the RAG Engine's failed-document list via /documents/paginated

Secrets: LIGHTRAG_API_KEY from env if set, else read at runtime from
/volume1/docker/ai/.env on the NAS. Never printed, never stored.

stdlib only — no pip installs needed.

Usage:
  ./index-state.py                                  # state summary
  ./index-state.py --failed                         # + query RAG Engine for failed docs
  ./index-state.py --state-file /volume1/docker/ai/vault-indexer/hashes-minirag.json
                                                    # during MiniRAG migration
"""
import argparse
import json
import os
import subprocess
import sys
import urllib.error
import urllib.request
from datetime import datetime, timezone

NAS = "10.0.0.250"
SSH_KEY = os.environ.get("SSH_KEY", os.path.expanduser("~/.ssh/agent_ed25519"))
DEFAULT_STATE_FILE = "/volume1/docker/ai/vault-indexer/hashes.json"
DEFAULT_RAG_URL = f"http://{NAS}:9621"
ARCHIVE_DAYS = 30  # matches vault-indexer/indexer.py ARCHIVE_DAYS


def ssh_cat(remote_path: str) -> str | None:
    cmd = [
        "ssh", "-i", SSH_KEY, "-o", "ConnectTimeout=5", "-o", "BatchMode=yes",
        f"agent@{NAS}", f"sudo cat {remote_path}",
    ]
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=20)
    except FileNotFoundError:
        print("ERROR: ssh binary not found.", file=sys.stderr)
        return None
    except subprocess.TimeoutExpired:
        print(f"ERROR: ssh to agent@{NAS} timed out. Hint: NAS down or you are off-LAN.", file=sys.stderr)
        return None
    if out.returncode != 0:
        print(f"ERROR: could not read {remote_path} on NAS "
              f"(ssh exit {out.returncode}): {out.stderr.strip()[:200]}", file=sys.stderr)
        print("Hint: key must be ~/.ssh/agent_ed25519 (agent@ user, NOPASSWD sudo). "
              "If the file is missing, the indexer has never run with this STATE_FILE.", file=sys.stderr)
        return None
    return out.stdout


def get_api_key() -> str | None:
    key = os.environ.get("LIGHTRAG_API_KEY")
    if key:
        return key
    env_text = ssh_cat("/volume1/docker/ai/.env")
    if env_text:
        for line in env_text.splitlines():
            if line.startswith("LIGHTRAG_API_KEY="):
                return line.split("=", 1)[1].strip()
    return None


def report_state(state: dict) -> None:
    now = datetime.now(timezone.utc)
    archived = {k: v for k, v in state.items() if "archived_at" in v}
    no_doc_id = [k for k, v in state.items() if not v.get("doc_id")]
    active = len(state) - len(archived)

    print(f"Total tracked files : {len(state)}")
    print(f"  active            : {active}")
    print(f"  archived          : {len(archived)}  (auto-delete after {ARCHIVE_DAYS}d)")
    print(f"  without doc_id    : {len(no_doc_id)}")

    if archived:
        print(f"\nArchived files (age / auto-delete in):")
        rows = []
        for rel, entry in archived.items():
            try:
                age = (now - datetime.fromisoformat(entry["archived_at"])).days
            except (ValueError, KeyError):
                age = -1
            rows.append((age, rel))
        for age, rel in sorted(rows, reverse=True):
            eta = ARCHIVE_DAYS - age
            flag = "  <-- past window, deletes on next indexer run" if eta <= 0 else ""
            print(f"  {age:>4}d old  (deletes in {max(eta, 0):>2}d)  {rel}{flag}")

    if no_doc_id:
        print("\nFiles without doc_id (insert never confirmed; indexer retries next run):")
        for rel in sorted(no_doc_id):
            print(f"  {rel}")
        print("Hint: persistent no-doc_id entries mean track_status timed out or the insert "
              "failed — check indexer.log on the NAS and run --failed.")


def report_failed(rag_url: str) -> int:
    key = get_api_key()
    if not key:
        print("\nERROR: no LIGHTRAG_API_KEY (env unset and NAS .env unreadable) — "
              "cannot query failed docs. The key lives ONLY in /volume1/docker/ai/.env on the NAS.",
              file=sys.stderr)
        return 1

    # Live LightRAG (core 1.4.16 / api 0291, verified 2026-07-02) requires
    # LOWERCASE status_filter values and page_size >= 10. Uppercase "FAILED" is a 422.
    page, page_size = 1, 50
    docs, status_counts = [], {}
    while True:
        body = json.dumps({"page": page, "page_size": page_size,
                           "status_filter": "failed"}).encode()
        req = urllib.request.Request(
            f"{rag_url}/documents/paginated", data=body, method="POST",
            headers={"X-API-Key": key, "Content-Type": "application/json"},
        )
        try:
            with urllib.request.urlopen(req, timeout=15) as resp:
                data = json.loads(resp.read())
        except urllib.error.HTTPError as e:
            print(f"\nERROR: /documents/paginated -> HTTP {e.code}: {e.read()[:200]!r}",
                  file=sys.stderr)
            print("Hint: 403 = bad API key; 422 = request shape rejected "
                  "(status_filter must be lowercase, page_size >= 10).", file=sys.stderr)
            return 1
        except (urllib.error.URLError, TimeoutError) as e:
            print(f"\nERROR: cannot reach RAG Engine at {rag_url}: {e}", file=sys.stderr)
            print("Hint: run stack-health.sh first — is the lightrag container up?", file=sys.stderr)
            return 1
        batch = data.get("documents", [])
        docs.extend(batch)
        status_counts = data.get("status_counts", status_counts)
        if len(batch) < page_size:
            break
        page += 1

    print(f"\nRAG Engine document status counts: {json.dumps(status_counts)}")
    print(f"Failed documents: {len(docs)}")
    for d in docs[:40]:
        err = str(d.get("error_msg") or "")[:80].replace("\n", " ")
        print(f"  {d.get('file_path', '?'):<60} {err}")
    if len(docs) > 40:
        print(f"  ... and {len(docs) - 40} more")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--state-file", default=DEFAULT_STATE_FILE,
                    help=f"remote state file on the NAS (default {DEFAULT_STATE_FILE}); "
                         "point at hashes-minirag.json during the MiniRAG migration")
    ap.add_argument("--failed", action="store_true",
                    help="also query the RAG Engine for failed documents")
    ap.add_argument("--rag-url", default=DEFAULT_RAG_URL,
                    help=f"RAG Engine base URL (default {DEFAULT_RAG_URL}; "
                         "for the MiniRAG parallel index use the port resolved at "
                         "migration Gate 0a — :9622 is lightrag-trading as of 2026-07-02)")
    ap.add_argument("--json", action="store_true", help="dump raw state JSON to stdout")
    args = ap.parse_args()

    raw = ssh_cat(args.state_file)
    rc = 0
    if raw is None:
        rc = 1
    else:
        try:
            state = json.loads(raw)
        except json.JSONDecodeError as e:
            print(f"ERROR: {args.state_file} is not valid JSON: {e}", file=sys.stderr)
            print("Hint: a partial write should be impossible (indexer writes .tmp then renames) — "
                  "check you named the right file.", file=sys.stderr)
            return 1
        if args.json:
            print(json.dumps(state, indent=2, sort_keys=True))
        else:
            report_state(state)

    if args.failed:
        rc = max(rc, report_failed(args.rag_url.rstrip("/")))
    return rc


if __name__ == "__main__":
    sys.exit(main())
