#!/usr/bin/env bash
# wiki-lint-safe.sh — run the LLM Wiki lint WITHOUT accidentally triggering an ingest.
#
# WHY THIS WRAPPER EXISTS: wiki-ingest.py has a known entry-point bug (see
# home-infra-failure-archaeology): running `python3 wiki-ingest.py --semantic-lint`
# ALONE also runs a full ingest of _raw/ captures — captures get processed and
# DELETED, which is destructive if you only wanted a lint. The safe semantic-lint
# invocation is `--lint --semantic-lint` together (lint_only=true short-circuits
# the ingest branch).
#
# Usage:
#   ./wiki-lint-safe.sh              # structural lint only (orphans, broken wikilinks)
#   ./wiki-lint-safe.sh --semantic   # structural + semantic (LLM via broker :11435) lint
#
# Env: VAULT_PATH overrides the vault location (default in wiki-ingest.py:
#      ~/dev/Obsidian/Home Network Vault). OLLAMA_URL / INGEST_MODEL as in the script.
#
# READ-ONLY with respect to the wiki: both lint modes only read wiki/ pages and
# print issues. The semantic mode calls the local model via the Ollama broker
# (interactive lane :11435) and may take minutes; 503s are retried automatically.

set -euo pipefail

REPO="${REPO:-/Users/prestonbernstein/dev/home-infra}"
INGEST_SCRIPT="$REPO/wiki-ingest.py"

if [ ! -f "$INGEST_SCRIPT" ]; then
  echo "ERROR: $INGEST_SCRIPT not found. wiki-ingest.py lives at the home-infra repo root." >&2
  exit 2
fi

# Prefer the repo venv (has `requests`); fall back to system python3.
PY="$REPO/.venv/bin/python3"
[ -x "$PY" ] || PY="python3"

case "${1:-}" in
  --semantic)
    # SAFE combination: --lint forces lint_only=true, which disables the buggy
    # ingest branch that --semantic-lint alone would trigger.
    exec "$PY" "$INGEST_SCRIPT" --lint --semantic-lint
    ;;
  "")
    exec "$PY" "$INGEST_SCRIPT" --lint
    ;;
  *)
    echo "Usage: $0 [--semantic]" >&2
    echo "Never call wiki-ingest.py --semantic-lint without --lint unless you INTEND to ingest _raw/ captures." >&2
    exit 2
    ;;
esac
