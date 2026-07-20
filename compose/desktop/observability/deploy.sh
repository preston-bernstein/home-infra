#!/usr/bin/env bash
# Deploy the shared observability stack (Prometheus + Grafana + Loki + Alloy +
# node-exporter + cAdvisor) to the desktop, under its OWN dedicated nologin
# service user `observability` -- never granted `docker` group membership
# (host-root-equivalent); instead gets a NARROW /etc/sudoers.d/observability
# grant scoped to exactly this stack's compose file, mirroring
# scraper-egress/deploy.sh's existing narrow-NOPASSWD sudoers pattern.
#
# How this deliberately DIFFERS from compose/desktop/scraper-egress/deploy.sh:
#   1. Nested directories, not a flat 3-file copy. This stack ships
#      alloy/, prometheus/, loki/, grafana/ (with a provisioning/ subtree),
#      and dashboards/ alongside docker-compose.yml + .env.example, so the
#      rsync step syncs whole directories recursively instead of enumerating
#      individual files.
#   2. UID/GID capture. Containers run pinned to the real `observability`
#      service-user UID/GID (see docker-compose.yml's `user: "${PUID}:${PGID}"`)
#      so bind-mounted data directories are readable/writable without running
#      containers as root. This script captures `id -u`/`id -g` right after
#      user creation and writes them into .env as PUID/PGID, idempotently.
#   3. Bind-mount data directories. Creates
#      /opt/docker/observability/{prometheus,grafana,loki,alloy}-data on the
#      desktop, owned by the service user -- scraper-egress has no persistent
#      bind-mounted data dirs to create.
#   4. Secret generation. If GRAFANA_ADMIN_PASSWORD isn't already set to a
#      non-empty value in the desktop's .env, this script generates a random
#      32-character password and writes it in -- scraper-egress instead makes
#      the operator hand-enter ProtonVPN credentials on the desktop.
#   5. visudo pre-check via a staged temp file before the sudoers drop-in is
#      ever activated; a failed check exits non-zero WITHOUT installing the
#      broken file (scraper-egress also runs `visudo -cf`, but under `set -e`
#      implicitly -- here the pass/fail is handled explicitly).
#
# Idempotent: re-running creates nothing new, never duplicates the sudoers
# entry, never re-chowns/re-creates what already exists correctly, and NEVER
# overwrites an operator-populated .env with the blank .env.example template.
# GRAFANA_ADMIN_PASSWORD, once set, is left untouched on subsequent runs.
#
# This script never echoes, logs, or transfers .env contents, and never runs
# `set -x` around any block that touches .env or secret values.
#
# Authored on the Mac; runs only on the desktop (uses sudo/useradd/visudo).
set -euo pipefail

SSH_HOST="desktop-agent"
SVC_USER="observability"
COMPOSE_DIR="/opt/docker/observability"
# The runtime files (compose, .env.example, alloy/, prometheus/, loki/,
# grafana/, dashboards/) live alongside this script in
# home-infra/compose/desktop/observability/.
SRC_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "==> Ensuring service user ${SVC_USER} + bind-mount data directories on ${SSH_HOST} (nologin, NOT in docker group)"
UID_GID="$(ssh "${SSH_HOST}" 'sudo bash -s' <<'REMOTE'
set -euo pipefail
if id -u observability >/dev/null 2>&1; then
  echo "service user observability already exists" >&2
else
  useradd --system --shell /usr/sbin/nologin observability
  echo "created service user observability" >&2
fi
mkdir -p /opt/docker/observability
mkdir -p /opt/docker/observability/{prometheus,grafana,loki,alloy}-data
chown -R observability:observability /opt/docker/observability
chmod 750 /opt/docker/observability
echo "bind-mount data directories ready" >&2
# Only this line goes to stdout -- everything else above is status noise on
# stderr, so the caller can cleanly capture just "uid:gid".
printf '%s:%s' "$(id -u observability)" "$(id -g observability)"
REMOTE
)"
REAL_UID="${UID_GID%%:*}"
REAL_GID="${UID_GID##*:}"
echo "==> Captured real observability UID:GID = ${REAL_UID}:${REAL_GID}"

echo "==> Installing narrow sudoers grant (docker compose on THIS stack's compose file only -- no docker-group membership)"
ssh "${SSH_HOST}" 'sudo bash -s' <<'REMOTE'
set -euo pipefail
STAGE="$(mktemp)"
cat > "$STAGE" <<'SUDOERS'
observability ALL=(root) NOPASSWD: /usr/bin/docker compose -f /opt/docker/observability/docker-compose.yml *
SUDOERS
if visudo -cf "$STAGE"; then
  install -o root -g root -m 0440 "$STAGE" /etc/sudoers.d/observability
  rm -f "$STAGE"
  echo "sudoers grant installed: /etc/sudoers.d/observability"
