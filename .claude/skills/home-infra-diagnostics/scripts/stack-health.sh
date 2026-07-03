#!/usr/bin/env bash
# stack-health.sh — read-only health sweep of the Personal AI Stack.
# Checks, in order: host reachability, SSH, broker lanes, NAS containers,
# RAG Engine pipeline, MiniRAG (migration), lightrag-mcp, desktop containers.
#
# STRICTLY READ-ONLY: pings, curl GETs, `docker ps`, `cat`. Never restarts,
# stops, or mutates anything.
#
# Secrets: LIGHTRAG_API_KEY is taken from the environment if set, otherwise
# read at runtime from /volume1/docker/ai/.env on the NAS via ssh. It is
# NEVER printed and never stored.
#
# Exit code: 0 = no FAILs, 1 = at least one FAIL.
#
# Usage: ./stack-health.sh [-v]   (-v: show raw curl/ssh output on failures)

set -u

DESKTOP=10.0.0.243
NAS=10.0.0.250
SSH_KEY="${SSH_KEY:-$HOME/.ssh/agent_ed25519}"
SSH_OPTS=(-i "$SSH_KEY" -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=accept-new)
NAS_DOCKER="sudo /usr/local/bin/docker"   # docker is NOT in sudo PATH on Synology
CURL="curl -s -m 3 -o /dev/null -w %{http_code}"

VERBOSE=0
[ "${1:-}" = "-v" ] && VERBOSE=1

PASS_N=0; WARN_N=0; FAIL_N=0
pass() { printf 'PASS  %s\n' "$1"; PASS_N=$((PASS_N+1)); }
warn() { printf 'WARN  %s\n' "$1"; WARN_N=$((WARN_N+1)); }
fail() { printf 'FAIL  %s\n' "$1"; FAIL_N=$((FAIL_N+1)); }

section() { printf '\n== %s ==\n' "$1"; }

# ---------------------------------------------------------------- reachability
section "Host reachability"
DESKTOP_UP=0; NAS_UP=0
if ping -c 1 -W 2000 "$DESKTOP" >/dev/null 2>&1; then
  pass "ping desktop ($DESKTOP)"; DESKTOP_UP=1
else
  fail "ping desktop ($DESKTOP) — no ICMP reply. Hint: is the desktop powered on / on the LAN? Are YOU on the home LAN or Tailscale?"
fi
if ping -c 1 -W 2000 "$NAS" >/dev/null 2>&1; then
  pass "ping NAS ($NAS)"; NAS_UP=1
else
  fail "ping NAS ($NAS) — no ICMP reply. Hint: NAS down or you are off-LAN. Everything below that needs the NAS will fail too."
fi

DESKTOP_SSH=0; NAS_SSH=0
if [ ! -f "$SSH_KEY" ]; then
  warn "SSH key $SSH_KEY not found — skipping all SSH checks. Hint: agent identity lives at ~/.ssh/agent_ed25519 (see home-infra-run-and-operate)."
else
  if [ "$DESKTOP_UP" = 1 ] && ssh "${SSH_OPTS[@]}" "agent@$DESKTOP" true 2>/dev/null; then
    pass "ssh agent@$DESKTOP"; DESKTOP_SSH=1
  else
    fail "ssh agent@$DESKTOP — Hint: key must be ~/.ssh/agent_ed25519; never use preston@."
  fi
  if [ "$NAS_UP" = 1 ] && ssh "${SSH_OPTS[@]}" "agent@$NAS" true 2>/dev/null; then
    pass "ssh agent@$NAS"; NAS_SSH=1
  else
    fail "ssh agent@$NAS — Hint: key must be ~/.ssh/agent_ed25519; never use preston@."
  fi
fi

# ---------------------------------------------------------------- broker lanes
section "Ollama resource broker lanes (desktop)"
# Any HTTP status (even 404) proves the listener is up; 000 means no listener.
check_lane() { # $1 label  $2 url  $3 expected-code
  local code
  code=$($CURL "$2" 2>/dev/null)
  if [ "$code" = "$3" ]; then
    pass "$1 -> HTTP $code"
  elif [ "$code" = "000" ] || [ -z "$code" ]; then
    fail "$1 -> no response. Hint: broker down on desktop? Check ~/dev/ollama-resource-broker service on $DESKTOP (host process, not a container). NEVER fall back to raw :11434."
  else
    warn "$1 -> HTTP $code (expected $3) — listener is UP but endpoint answered unexpectedly; broker may have changed routes."
  fi
}
if [ "$DESKTOP_UP" = 1 ]; then
  check_lane "interactive lane :11435 /api/tags" "http://$DESKTOP:11435/api/tags" 200
  check_lane "batch lane       :11436 /api/tags" "http://$DESKTOP:11436/api/tags" 200
  check_lane "durable jobs     :11437 /jobs"     "http://$DESKTOP:11437/jobs"     200
  check_lane "embed lane       :11438 /health"   "http://$DESKTOP:11438/health"   200
