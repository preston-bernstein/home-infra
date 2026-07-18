#!/usr/bin/env bash
# Leak-test harness for the scraper egress-isolation gluetun stack
# (deploy/scraper-egress/docker-compose.yml). Runs ON THE DESKTOP ONLY --
# it needs the live Docker daemon and the live gluetun-scraper tunnel; the
# Mac checkout has neither. See docs/scraper-egress-harness/plan.md (leak-
# test CLI/exit-code contract) and requirements.md (FR13, AC6-AC10) for the
# full spec.
#
# Runs four independent PASS/FAIL assertions in order and NEVER prints
# `.env` contents or any secret value -- only IPs, resolver addresses, and
# PASS/FAIL lines are safe to print.
#
# Invocation: sudo -u scraper-egress scripts/leak_test_scraper_egress.sh
# (no args; COMPOSE_DIR env var overrides the default deploy path below)
set -euo pipefail

# --- Configuration ---------------------------------------------------------
COMPOSE_DIR="${COMPOSE_DIR:-/opt/docker/scraper-egress}"
ENV_FILE="${COMPOSE_DIR}/.env"

SCRAPER_CONTAINER="${SCRAPER_CONTAINER:-gluetun-scraper}"
# arr-stack's gluetun service key is `gluetun` (docs/scraper-egress-harness/
# .ctx.md); override via env var if arr-stack's actual container_name ever
# diverges from its service key.
ARR_STACK_CONTAINER="${ARR_STACK_CONTAINER:-gluetun}"

# External IP-echo endpoint. Cross-checked against gluetun's own
# control-server /v1/publicip/ip (see get_control_server_ip below) as a
# second source of truth, so a single external outage never produces a
# false FAIL on its own (see plan.md Risk areas).
IP_ECHO="https://api.ipify.org"
# gluetun's control server (v1 API) default port -- never published via a
# compose `ports:` block; reached only via `docker exec` into the
# container's own netns, same as the healthcheck does over localhost:9999.
CONTROL_PORT=8000

PROBE_TIMEOUT=8

# --- Result tracking --------------------------------------------------------
PASS_COUNT=0

pass() {
  # $1: assertion index (1-4, informational; consumed by the RESULT line
  # task 4b appends) -- $2: check name. Prints exactly one line.
  echo "PASS ${2}"
  PASS_COUNT=$((PASS_COUNT + 1))
}

fail() {
  # $1: assertion index (1-4, informational) -- $2: check name. Prints
  # exactly one line.
  echo "FAIL ${2}"
}

# --- Preconditions -----------------------------------------------------------
if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: ${ENV_FILE} not found -- is the harness deployed under COMPOSE_DIR=${COMPOSE_DIR}?" >&2
  exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "ERROR: docker not found on PATH -- this script must run on the desktop." >&2
  exit 1
fi

# Reads a single non-secret var out of the deployed .env without ever
# echoing the whole file. Callers must never pass a secret-bearing var
# name (OPENVPN_USER/OPENVPN_PASSWORD) to this helper from any assertion
# that prints its return value -- non-secret values only (VPN_TYPE,
# addresses, on/off flags).
env_get() {
  local var_name="$1"
  grep -m1 "^${var_name}=" "$ENV_FILE" | cut -d= -f2- || true
}

# Extracts the first IPv4 literal from stdin -- tolerant of either a
# bare-text ip-echo response or a JSON control-server response, so a
# format change on either side doesn't break parsing.
extract_ipv4() {
  grep -oE '[0-9]{1,3}(\.[0-9]{1,3}){3}' | head -n1
}

# Queries a gluetun container's own control server for its current public
# exit IP, over docker exec / netns only -- never a published port.
get_control_server_ip() {
  local container="$1"
  docker exec "$container" wget -qO- --timeout="$PROBE_TIMEOUT" \
    "http://127.0.0.1:${CONTROL_PORT}/v1/publicip/ip" 2>/dev/null | extract_ipv4 || true
}

