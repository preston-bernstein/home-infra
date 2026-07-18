# Deploy and Rotate: Scraper Egress-Isolation Harness

This doc is the runbook for the scraper-egress harness (owned by `home-infra`, deployed to the desktop). The `deploy.sh` script runs from the Mac `home-infra` checkout and ssh's to `desktop-agent` itself; credential entry and bring-up happen ONLY on the desktop, never on the Mac.

## Deploy

From the Mac `home-infra` checkout (the script ssh's to the desktop on its own):

```bash
cd ~/dev/home-infra/compose/desktop/scraper-egress
./deploy.sh
```

This script:
- Creates the `scraper-egress` nologin service user (idempotent via `id -u ... || useradd`).
- Installs a narrow sudoers grant in `/etc/sudoers.d/scraper-egress` scoped to exactly `docker compose -f /opt/docker/scraper-egress/docker-compose.yml *`. Does **NOT** add the user to the `docker` group — docker-group membership is host-root-equivalent and would defeat the isolation from the Kalshi executor this harness exists to provide.
- Creates `/opt/docker/scraper-egress/` directory.
- Rsyncs `docker-compose.yml` and `.env.example` from the repo, with `--exclude '.env'`.
- Guards the `.env` template copy: `[[ -f .env ]] || cp .env.example .env`. Re-running the script never overwrites an already-populated live `.env`.
- Prints instructions to continue to credential entry (see next section).

## Credential Entry (Desktop Only, Never on the Mac)

After deploy, the script instructs:

```bash
sudo -u scraper-egress -e /opt/docker/scraper-egress/.env
```

This opens the live `.env` file in your default editor (`$EDITOR`, typically `vi`) as the `scraper-egress` user. Fill in:

- **ProtonVPN credentials** (`OPENVPN_USER`, `OPENVPN_PASSWORD`, `OPENVPN_PROTOCOL`, `VPN_TYPE`, `VPN_SERVICE_PROVIDER`): use your existing ProtonVPN account credentials already stored in `/opt/docker/arr-stack/gluetun.env` (or a separate ProtonVPN account if you have one for isolation; see ProtonVPN Account Decision below).
- **`SERVER_COUNTRIES`**: a country code or comma-separated list (e.g., `nl`, `de`, `se`) **distinct** from the value in `/opt/docker/arr-stack/gluetun.env`. The two gluetun containers must exit from different ProtonVPN servers to ensure they never share an IP. Compare the files before saving:
  ```bash
  grep "^SERVER_COUNTRIES=" /opt/docker/arr-stack/gluetun.env
  grep "^SERVER_COUNTRIES=" /opt/docker/scraper-egress/.env  # (empty until you fill it)
  ```

### ProtonVPN Account Decision

Before filling `.env`, confirm the ProtonVPN account (same account as arr-stack, or a separate one) has headroom for a second simultaneous tunnel connection. If using the **same account** (simpler), a scraping-triggered account flag or suspension takes **both** the torrent tunnel (arr-stack) and the scraper tunnel down together. If using a **separate account** (safer but costs a second subscription), the scraper's account can fail independently. Document your choice:

```bash
# Same account or separate?
# Same: OPENVPN_USER/PASSWORD match arr-stack
# Separate: different credentials, different account
```

### Security Hygiene

**NEVER**:
- Draft the live `.env` on the Mac (Time Machine, iCloud sync, and editor swap files all expose plaintext credentials).
- Echo credentials on a command line (`echo "$OPENVPN_PASSWORD"` leaves the value in shell history).
- Commit real `.env` files to git (only `.env.example` is tracked; live `.env` is git-ignored).

## Bring Up

Once credentials are entered (the `scraper-egress` user reaches docker only through its narrow sudoers grant, so bring-up is a double-sudo: run docker compose AS `scraper-egress`, which the grant then allows AS root — this is the isolation working as designed):

```bash
sudo -u scraper-egress sudo /usr/bin/docker compose -f /opt/docker/scraper-egress/docker-compose.yml up -d
```

Wait for the tunnel to come up. Check health:

```bash
docker inspect gluetun-scraper --format '{{.State.Health.Status}}'
```

Should return `healthy` within 30 seconds (gluetun's health check verifies the ProtonVPN tunnel is actually established, not just that the container started).

## Rotation

To rotate ProtonVPN credentials or switch `SERVER_COUNTRIES`:

1. Edit the live `.env`:
   ```bash
   sudo -u scraper-egress -e /opt/docker/scraper-egress/.env
   ```

2. Recreate the gluetun container with the new `.env` (same double-sudo-via-grant as bring-up):
   ```bash
   sudo -u scraper-egress sudo /usr/bin/docker compose -f /opt/docker/scraper-egress/docker-compose.yml up -d --force-recreate egress-gateway
   ```

**Important**: Do NOT use bare `docker compose restart egress-gateway`. A `restart` does not guarantee the container re-reads the rewritten `.env` — you must use `--force-recreate` to force a teardown and fresh launch with the new environment.

## Secret Hygiene Warnings

**NEVER** run these commands against the live stack — both print resolved OpenVPN credentials in plaintext to stdout:

```bash
docker inspect gluetun-scraper                    # BAD: prints all env vars
docker compose config                             # BAD: prints resolved secrets
```

**DO** use `--format` to query only state/health:

```bash
docker inspect gluetun-scraper --format '{{.State.Status}}'
docker inspect gluetun-scraper --format '{{.State.Health.Status}}'
docker port gluetun-scraper                       # OK: shows exposed ports (should be empty)
```

If you accidentally ran an unfiltered `docker inspect` or `docker compose config` and saw credentials printed, assume the value has been exposed and rotate credentials immediately.

## Post-Deploy Verification (Desktop, Linux)

After bring-up, verify the harness is correctly isolated and credentials are secure. Run these commands on the desktop (note: `stat -c` is GNU Linux syntax, not BSD):

### 1. Credential File Permissions

```bash
sudo stat -c %a /opt/docker/scraper-egress/.env
# Should print: 600
```

```bash
sudo stat -c %U /opt/docker/scraper-egress/.env
# Should print: scraper-egress
```

### 2. Service User Isolation

```bash
id scraper-egress
# Output must NOT contain "docker" group
# Example (good): uid=999(scraper-egress) gid=999(scraper-egress) groups=999(scraper-egress)
# Example (bad):  uid=999(scraper-egress) gid=999(scraper-egress) groups=999(scraper-egress),999(docker)
```

Confirm the `scraper-egress` user is distinct from `algo-factory` and media users:

```bash
getent passwd scraper-egress | cut -d: -f3  # UID for scraper-egress
getent passwd algo-factory | cut -d: -f3     # UID for algo-factory (should differ)
```

### 3. Container Network Isolation

```bash
docker port gluetun-scraper
# Should print: (empty, no ports exposed)
```

### 4. Compose Configuration (No Host Networking)

Check the RUNTIME network mode, not the compose text — the compose file's own
comments contain the string "network_mode: host" (documenting that it must NOT
be used), so a naive `grep -c` gives a false positive.

```bash
docker inspect gluetun-scraper --format '{{.HostConfig.NetworkMode}}'
# Should print the container's own bridge network (e.g. scraper-egress_default),
# NOT "host". Anything other than "host" is correct.
```

### 5. Firewall Configuration (No Broad LAN Carve-Out)

```bash
sudo -u scraper-egress grep "^FIREWALL_OUTBOUND_SUBNETS=" /opt/docker/scraper-egress/.env | cut -d= -f2
# Should print: (empty, or a single DNS-resolver /32)
# Should NOT print: 10.0.0.0/24 or any other broad LAN subnet
```

### 6. No Committed Live `.env`

```bash
git ls-files | grep -E '\.env$' | grep -v '\.env\.example$'
# Should print: (empty — no live .env files in git)
```

## Leak-Test Verification

Once the container is healthy, run the leak-test script to verify end-to-end isolation:

The leak-test is deployed alongside the stack (`deploy.sh` rsyncs it to `/opt/docker/scraper-egress/leak-test.sh`). It needs broad `docker` access (exec/inspect), so run it as root, not as `scraper-egress`:

```bash
ssh desktop-agent "sudo COMPOSE_DIR=/opt/docker/scraper-egress bash /opt/docker/scraper-egress/leak-test.sh"
```

Expected output (four PASS assertions):

```
PASS ip-exit
PASS dns-path
PASS exit-isolation
PASS fail-closed
RESULT: 4/4 passed
```

Script exits 0 on all PASS; exits 1 if any assertion fails. If any assertion fails, review the scraper egress container logs (`docker logs gluetun-scraper`) and arr-stack gluetun logs (`docker logs gluetun-arr-stack`) for clues, then re-check credential entry and `SERVER_COUNTRIES` divergence.

## Troubleshooting

- **Container exits immediately** (`docker inspect gluetun-scraper --format '{{.State.Status}}'` returns `exited`): Check logs: `sudo -u scraper-egress docker compose logs egress-gateway | tail -50`. Common causes: invalid ProtonVPN credentials, missing `FIREWALL_OUTBOUND_SUBNETS` value, or typo in env vars.
- **Health check fails** (`docker inspect ... Health.Status` stays `starting` for >60s or returns `unhealthy`): The ProtonVPN tunnel is not establishing. Check: (1) account credentials are correct, (2) account has simultaneous-connection headroom (if same account as arr-stack), (3) `SERVER_COUNTRIES` code is valid for the account's subscription.
- **Leak-test fails** (assertions report FAIL): The most common cause is `SERVER_COUNTRIES` not differing from arr-stack. Re-check and edit `.env`, then rotate as described above. If rotation doesn't help, check that arr-stack's gluetun (`gluetun-arr-stack` container) is also healthy and has a stable exit IP.

## Summary

- **Deploy**: `./deploy.sh` from the Mac home-infra checkout.
- **Credentials**: `sudo -u scraper-egress -e /opt/docker/scraper-egress/.env` (desktop only, never on Mac).
- **Bring up**: `docker compose up -d` in `/opt/docker/scraper-egress/`.
- **Rotation**: Edit `.env`, then `docker compose up -d --force-recreate egress-gateway` (NOT bare restart).
- **Secrets**: Never bare `docker inspect` or `docker compose config` (both leak credentials); use `--format` queries only.
- **Post-deploy**: Run `stat`, `id`, and `docker port` verifications listed above to confirm isolation.
