#!/usr/bin/env bash
# drift-check.sh — compare repo compose files (intent) against live machine compose (runtime).
#
# STRICTLY READ-ONLY: fetches live files via `ssh ... cat`, diffs locally. Never writes
# to either machine. Divergence is NOT automatically a bug — the repo is intent and the
# live file is runtime truth (labeled ASSUMPTION in home-infra-change-control); mid-migration
# divergence is EXPECTED. This script tells you WHERE they differ so you can judge.
#
# Usage: ./drift-check.sh [nas|desktop|all]   (default: all)
#
# Exit code: 0 = no drift, 1 = drift found (inspect output), 2 = could not fetch.

set -u

REPO="${REPO:-/Users/prestonbernstein/dev/home-infra}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/agent_ed25519}"
SSH_OPTS=(-i "$SSH_KEY" -o ConnectTimeout=5 -o BatchMode=yes)

NAS=10.0.0.250
DESKTOP=10.0.0.243

TARGET="${1:-all}"
RC=0

check_pair() { # $1 label  $2 host  $3 remote-path  $4 repo-path  $5 sudo-prefix
  local label="$1" host="$2" remote="$3" local_file="$4" sudo_prefix="$5"
  printf '\n== %s ==\nrepo : %s\nlive : %s@%s:%s\n' "$label" "$local_file" agent "$host" "$remote"

  if [ ! -f "$local_file" ]; then
    printf 'ERROR: repo file missing: %s\n' "$local_file"
    RC=2; return
  fi

  local live
  if ! live=$(ssh "${SSH_OPTS[@]}" "agent@$host" "$sudo_prefix"" cat ""$remote" 2>/dev/null); then
    printf 'ERROR: could not fetch live file (host down, ssh key, or file absent).\n'
    printf 'Hint: ssh -i ~/.ssh/agent_ed25519 agent@%s '\''%s ls -la %s'\''\n' "$host" "$sudo_prefix" "$(dirname "$remote")"
    RC=2; return
  fi

  local diff_out
  diff_out=$(diff -u "$local_file" <(printf '%s\n' "$live") 2>/dev/null)
  if [ -z "$diff_out" ]; then
    printf 'IN SYNC — no drift.\n'
    return
  fi

  [ "$RC" -eq 0 ] && RC=1
  printf 'DRIFT FOUND (repo = "-" lines, live = "+" lines):\n%s\n' "$diff_out"
  printf -- '--- Interpretation hints ---\n'
  case "$label" in
    *NAS*)
      printf '* registry present in repo but not live = EXPECTED (Route B chosen, see minirag-migration-campaign Gate 0c). minirag itself was deployed 2026-07-03 and should now match repo — if it still shows as drift/missing, that is a real regression, not expected.\n'
      printf '* Services in live but not repo (e.g. lightrag-trading, open-webui, immich, financial-pipeline) may live in OTHER compose files or repos — check /volume1/docker/*/docker-compose.yml before assuming drift in THIS file.\n'
      ;;
    *desktop*)
      printf '* Env/volume differences on the desktop often reflect on-machine .env usage — secrets never live in the repo copy.\n'
      ;;
  esac
  printf '* Record real drift in the home-infra-architecture-contract drift register; reconcile via home-infra-change-control (class b/c).\n'
}

if [ "$TARGET" = "nas" ] || [ "$TARGET" = "all" ]; then
  check_pair "NAS compose" "$NAS" "/volume1/docker/ai/docker-compose.yml" \
    "$REPO/compose/nas/docker-compose.yml" "sudo"
fi

if [ "$TARGET" = "desktop" ] || [ "$TARGET" = "all" ]; then
  check_pair "desktop compose" "$DESKTOP" "/opt/docker/librechat-stack/docker-compose.yml" \
    "$REPO/compose/desktop/docker-compose.yml" ""
  check_pair "desktop embed-stack compose" "$DESKTOP" "/opt/docker/embed-stack/docker-compose.yml" \
    "$REPO/compose/desktop/embed-stack/docker-compose.yml" ""
fi

printf '\n== drift-check done (exit %d) ==\n' "$RC"
exit "$RC"