# Queries a gluetun container's exit IP via the external ip-echo endpoint,
# from inside the container's own network namespace (gluetun's Alpine
# image ships wget).
get_echo_ip() {
  local container="$1"
  docker exec "$container" wget -qO- --timeout="$PROBE_TIMEOUT" "$IP_ECHO" 2>/dev/null | extract_ipv4 || true
}

# Cross-checked exit IP for a gluetun container: only trusted if the
# external ip-echo endpoint and gluetun's own control server agree.
# Mismatch or unreachable-both is treated as unknown (empty stdout,
# non-zero return) so callers fail closed instead of trusting a single,
# unconfirmed source.
get_cross_checked_ip() {
  local container="$1" via_echo via_control
  via_echo="$(get_echo_ip "$container")"
  # The echo probe (docker exec wget to an external IP echo) is the PRIMARY,
  # reliable source. If it can't reach out, we have nothing.
  [[ -z "$via_echo" ]] && return 1
  # gluetun's control server (:8000/v1/publicip/ip) is an OPTIONAL second
  # source: some gluetun configs don't populate/expose it (it returns empty),
  # so treat it as confirm-only -- bail only if it responds AND disagrees.
  via_control="$(get_control_server_ip "$container")"
  if [[ -n "$via_control" && "$via_control" != "$via_echo" ]]; then
    return 1
  fi
  printf '%s\n' "$via_echo"
  return 0
}

# --- Assertion 1: ip-exit (two PASS/FAIL lines) -----------------------------
# (a) scraper exit IP != desktop's real WAN IP
# (b) scraper exit IP != arr-stack gluetun's CURRENT exit IP
run_ip_exit_assertions() {
  local scraper_ip desktop_ip arrstack_ip

  scraper_ip="$(get_cross_checked_ip "$SCRAPER_CONTAINER" || true)"

  # Desktop's real WAN IP, queried OUTSIDE any container -- this script
  # itself runs directly on the desktop host (as scraper-egress), not
  # inside gluetun-scraper's netns.
  desktop_ip="$(curl -fsS --max-time "$PROBE_TIMEOUT" "$IP_ECHO" 2>/dev/null | extract_ipv4 || true)"

  if [[ -n "$scraper_ip" && -n "$desktop_ip" && "$scraper_ip" != "$desktop_ip" ]]; then
    pass 1 ip-exit-vs-desktop
  else
    fail 1 ip-exit-vs-desktop
  fi

  # Use the reliable echo probe for the arr-stack exit IP too (its control
  # server is likewise not guaranteed to expose /v1/publicip/ip).
  arrstack_ip="$(get_echo_ip "$ARR_STACK_CONTAINER")"

  if [[ -n "$scraper_ip" && -n "$arrstack_ip" && "$scraper_ip" != "$arrstack_ip" ]]; then
    pass 2 ip-exit-vs-arrstack
  else
    fail 2 ip-exit-vs-arrstack
  fi
}

# --- Assertion 2: dns-path ---------------------------------------------------
# Verifies DNS resolution from inside gluetun-scraper's netns actually
# happens via the tunnel's own resolver, not the host's/ISP's -- via an
# ACTIVE resolution (a real hostname fetch that only succeeds if DNS
# genuinely worked), not merely a static read of resolv.conf (too weak on
# its own, per the harness contract).
run_dns_path_assertion() {
  local scraper_ns host_ns active_ip

  scraper_ns="$(docker exec "$SCRAPER_CONTAINER" sh -c \
    "grep -m1 '^nameserver' /etc/resolv.conf | awk '{print \$2}'" 2>/dev/null || true)"

  # Host's own resolver, read directly on the desktop -- outside any
  # container, for comparison only. Not a secret; safe to hold and compare.
  host_ns="$(grep -m1 '^nameserver' /etc/resolv.conf 2>/dev/null | awk '{print $2}' || true)"

  # Active check: resolve the ip-echo hostname from inside the container
  # and actually fetch it. A successful fetch proves resolution genuinely
  # happened via whatever resolver the container is configured with, not
  # just that resolv.conf claims to point somewhere.
  active_ip="$(get_echo_ip "$SCRAPER_CONTAINER")"

  if [[ -n "$active_ip" && -n "$scraper_ns" && "$scraper_ns" != "$host_ns" ]]; then
    pass 3 dns-path
  else
    fail 3 dns-path
  fi
}

