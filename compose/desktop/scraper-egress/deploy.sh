#!/usr/bin/env bash
# Deploy the scraper egress-isolation harness (gluetun + ProtonVPN) to the
# desktop, under its OWN dedicated nologin service user -- fully isolated
# from the Kalshi executor / algo-factory app user / live.db. This script
# never adds scraper-egress to the host `docker` group (docker-group
# membership is host-root-equivalent and would defeat the isolation this
# harness exists to provide) -- it grants docker-compose access via a
# NARROW sudoers.d drop-in scoped to exactly this harness's compose file,
# mirroring scripts/deploy.sh's existing narrow-NOPASSWD sudoers pattern.
#
# Idempotent: re-running creates nothing new and never overwrites an
# operator-populated .env with the blank .env.example template.
#
# Authored on the Mac; runs only on the desktop (uses sudo/useradd).
set -euo pipefail

SSH_HOST="desktop-agent"
SVC_USER="scraper-egress"
COMPOSE_DIR="/opt/docker/scraper-egress"
# The runtime files (compose, .env.example, leak-test.sh) live alongside this
# script in home-infra/compose/desktop/scraper-egress/.
SRC_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "==> Ensuring service user ${SVC_USER} + ${COMPOSE_DIR} on ${SSH_HOST} (nologin, NOT in docker group)"
ssh "${SSH_HOST}" 'sudo bash -s' <<'REMOTE'
set -euo pipefail
id -u scraper-egress >/dev/null 2>&1 || useradd --system --shell /usr/sbin/nologin scraper-egress
mkdir -p /opt/docker/scraper-egress
chown scraper-egress:scraper-egress /opt/docker/scraper-egress
chmod 750 /opt/docker/scraper-egress
echo "service user + directory ready"
REMOTE

echo "==> Installing narrow sudoers grant (docker compose on THIS harness's compose file only -- no docker-group membership)"
ssh "${SSH_HOST}" 'sudo bash -s' <<'REMOTE'
set -euo pipefail
STAGE="$(mktemp)"
cat > "$STAGE" <<'SUDOERS'
scraper-egress ALL=(root) NOPASSWD: /usr/bin/docker compose -f /opt/docker/scraper-egress/docker-compose.yml *
SUDOERS
visudo -cf "$STAGE"
install -o root -g root -m 0440 "$STAGE" /etc/sudoers.d/scraper-egress
rm -f "$STAGE"
echo "sudoers grant installed: /etc/sudoers.d/scraper-egress"
REMOTE

echo "==> Syncing runtime files (compose, .env.example, leak-test.sh) to ${SSH_HOST}:${COMPOSE_DIR}"
# Explicit file list -- only the runtime artifacts, never the live .env, the
# deploy script itself, or the design/ docs.
rsync -az \
  --rsync-path="sudo -u ${SVC_USER} rsync" \
  "${SRC_DIR}/docker-compose.yml" \
  "${SRC_DIR}/.env.example" \
  "${SRC_DIR}/leak-test.sh" \
  "${SSH_HOST}:${COMPOSE_DIR}/"

echo "==> Creating .env from template on ${SSH_HOST} (a re-run NEVER overwrites an already-populated .env)"
ssh "${SSH_HOST}" 'sudo bash -s' <<'REMOTE'
set -euo pipefail
[[ -f /opt/docker/scraper-egress/.env ]] || cp /opt/docker/scraper-egress/.env.example /opt/docker/scraper-egress/.env
chown scraper-egress:scraper-egress /opt/docker/scraper-egress/.env
chmod 600 /opt/docker/scraper-egress/.env
echo ".env present, chmod 600, owned by scraper-egress"
REMOTE

echo "==> Done."
echo "Next: fill in real ProtonVPN credentials ON THE DESKTOP ONLY -- never draft .env on the Mac."
echo "  ssh ${SSH_HOST}"
echo "  sudo -u ${SVC_USER} -e ${COMPOSE_DIR}/.env"
echo "(This script never reads, echoes, or transfers .env contents.)"