else
  warn "desktop unreachable — skipped broker lane checks"
fi

# ---------------------------------------------------------------- NAS containers
section "NAS containers"
# Expected always-up (from compose/nas/docker-compose.yml + live baseline 2026-07-02):
NAS_EXPECTED="lightrag lightrag-mcp vault-indexer tailscale-nas"
# In repo compose but absent live is EXPECTED mid-migration:
NAS_MIGRATION="registry minirag watchtower"
if [ "$NAS_SSH" = 1 ]; then
  NAS_PS=$(ssh "${SSH_OPTS[@]}" "agent@$NAS" "$NAS_DOCKER ps --format '{{.Names}}\t{{.Status}}'" 2>/dev/null)
  if [ -z "$NAS_PS" ]; then
    fail "docker ps on NAS returned nothing. Hint: use sudo /usr/local/bin/docker — plain 'sudo docker' is 'command not found' on Synology."
  else
    for c in $NAS_EXPECTED; do
      status=$(printf '%s\n' "$NAS_PS" | awk -F'\t' -v n="$c" '$1==n{print $2}')
      if [ -z "$status" ]; then
        fail "NAS container '$c' NOT RUNNING. Hint: cd /volume1/docker/ai && sudo /usr/local/bin/docker compose up -d $c (via home-infra-change-control first)."
      elif printf '%s' "$status" | grep -q "Restarting"; then
        fail "NAS container '$c' is crash-looping ($status). Hint: sudo /usr/local/bin/docker logs --tail 50 $c"
      else
        pass "NAS container '$c' ($status)"
      fi
    done
    for c in $NAS_MIGRATION; do
      if ! printf '%s\n' "$NAS_PS" | awk -F'\t' -v n="$c" '$1==n' | grep -q .; then
        warn "NAS container '$c' in repo compose but not running — EXPECTED while MiniRAG migration is pending (see minirag-migration-campaign)."
      else
        pass "NAS container '$c' running (migration component live)"
      fi
    done
    # Known live-but-undocumented / other-repo containers:
    if printf '%s\n' "$NAS_PS" | grep -q '^lightrag-trading	'; then
      warn "lightrag-trading is running on :9622 — undocumented in this repo; ownership unknown (repo compose assigns minirag to :9623, no longer conflicts). Do not touch; confirm ownership with Preston. See home-infra-architecture-contract drift register."
    fi
    if printf '%s\n' "$NAS_PS" | grep -E '^fashion-monitor-(mcp-server|dashboard)' | grep -q Restarting; then
      warn "fashion-monitor containers crash-looping — known-benign for THIS stack; owned by the fashion-monitor repo, not home-infra."
    fi
    [ "$VERBOSE" = 1 ] && printf '%s\n' "$NAS_PS"
  fi
else
  warn "no NAS SSH — skipped NAS container checks"
fi

# ---------------------------------------------------------------- RAG Engine
section "RAG Engine (LightRAG on NAS :9621)"
if [ "$NAS_UP" = 1 ]; then
  HCODE=$($CURL "http://$NAS:9621/health" 2>/dev/null)
  if [ "$HCODE" = "200" ]; then
    pass "lightrag /health -> 200 (no auth required for /health)"
  elif [ "$HCODE" = "000" ]; then
    fail "lightrag :9621 no response. Hint: container down? ssh agent@$NAS 'sudo /usr/local/bin/docker logs --tail 50 lightrag'"
  else
    warn "lightrag /health -> HTTP $HCODE (expected 200)"
  fi

  # API key: env first, then NAS .env at runtime. Never printed.
  KEY="${LIGHTRAG_API_KEY:-}"
  if [ -z "$KEY" ] && [ "$NAS_SSH" = 1 ]; then
    KEY=$(ssh "${SSH_OPTS[@]}" "agent@$NAS" 'sudo cat /volume1/docker/ai/.env' 2>/dev/null | sed -n 's/^LIGHTRAG_API_KEY=//p' | head -1)
  fi
  if [ -z "$KEY" ]; then
    warn "no LIGHTRAG_API_KEY (env unset, NAS .env unreadable) — skipping pipeline_status. Hint: export LIGHTRAG_API_KEY or fix SSH; the key lives ONLY in /volume1/docker/ai/.env on the NAS."
  else
    PS_JSON=$(curl -s -m 5 -H "X-API-Key: $KEY" "http://$NAS:9621/documents/pipeline_status" 2>/dev/null)
    if [ -z "$PS_JSON" ]; then
      fail "pipeline_status: no response despite /health up — Hint: retry; if persistent check lightrag logs."
    elif printf '%s' "$PS_JSON" | grep -q '"busy":[[:space:]]*true'; then
      warn "pipeline BUSY — indexing in progress. Benign if nightly indexer (cron 04:00) or a manual run is active; do NOT start another ingest now."
    elif printf '%s' "$PS_JSON" | grep -q '"busy":[[:space:]]*false'; then
      pass "pipeline_status: idle (busy=false)"
    else
      warn "pipeline_status: unparseable reply (${PS_JSON:0:80}...) — Hint: wrong API key returns 403; check X-API-Key."
    fi
    [ "$VERBOSE" = 1 ] && printf '%s\n' "${PS_JSON:0:400}"
  fi