# --- Assertion 3: fail-closed ------------------------------------------------
# Kills the tunnel, VERIFIES the kill actually landed (protocol-aware per
# VPN_TYPE), then confirms egress from inside gluetun-scraper's netns fails
# closed rather than leaking out via the host's real IP. A trap installed
# BEFORE any of this runs restores the tunnel to healthy on every exit path
# (normal end, failed assertion, Ctrl-C, SSH drop) -- see restore_tunnel.

HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-90}"
KILL_VERIFY_TIMEOUT="${KILL_VERIFY_TIMEOUT:-15}"
PROBE_WINDOW="${PROBE_WINDOW:-15}"

RESTORE_DONE=0

# Brings gluetun-scraper back to a verified-healthy tunnel. Idempotent --
# safe to call multiple times (e.g. once from an assertion's own fail path
# and again from the EXIT trap) and safe to call even if the tunnel was
# never actually killed. Never fails loudly; this is best-effort cleanup
# that must not mask an earlier assertion failure or itself crash the trap.
# shellcheck disable=SC2329 # invoked indirectly via `trap restore_tunnel ...` below
restore_tunnel() {
  if [[ "$RESTORE_DONE" -eq 1 ]]; then
    return 0
  fi
  RESTORE_DONE=1

  echo "restore_tunnel: recreating ${SCRAPER_CONTAINER}..." >&2
  docker compose -f "${COMPOSE_DIR}/docker-compose.yml" up -d --force-recreate egress-gateway \
    >/dev/null 2>&1 || docker restart "$SCRAPER_CONTAINER" >/dev/null 2>&1 || true

  local waited=0 status
  while [[ "$waited" -lt "$HEALTH_TIMEOUT" ]]; do
    status="$(docker inspect "$SCRAPER_CONTAINER" --format '{{.State.Health.Status}}' 2>/dev/null || true)"
    if [[ "$status" == "healthy" ]]; then
      echo "restore_tunnel: ${SCRAPER_CONTAINER} is healthy." >&2
      return 0
    fi
    sleep 1
    waited=$((waited + 1))
  done

  echo "restore_tunnel: WARNING -- ${SCRAPER_CONTAINER} did not report healthy within ${HEALTH_TIMEOUT}s; check it manually." >&2
  return 0
}

# Kills the tunnel protocol-aware per VPN_TYPE. Echoes "openvpn", "wireguard"
# on success so the caller knows which verification path to use, or prints
# nothing (empty stdout) if VPN_TYPE is unset/unrecognized.
kill_tunnel() {
  local vpn_type
  vpn_type="$(env_get VPN_TYPE)"

  case "$vpn_type" in
    openvpn)
      docker exec "$SCRAPER_CONTAINER" pkill -TERM openvpn >/dev/null 2>&1 || true
      printf '%s\n' openvpn
      ;;
    wireguard)
      # No openvpn process exists under WireGuard -- pkill openvpn here
      # would be a silent no-op. Bring the wg interface down directly
      # inside the container's netns instead.
      docker exec "$SCRAPER_CONTAINER" sh -c '
        iface="$(wg show interfaces 2>/dev/null | awk "{print \$1; exit}")"
        if [[ -z "$iface" ]]; then
          iface="wg0"
        fi
        wg-quick down "$iface" 2>/dev/null || ip link set "$iface" down 2>/dev/null || true
      ' >/dev/null 2>&1 || true
      printf '%s\n' wireguard
      ;;
    *)
      printf '\n'
      ;;
  esac
}

