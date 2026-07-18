# Steps: Scraper Egress-Isolation Harness

## Prerequisites

ProtonVPN account and credentials already exist (used by arr-stack; see `/opt/docker/arr-stack/gluetun.env` for reference). Desktop Docker daemon present and running (arr-stack containers already use it). Both Mac (this repo checkout) and desktop `ssh desktop-agent` accessible.

## Implementation steps

### Step 1: Create docker-compose.yml
**What**: [authoring] Author `deploy/scraper-egress/docker-compose.yml` with gluetun service definition, isolated container name, firewall-enabled config, and health check.

**Files**: `deploy/scraper-egress/docker-compose.yml`

**Test**: `docker compose -f deploy/scraper-egress/docker-compose.yml config` (from Mac, with `.env.example` values substituted) produces valid YAML with service key `egress-gateway`, container name `gluetun-scraper`, `cap_add: NET_ADMIN`, `devices: ["/dev/net/tun"]`, `FIREWALL: "on"`, `env_file: [.env]`, default-bridge networking (NOT `network_mode: host`), NO `ports:` block (control server unpublished), and health check via `HEALTH_TARGET_ADDRESS`. `FIREWALL_OUTBOUND_SUBNETS` sources from `.env` (narrowed to a DNS-resolver /32 or empty per the hardened spec, NOT the full 10.0.0.0/24 LAN).

**Depends on**: none

**Parallelizable**: Yes

### Step 2: Create .env.example and update .gitignore
**What**: [authoring] Author `deploy/scraper-egress/.env.example` with all placeholder environment variables for gluetun, non-secret defaults committed as real values (firewall, subnet), and security warning on `FIREWALL_ENABLED_DISABLING_IT_SHOOTS_YOU_IN_YOUR_FOOT`. Also add one-line comment to `.gitignore` near the secrets block noting that `deploy/scraper-egress/.env` is covered by existing `.env` / `.env.*` patterns.

**Files**: `deploy/scraper-egress/.env.example`, `.gitignore`

**Test**: `.env.example` contains all required gluetun vars (`VPN_SERVICE_PROVIDER`, `VPN_TYPE`, `OPENVPN_USER`, `OPENVPN_PASSWORD`, `OPENVPN_PROTOCOL`, `SERVER_COUNTRIES`, `FIREWALL=on`, `FIREWALL_OUTBOUND_SUBNETS` (empty or a single DNS `/32` — NOT `10.0.0.0/24`), `DNS_KEEP_NAMESERVER=off`, `DNS_ADDRESS`, `DNS_SERVER`, `VPN_PORT_FORWARDING=off`, `HEALTH_TARGET_ADDRESS`, `PUID`, `PGID`, `TZ`); non-secret fail-closed defaults (`FIREWALL=on`, `DNS_KEEP_NAMESERVER=off`, `VPN_PORT_FORWARDING=off`) committed as real values, secret fields empty, `FIREWALL_OUTBOUND_SUBNETS` empty-or-DNS-only. `.gitignore` comment present; `git check-ignore deploy/scraper-egress/.env` confirms pattern match (exit 0).

**Depends on**: none

**Parallelizable**: Yes

