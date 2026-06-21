#!/usr/bin/env bash
# Migrates *arr/Overseerr connection configs from old ATT LAN IPs to new USG LAN IPs.
# Requires: curl, jq
#
# Usage: copy .env.example → .env, fill in keys, then run this script.
# The script sources .env if present; you can also export the vars manually.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "$SCRIPT_DIR/.env" ]] && source "$SCRIPT_DIR/.env"

# ── Fill these in (or set in .env) ──────────────────────────────────────────
OLD_NAS="${OLD_NAS:-}"        # e.g. OLD_NAS_IP  — NAS IP on old ATT network
OLD_DESKTOP="${OLD_DESKTOP:-}" # e.g. OLD_DESKTOP_IP — desktop IP on old ATT network
# ─────────────────────────────────────────────────────────────────────────────

NEW_NAS="10.0.0.250"
NEW_DESKTOP="10.0.0.243"

SONARR_KEY="${SONARR_KEY:-}"
SONARR4K_KEY="${SONARR4K_KEY:-}"
RADARR_KEY="${RADARR_KEY:-}"
LIDARR_KEY="${LIDARR_KEY:-}"
READARR_KEY="${READARR_KEY:-}"
PROWLARR_KEY="${PROWLARR_KEY:-}"
OVERSEERR_KEY="${OVERSEERR_KEY:-}"

# ── Helpers ──────────────────────────────────────────────────────────────────

replace_host() {
  local h="$1"
  if   [[ "$h" == "$OLD_NAS"     ]]; then echo "$NEW_NAS"
  elif [[ "$h" == "$OLD_DESKTOP" ]]; then echo "$NEW_DESKTOP"
  else echo "$h"
  fi
}

is_old() {
  [[ "$1" == "$OLD_NAS" || "$1" == "$OLD_DESKTOP" ]]
}

# ── *arr download clients + indexers ─────────────────────────────────────────

patch_arr() {
  local name="$1" base="$2" key="$3" ver="${4:-v3}"
  echo "=== $name ==="

  for endpoint in downloadclient indexer; do
    local items
    items=$(curl -sf -H "X-Api-Key: $key" "$base/api/$ver/$endpoint") || { echo "  SKIP $endpoint (unreachable)"; continue; }
    local count; count=$(echo "$items" | jq 'length')
    for i in $(seq 0 $((count - 1))); do
      local item; item=$(echo "$items" | jq ".[$i]")
      local id;   id=$(echo "$item" | jq '.id')
      local host; host=$(echo "$item" | jq -r '[.fields[]? | select(.name=="host") | .value][0] // ""')
      if is_old "$host"; then
        local new_host; new_host=$(replace_host "$host")
        echo "  $endpoint[$id] host: $host → $new_host"
        local updated; updated=$(echo "$item" | jq --arg h "$new_host" \
          '(.fields[] | select(.name=="host")).value = $h')
        curl -sf -X PUT -H "X-Api-Key: $key" -H "Content-Type: application/json" \
          -d "$updated" "$base/api/$ver/$endpoint/$id" > /dev/null
      fi
    done
  done
}

# ── Prowlarr → *arr app connections ──────────────────────────────────────────

patch_prowlarr() {
  echo "=== Prowlarr Applications ==="
  local apps
  apps=$(curl -sf -H "X-Api-Key: $PROWLARR_KEY" "http://$NEW_NAS:9696/api/v1/applications") || { echo "  SKIP (unreachable)"; return; }
  local count; count=$(echo "$apps" | jq 'length')
  for i in $(seq 0 $((count - 1))); do
    local app; app=$(echo "$apps" | jq ".[$i]")
    local id;  id=$(echo "$app" | jq '.id')
    # walk every string field and replace old IPs
    local has_old; has_old=$(echo "$app" | jq --arg o1 "$OLD_NAS" --arg o2 "$OLD_DESKTOP" \
      '[.. | strings | select(contains($o1) or contains($o2))] | length')
    if [[ "$has_old" -gt 0 ]]; then
      echo "  App $id: replacing old IP references"
      local updated; updated=$(echo "$app" | jq \
        --arg o1 "$OLD_NAS"     --arg n1 "$NEW_NAS" \
        --arg o2 "$OLD_DESKTOP" --arg n2 "$NEW_DESKTOP" \
        'walk(if type == "string" then gsub($o1; $n1) | gsub($o2; $n2) else . end)')
      curl -sf -X PUT -H "X-Api-Key: $PROWLARR_KEY" -H "Content-Type: application/json" \
        -d "$updated" "http://$NEW_NAS:9696/api/v1/applications/$id" > /dev/null
    fi
  done
}

# ── Overseerr → Sonarr / Radarr / Plex ───────────────────────────────────────

patch_overseerr() {
  echo "=== Overseerr ==="
  local base="http://$NEW_NAS:5055"
  local hdr=(-H "X-Api-Key: $OVERSEERR_KEY")

  for svc in sonarr radarr; do
    local instances
    instances=$(curl -sf "${hdr[@]}" "$base/api/v1/settings/$svc") || { echo "  SKIP $svc"; continue; }
    echo "$instances" | jq -c '.[]' | while read -r inst; do
      local id;   id=$(echo "$inst" | jq '.id')
      local host; host=$(echo "$inst" | jq -r '.hostname')
      if is_old "$host"; then
        local new_host; new_host=$(replace_host "$host")
        echo "  $svc[$id] hostname: $host → $new_host"
        local updated; updated=$(echo "$inst" | jq --arg h "$new_host" '.hostname = $h')
        curl -sf -X PUT "${hdr[@]}" -H "Content-Type: application/json" \
          -d "$updated" "$base/api/v1/settings/$svc/$id" > /dev/null
      fi
    done
  done

  # Plex
  local plex; plex=$(curl -sf "${hdr[@]}" "$base/api/v1/settings/plex") || { echo "  SKIP plex"; return; }
  local plex_ip; plex_ip=$(echo "$plex" | jq -r '.ip')
  if is_old "$plex_ip"; then
    local new_ip; new_ip=$(replace_host "$plex_ip")
    echo "  plex ip: $plex_ip → $new_ip"
    local updated; updated=$(echo "$plex" | jq --arg h "$new_ip" '.ip = $h')
    curl -sf -X POST "${hdr[@]}" -H "Content-Type: application/json" \
      -d "$updated" "$base/api/v1/settings/plex" > /dev/null
  fi
}

# ── Guard ─────────────────────────────────────────────────────────────────────

if [[ -z "$OLD_NAS" || -z "$OLD_DESKTOP" ]]; then
  echo "ERROR: set OLD_NAS and OLD_DESKTOP at the top of the script before running"
  exit 1
fi

# ── Run ───────────────────────────────────────────────────────────────────────

patch_arr "Sonarr"   "http://$NEW_NAS:8989" "$SONARR_KEY"
patch_arr "Sonarr4K" "http://$NEW_NAS:8990" "$SONARR4K_KEY"
patch_arr "Radarr"   "http://$NEW_NAS:7878" "$RADARR_KEY"
patch_arr "Lidarr"   "http://$NEW_NAS:8686" "$LIDARR_KEY"
patch_arr "Readarr"  "http://$NEW_NAS:8787" "$READARR_KEY"
patch_prowlarr
patch_overseerr

echo ""
echo "Done. Verify connections in each app's Settings → (Download Clients / Indexers)."
echo "Plex remote access: check Settings → Remote Access in Plex Web and hit retry."