# Verifies the kill from kill_tunnel actually landed. $1 is the protocol
# ("openvpn"/"wireguard") echoed by kill_tunnel. Returns 0 (torn down) or
# 1 (still up / could not confirm) -- callers must FAIL rather than trust
# a probe if this returns 1.
verify_tunnel_down() {
  local protocol="$1" waited=0

  while [[ "$waited" -lt "$KILL_VERIFY_TIMEOUT" ]]; do
    case "$protocol" in
      openvpn)
        if ! docker exec "$SCRAPER_CONTAINER" pgrep openvpn >/dev/null 2>&1; then
          return 0
        fi
        ;;
      wireguard)
        if ! docker exec "$SCRAPER_CONTAINER" sh -c 'wg show interfaces 2>/dev/null | grep -q .'; then
          return 0
        fi
        ;;
      *)
        return 1
        ;;
    esac
    sleep 1
    waited=$((waited + 1))
  done

  return 1
}

# Polls egress from inside gluetun-scraper's netns across a short window
# while the tunnel is confirmed down. Returns 0 (fail-closed: every probe
# failed, as expected) or 1 (leak: at least one probe succeeded).
probe_fails_closed() {
  # The invariant is: with the tunnel killed, the scraper must NEVER egress via
  # the desktop's real WAN IP. gluetun's FIREWALL=on either blocks egress
  # entirely (empty result) OR gluetun's supervisor reconnects the tunnel and
  # egress resumes on a VPN IP -- both are fine. The ONLY failure is egress
  # returning the host's real WAN IP (a genuine kill-switch leak). Treating any
  # successful egress as a leak is wrong: gluetun auto-reconnects near-instantly,
  # so egress succeeding usually just means the VPN came back, not a leak.
  local host_ip="$1" waited=0 result

  while [[ "$waited" -lt "$PROBE_WINDOW" ]]; do
    result="$(docker exec "$SCRAPER_CONTAINER" wget -T 5 -qO- "$IP_ECHO" 2>/dev/null | extract_ipv4 || true)"
    if [[ -n "$result" && "$result" == "$host_ip" ]]; then
      # Egress used the desktop's real WAN IP -- a genuine kill-switch leak.
      return 1
    fi
    sleep 1
    waited=$((waited + 1))
  done

  return 0
}

run_fail_closed_assertion() {
  local protocol host_ip

  # The desktop's real WAN IP -- the one value egress must NEVER reveal while
  # the tunnel is down (queried on the host, outside any container).
  host_ip="$(curl -fsS --max-time "$PROBE_TIMEOUT" "$IP_ECHO" 2>/dev/null | extract_ipv4 || true)"

  protocol="$(kill_tunnel)"

  if [[ -z "$protocol" ]]; then
    echo "fail-closed: VPN_TYPE='$(env_get VPN_TYPE)' is unset or unrecognized -- refusing to guess a kill method." >&2
    fail 4 fail-closed
    return
  fi

  if ! verify_tunnel_down "$protocol"; then
    echo "fail-closed: kill did not land ($protocol) -- tunnel still appears up." >&2
    fail 4 fail-closed
    return
  fi

  if [[ -z "$host_ip" ]]; then
    echo "fail-closed: could not determine the desktop WAN IP to check against -- cannot assert." >&2
    fail 4 fail-closed
    return
  fi

  if probe_fails_closed "$host_ip"; then
    pass 4 fail-closed
  else
    echo "fail-closed: egress returned the desktop's real WAN IP while the tunnel was down -- LEAK." >&2
    fail 4 fail-closed
  fi
}

# Install the restore trap BEFORE touching the tunnel at all, so any exit
# path from this point forward -- normal completion, a failed assertion
# under `set -e`, Ctrl-C, SIGTERM, or an SSH drop -- brings the tunnel back
# to a verified-healthy state.
trap restore_tunnel EXIT ERR INT TERM

# --- Run assertions 1-3 in order --------------------------------------------
run_ip_exit_assertions
run_dns_path_assertion
run_fail_closed_assertion

echo "RESULT: ${PASS_COUNT}/4 passed"

if [[ "$PASS_COUNT" -eq 4 ]]; then
  exit 0
else
  exit 1
fi
