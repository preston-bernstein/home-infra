#!/usr/bin/env bash
# wiki-lint-safe.sh — run the LLM Wiki lint WITHOUT accidentally triggering an ingest.
#
# HISTORY (see home-infra-failure-archaeology F10): wiki-ingest.py used to have an
# entry-point bug where `python3 wiki-ingest.py --semantic-lint` ALONE also ran a
# full ingest of _raw/ captures — destructive if you only wanted a lint. That bug
# was fixed 2026-07-03 (PR #2, commit c14b0bb); `--semantic-lint` alone is now safe
# on its own. This wrapper still calls `--lint --semantic-lint` together, which
# remains correct and harmless either way — kept for explicitness and because typing
# `./wiki-lint-safe.sh --semantic` is a smaller surface for a typo than the two-flag
# form. Not required for safety anymore, but no reason to remove it.
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
    # --lint --semantic-lint together: correct and harmless (see header history note).
    exec "$PY" "$INGEST_SCRIPT" --lint --semantic-lint
    ;;
  "")
    exec "$PY" "$INGEST_SCRIPT" --lint
    ;;
  *)
    echo "Usage: $0 [--semantic]" >&2
    exit 2
    ;;
esac