else
  warn "NAS unreachable — skipped RAG Engine checks"
fi

# ---------------------------------------------------------------- MiniRAG (migration)
section "MiniRAG (NAS :9623, parallel to production LightRAG)"
if [ "$NAS_UP" = 1 ]; then
  MCODE=$($CURL "http://$NAS:9623/health" 2>/dev/null)
  if [ "$MCODE" = "200" ]; then
    pass "minirag /health -> 200 (no auth required; migration component, not yet indexed/cut over)"
  elif [ "$MCODE" = "000" ]; then
    warn "minirag :9623 no response — EXPECTED if migration not yet deployed to this point; see minirag-migration-campaign. If it was previously up, check: ssh agent@$NAS 'sudo /usr/local/bin/docker logs --tail 50 minirag'"
  else
    warn "minirag /health -> HTTP $MCODE (expected 200)"
  fi
  # No pipeline_status check here: MiniRAG has no such endpoint (confirmed 2026-07-03 via
  # /openapi.json — see home-infra-failure-archaeology F12). Do not add one by analogy.
else
  warn "NAS unreachable — skipped MiniRAG checks"
fi

# ---------------------------------------------------------------- lightrag-mcp
section "lightrag-mcp (NAS :3002)"
if [ "$NAS_UP" = 1 ]; then
  MCODE=$($CURL "http://$NAS:3002/mcp" 2>/dev/null)
  case "$MCODE" in
    000|"") fail "lightrag-mcp :3002 no response. Hint: container down? Clients (LibreChat) hit http://$NAS:3002/mcp directly." ;;
    406|405|400|200) pass "lightrag-mcp :3002/mcp -> HTTP $MCODE (streamable-http server rejects a plain GET — listener is UP; 406 is the healthy answer)" ;;
    *) warn "lightrag-mcp :3002/mcp -> HTTP $MCODE — listener up, unexpected code." ;;
  esac
else
  warn "NAS unreachable — skipped lightrag-mcp check"
fi

# ---------------------------------------------------------------- desktop containers
section "Desktop containers"
DESKTOP_EXPECTED="librechat mongodb vision-mcp proton-email-mcp protonmail-bridge infinity-siglip caddy cloudflared"
if [ "$DESKTOP_SSH" = 1 ]; then
  D_PS=$(ssh "${SSH_OPTS[@]}" "agent@$DESKTOP" "docker ps --format '{{.Names}}\t{{.Status}}' 2>/dev/null || sudo docker ps --format '{{.Names}}\t{{.Status}}'" 2>/dev/null)
  if [ -z "$D_PS" ]; then
    fail "docker ps on desktop returned nothing. Hint: is the docker daemon up? ssh agent@$DESKTOP 'systemctl status docker'"
  else
    for c in $DESKTOP_EXPECTED; do
      status=$(printf '%s\n' "$D_PS" | awk -F'\t' -v n="$c" '$1==n{print $2}')
      if [ -z "$status" ]; then
        fail "desktop container '$c' NOT RUNNING. Hint: stack lives at /opt/docker/librechat-stack (embed-stack separate)."
      elif printf '%s' "$status" | grep -q "Restarting"; then
        fail "desktop container '$c' crash-looping ($status). Hint: docker logs --tail 50 $c"
      else
        pass "desktop container '$c' ($status)"
      fi
    done
    [ "$VERBOSE" = 1 ] && printf '%s\n' "$D_PS"
  fi
else
  warn "no desktop SSH — skipped desktop container checks"
fi

# ---------------------------------------------------------------- summary
printf '\n== Summary ==\n%d PASS, %d WARN, %d FAIL\n' "$PASS_N" "$WARN_N" "$FAIL_N"
if [ "$FAIL_N" -gt 0 ]; then
  printf 'At least one FAIL — see the interpretation guide in SKILL.md, then home-infra-debugging-playbook.\n'
  exit 1
fi
exit 0