### Step 3: Create deploy_scraper_egress.sh
**What**: [authoring] Author `scripts/deploy_scraper_egress.sh` to idempotently create `scraper-egress` service user (nologin), install a NARROW `/etc/sudoers.d/scraper-egress` grant scoped to exactly `docker compose -f /opt/docker/scraper-egress/docker-compose.yml *` (mirroring `scripts/deploy.sh`'s narrow-NOPASSWD pattern — do NOT add the user to the `docker` group, which is host-root-equivalent), create `/opt/docker/scraper-egress/`, rsync compose files with `--exclude '.env'`, guard the `.env` template copy with `[[ -f live.env ]] || cp .env.example .env` so a re-run never clobbers operator creds, and instruct operator to edit `.env` in place.

**Files**: `scripts/deploy_scraper_egress.sh`

**Test**: `shellcheck scripts/deploy_scraper_egress.sh` passes; dry-run review confirms script creates user (guarded by `id -u`), installs the narrow sudoers grant (and does NOT run `usermod -aG docker`), validates it with `visudo -cf`, creates directory, rsyncs with exclude filter, guards the `.env` copy against clobber, and prints `sudo -u scraper-egress -e` edit instruction (never echoes credentials).

**Depends on**: none

**Parallelizable**: Yes

### Step 4a: Author leak-test IP-exit and DNS-path assertions
**What**: [authoring] Author the first two assertions in `scripts/leak_test_scraper_egress.sh`: (1) IP-exit isolation — verify scraper exit IP ≠ desktop WAN IP AND ≠ arr-stack gluetun exit IP; (2) DNS-path isolation — verify DNS query goes through tunnel resolver (not ISP). Output `PASS` or `FAIL` per assertion.

**Files**: `scripts/leak_test_scraper_egress.sh` (partial; assertions 1–2)

**Test**: `shellcheck scripts/leak_test_scraper_egress.sh` passes; code review confirms ip-exit block queries both `gluetun-scraper` container IP and compares against arr-stack gluetun's exit IP (via `docker exec gluetun-arr-stack` or `/opt/docker/arr-stack/.env`); dns-path block queries resolver inside gluetun-scraper and verifies response differs from ISP resolver.

**Depends on**: none

**Parallelizable**: Yes

### Step 4b: Author leak-test fail-closed assertion with trap handler
**What**: [authoring] Author the third assertion in `scripts/leak_test_scraper_egress.sh`: fail-closed isolation — kill tunnel process (with protocol-aware branching on `VPN_TYPE`: OPENVPN process kill via `pgrep`, WireGuard interface down via `wg`), verify kill landed (pgrep/wg show), attempt egress via host IP, confirm it fails, then restore tunnel via trap on ANY exit (ERR/EXIT). Output final `RESULT: <n>/4 passed` (four assertions total), exit 0 iff all pass. Hardening: trap must restore tunnel even on abort/interrupt.

**Files**: `scripts/leak_test_scraper_egress.sh` (partial; assertion 3 + trap handler)

**Test**: `shellcheck scripts/leak_test_scraper_egress.sh` passes; dry-run trace confirms protocol-aware kill (grep for `VPN_TYPE` branch), verification (pgrep/wg show call), restore trap (grep for `trap .* EXIT ERR`), and `RESULT: 4/4 passed` output line. Script handles both OPENVPN and WIREGUARD without hardcoding.

**Depends on**: Step 4a

**Parallelizable**: No

### Step 5: Create consumer-contract.md
**What**: [authoring] Author `docs/scraper-egress-harness/consumer-contract.md` documenting how future scraper containers attach via `network_mode: service:egress-gateway` without hardcoding ProtonVPN-specific vars, plus backend-swap guarantee and out-of-scope reiteration.

**Files**: `docs/scraper-egress-harness/consumer-contract.md`

**Test**: Document contains consumer YAML example with `network_mode: "service:egress-gateway"` and `depends_on`, explicit statement that no `PROTON_*` or `SERVER_COUNTRIES` vars appear in consumer definition, backend-swap example (swapping gluetun for residential proxy requires no consumer changes), and explicit restatement of out-of-scope items (scraper implementations, stealth browser, cease-and-desist halt rail, rate governor, residential-proxy backend).

**Depends on**: none

**Parallelizable**: Yes

### Step 6: Create deploy-and-rotate.md
**What**: [authoring] Author `docs/scraper-egress-harness/deploy-and-rotate.md` documenting live .env location, required `chmod 600`/ownership, credential rotation procedure, and post-deploy verification commands.

**Files**: `docs/scraper-egress-harness/deploy-and-rotate.md`

**Test**: Document specifies live `.env` location (`/opt/docker/scraper-egress/.env`), required ownership (`scraper-egress` user), required permissions (`chmod 600`), rotation steps (`sudo -u scraper-egress -e .env` then `docker compose up -d --force-recreate egress-gateway` — NOT bare `restart`, so a rewritten `.env` is re-read), an explicit warning to NEVER run bare `docker inspect <container>` or `docker compose config` against the live stack (both print resolved OPENVPN creds in cleartext) and NEVER draft the live `.env` on the Mac, and verification commands (`stat`, `id`, `getent passwd`, `git ls-files` filter) to run on desktop after deploy to confirm the credential/isolation ACs.

**Depends on**: none

**Parallelizable**: Yes

### Step 7: Harden scripts/check_clean.sh for nested .env detection
**What**: [authoring] Harden `scripts/check_clean.sh` to detect and reject nested `.env` files anywhere in the repo (not just root), specifically in `deploy/scraper-egress/.env`. Add explicit check: if any `.env` files exist in deployment directories (not `.env.example`), exit with ERROR.

**Files**: `scripts/check_clean.sh`

**Test**: Add a dummy `deploy/scraper-egress/.env` with fake credentials (e.g., `OPENVPN_PASSWORD=fake123`), run `scripts/check_clean.sh`, confirm it fails with ERROR message mentioning the nested `.env`. Then remove the dummy file and confirm the script passes again (exit 0).

**Depends on**: Steps 1–6 (all authoring files present)

**Parallelizable**: No

### Step 8: Verify scripts/check_clean.sh passes (Mac)
**What**: [authoring] Run `scripts/check_clean.sh` from the Mac checkout after all authoring steps (1–7) are complete to verify the new harness files do not trigger secret-detection patterns and the gate passes with status 0 (required before push per AC8).

**Files**: `scripts/check_clean.sh`

**Test**: `scripts/check_clean.sh` runs to completion and exits 0; output contains no ERROR or FAIL messages related to `deploy/scraper-egress/` files (secret patterns must not fire on `.env.example` placeholder content or any committed `.env*` files). If the script passes, the harness files are safe to push to the public repo.

**Depends on**: Steps 1–7 (authoring complete, check_clean.sh hardened)

**Parallelizable**: No

### Step 9: Commit, push, and sync harness to desktop
**What**: [authoring→desktop bridge] Commit all harness files on the Mac (`git add deploy/scripts/docs`), push to origin/main, then `ssh desktop-agent 'cd /home/algo-factory/src/algo-factory && git pull'` to sync the desktop checkout. Verify that `deploy/scraper-egress/` directory, `scripts/deploy_scraper_egress.sh`, and `scripts/leak_test_scraper_egress.sh` all exist on the desktop afterward.

**Files**: (authoring commit, desktop git state)

**Test**: `git status` on Mac shows no modified harness files; desktop `ssh desktop-agent 'ls -la /home/algo-factory/src/algo-factory/deploy/scraper-egress/'` returns `docker-compose.yml`, `.env.example`; `ssh desktop-agent 'ls -la /home/algo-factory/src/algo-factory/scripts/ | grep -E "(deploy_scraper_egress|leak_test_scraper_egress)'` returns both scripts. Exit 0 if all files present.

**Depends on**: Step 8 (check_clean.sh verification complete; safe to commit)

**Parallelizable**: No

### Step 10: Deploy service user and directory structure
**What**: [desktop] Run `ssh desktop-agent 'cd /home/algo-factory/src/algo-factory && bash scripts/deploy_scraper_egress.sh'` to create `scraper-egress` nologin service user, install the narrow sudoers grant (NOT docker-group membership), create `/opt/docker/scraper-egress/`, rsync `docker-compose.yml` and `.env.example`, and auto-create `.env` template (guarded against clobber). Operator receives printed instruction to edit `.env` with real credentials next.

**Files**: (deployment artifact — creates `/opt/docker/scraper-egress/docker-compose.yml`, `/opt/docker/scraper-egress/.env.example`, `/opt/docker/scraper-egress/.env` template, and `scraper-egress` user)

**Test**: `ssh desktop-agent 'id scraper-egress'` succeeds; `ssh desktop-agent 'ls -la /opt/docker/scraper-egress/'` shows `docker-compose.yml`, `.env.example`, `.env`; run deploy script TWICE and confirm second run succeeds with no user-already-exists error or .env overwrite (file timestamp unchanged).

**Depends on**: Step 9 (harness synced to desktop)

**Parallelizable**: No

### Step 11: Operator configures credentials
**What**: [desktop] Operator manually runs `ssh desktop-agent 'sudo -u scraper-egress -e /opt/docker/scraper-egress/.env'` (as instructed by step 10 output) and fills in real ProtonVPN credentials and `SERVER_COUNTRIES` value distinct from arr-stack's `gluetun.env`.

**Files**: `/opt/docker/scraper-egress/.env` (live, not committed)

**Test**: `ssh desktop-agent 'sudo -u scraper-egress grep "^SERVER_COUNTRIES=" /opt/docker/scraper-egress/.env | cut -d= -f2'` returns a non-empty value; operator visually confirms it differs from `ssh desktop-agent 'grep "^SERVER_COUNTRIES=" /opt/docker/arr-stack/gluetun.env | cut -d= -f2'` (e.g., one uses `nl`, other uses `de`, per AC2).

**Depends on**: Step 10

**Parallelizable**: No

### Step 12: Bring up egress-gateway container and verify health
**What**: [desktop] Run `ssh desktop-agent 'cd /opt/docker/scraper-egress && sudo -u scraper-egress docker compose up -d'` to start the gluetun service, wait for health check to pass, and confirm container is running without errors.

**Files**: (runtime state — container `gluetun-scraper` running)

**Test**: `ssh desktop-agent 'docker inspect gluetun-scraper --format {{.State.Status}}'` returns `running`; `ssh desktop-agent 'docker inspect gluetun-scraper --format {{.State.Health.Status}}'` returns `healthy` (within 30s); `ssh desktop-agent 'docker logs gluetun-scraper | head -20'` shows no error messages (tunnel initialization succeeds).

**Depends on**: Step 11

**Parallelizable**: No

### Step 13: Run leak-test script with all four assertions
**What**: [desktop] Run `ssh desktop-agent 'sudo -u scraper-egress scripts/leak_test_scraper_egress.sh'` to verify: (1) scraper exit IP ≠ desktop WAN IP, (2) scraper exit IP ≠ arr-stack gluetun exit IP, (3) DNS-path isolation (query goes through tunnel resolver, not ISP), (4) fail-closed guarantee (tunnel down = no egress via host IP). Trap ensures tunnel is restored on exit.

**Files**: (test output — script produces PASS/FAIL assertions)

**Test**: Script output contains four assertion lines: `PASS ip-exit-vs-desktop`, `PASS ip-exit-vs-arrstack`, `PASS dns-path`, `PASS fail-closed`, followed by one summary line `RESULT: 4/4 passed` (five lines total). Script exits 0 if all pass, exits 1 if any fail. Verify gluetun-scraper is healthy again after test completes: `docker inspect gluetun-scraper --format {{.State.Health.Status}}` returns `healthy`.

**Depends on**: Step 12

**Parallelizable**: No

### Step 14: Verify post-deploy isolation properties and credential security
**What**: [desktop] Verify credential file permissions (600, scraper-egress owner), no plaintext VPN credentials in logs/output, service user isolation, docker group separation, and firewall configuration correctness (FIREWALL_OUTBOUND_SUBNETS not broad, no published control ports, compose not network_mode: host).

**Files**: `/opt/docker/scraper-egress/.env`, `/opt/docker/scraper-egress/docker-compose.yml`, service user records, docker inspect output

**Test** (desktop is Linux — use GNU `stat -c`, not BSD `stat -f`): (1) Permissions: `ssh desktop-agent 'sudo stat -c %a /opt/docker/scraper-egress/.env'` returns `600`; `ssh desktop-agent 'sudo stat -c %U /opt/docker/scraper-egress/.env'` returns `scraper-egress`. (2) User isolation: `ssh desktop-agent 'getent passwd scraper-egress | cut -d: -f3'` UID distinct from algo-factory and media users. (3) Group separation: `ssh desktop-agent 'id scraper-egress'` output does NOT contain `docker` group (scraper-egress uses the narrow sudoers grant, never docker-group membership). (4) No credential leaks (absolute paths, do NOT swallow stderr): `ssh desktop-agent 'sudo -u scraper-egress grep OPENVPN_PASSWORD /opt/docker/scraper-egress/.env'` shows the value is present but the file is `chmod 600` owner-only; `ssh desktop-agent 'docker logs gluetun-scraper 2>&1 | grep -i password'` returns empty. (5) Firewall config: `ssh desktop-agent 'sudo -u scraper-egress grep FIREWALL_OUTBOUND_SUBNETS /opt/docker/scraper-egress/.env | cut -d= -f2'` is empty or a single `/32` DNS host — NOT a broad LAN range (10.0.0.0/24 or wider). (6) No published control port: `ssh desktop-agent 'docker port gluetun-scraper'` returns empty. (7) Compose not host network: `ssh desktop-agent 'grep -c "network_mode: host" /opt/docker/scraper-egress/docker-compose.yml'` returns 0.

**Depends on**: Step 13

**Parallelizable**: No

## Rollback plan

**Authoring steps (1–8, Mac):** All reversible via `git checkout -- .` or individual file deletion; nothing committed yet.

**Step 9 (commit/push/pull):** Revert via `git revert` on Mac, then `git pull` on desktop to sync the rollback.

**Desktop steps (10–14):**
- Fail-closed test abort: The trap handler in Step 4b/13 automatically restores the tunnel on EXIT/ERR, even if the test is interrupted mid-run (e.g., Ctrl+C). Verify tunnel restored: `docker inspect gluetun-scraper --format {{.State.Health.Status}}` should return `healthy`.
- Containers: `ssh desktop-agent 'cd /opt/docker/scraper-egress && sudo -u scraper-egress docker compose down'` removes running container.
- Service user: `ssh desktop-agent 'sudo userdel scraper-egress'` (idempotent; no-op if user does not exist).
- Docker group removal: `ssh desktop-agent 'sudo gpasswd -d scraper-egress docker'` (idempotent; no-op if scraper-egress not in group).
- Sudoers cleanup (if Step 10 added any): `ssh desktop-agent 'sudo visudo -c'` to verify no orphaned entries.
- Directory: `ssh desktop-agent 'sudo rm -rf /opt/docker/scraper-egress'` removes all deployment artifacts.
- Verify rollback: `ssh desktop-agent 'id scraper-egress'` should return "no such user"; `ssh desktop-agent 'docker ps | grep gluetun-scraper'` should return empty.

All steps are independently reversible with no side effects on the Kalshi executor, financial pipeline, or arr-stack infrastructure.