else
  echo "ERROR: sudoers syntax check failed -- NOT installing /etc/sudoers.d/observability" >&2
  rm -f "$STAGE"
  exit 1
fi
REMOTE

echo "==> Syncing compose file + nested config directories (alloy/, prometheus/, loki/, grafana/, dashboards/) + .env.example to ${SSH_HOST}:${COMPOSE_DIR}"
# UNLIKE scraper-egress's flat 3-file rsync, this stack has nested
# subdirectories (Prometheus/Loki/Grafana/Alloy configs + dashboard JSON), so
# whole directories are synced recursively (-a) rather than enumerating
# individual files. No trailing slash on the directory sources below -- that
# preserves each directory's own name at the destination instead of
# flattening its contents into COMPOSE_DIR directly.
rsync -az \
  --rsync-path="sudo -u ${SVC_USER} rsync" \
  "${SRC_DIR}/docker-compose.yml" \
  "${SRC_DIR}/.env.example" \
  "${SRC_DIR}/alloy" \
  "${SRC_DIR}/prometheus" \
  "${SRC_DIR}/loki" \
  "${SRC_DIR}/grafana" \
  "${SRC_DIR}/dashboards" \
  "${SSH_HOST}:${COMPOSE_DIR}/"

echo "==> Seeding .env, writing captured PUID/PGID, and ensuring GRAFANA_ADMIN_PASSWORD is set (a re-run NEVER overwrites an already-populated .env; contents are never echoed)"
ssh "${SSH_HOST}" "sudo bash -s" -- "${REAL_UID}" "${REAL_GID}" <<'REMOTE'
set -euo pipefail
REAL_UID="$1"
REAL_GID="$2"
COMPOSE_DIR="/opt/docker/observability"
ENV_FILE="${COMPOSE_DIR}/.env"
ENV_EXAMPLE="${COMPOSE_DIR}/.env.example"

if [[ -f "$ENV_FILE" ]]; then
  echo "existing .env found -- leaving operator-set values in place"
else
  cp "$ENV_EXAMPLE" "$ENV_FILE"
  echo "seeded .env from .env.example"
fi

# Idempotently write PUID/PGID -- replace the line if present, append if not.
if grep -q '^PUID=' "$ENV_FILE"; then
  sed -i "s/^PUID=.*/PUID=${REAL_UID}/" "$ENV_FILE"
else
  echo "PUID=${REAL_UID}" >> "$ENV_FILE"
fi
if grep -q '^PGID=' "$ENV_FILE"; then
  sed -i "s/^PGID=.*/PGID=${REAL_GID}/" "$ENV_FILE"
else
  echo "PGID=${REAL_GID}" >> "$ENV_FILE"
fi

# Generate GRAFANA_ADMIN_PASSWORD only if it isn't already set to a non-empty
# value -- never overwrite an operator- or previous-run-set password. The
# value itself is never echoed or logged.
CURRENT_PW="$(grep '^GRAFANA_ADMIN_PASSWORD=' "$ENV_FILE" 2>/dev/null | head -n1 | cut -d= -f2-)"
if [[ -z "${CURRENT_PW}" ]]; then
  NEW_PW="$(openssl rand -base64 24)"
  if grep -q '^GRAFANA_ADMIN_PASSWORD=' "$ENV_FILE"; then
    sed -i "s#^GRAFANA_ADMIN_PASSWORD=.*#GRAFANA_ADMIN_PASSWORD=${NEW_PW}#" "$ENV_FILE"
  else
    echo "GRAFANA_ADMIN_PASSWORD=${NEW_PW}" >> "$ENV_FILE"
  fi
  unset NEW_PW
  echo "generated a new random GRAFANA_ADMIN_PASSWORD (value not logged)"
else
  echo "GRAFANA_ADMIN_PASSWORD already set -- leaving it untouched"
fi
unset CURRENT_PW

chown observability:observability "$ENV_FILE"
chmod 600 "$ENV_FILE"
echo ".env ready: chmod 600, owned by observability, PUID=${REAL_UID} PGID=${REAL_GID}"
REMOTE

echo "==> Done."
echo "Next: bring the stack up on the desktop as the observability service user:"
echo "  ssh ${SSH_HOST}"
echo "  sudo -u ${SVC_USER} sudo docker compose -f ${COMPOSE_DIR}/docker-compose.yml up -d"
echo "Grafana admin password (auto-generated if this was a first run) is in"
echo "  ${COMPOSE_DIR}/.env on the desktop -- this script never reads, echoes, or transfers it."
