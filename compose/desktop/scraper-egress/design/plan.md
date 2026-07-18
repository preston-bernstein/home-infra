# Plan: Scraper Egress-Isolation Harness

## Approach
Stand up a second, fully independent `qmcgaw/gluetun` + ProtonVPN container that mirrors the proven `/opt/docker/arr-stack` pattern byte-for-byte in structure (image, `NET_ADMIN`, `/dev/net/tun`, `env_file`-sourced creds, `FIREWALL=on`, `FIREWALL_OUTBOUND_SUBNETS`) but with its own container/service identity, its own ProtonVPN exit config, and its own dedicated `nologin` service user, so a scraper's egress can never share a network namespace, IP, or Linux user with the Kalshi executor / financial pipeline. The compose stack lives in a new `deploy/scraper-egress/` subtree (the repo's first non-Python, non-systemd artifact), ships only a placeholder `.env.example`, and is deployed and verified exclusively on the desktop via a dedicated bash deploy script and a bash leak-test script that asserts exit IP, DNS path, exit-IP isolation from arr-stack, and fail-closed behavior as four independent PASS/FAIL checks. No scraper logic is built here — this is the tunnel and its proof of isolation only.

## Design decisions

- **Docker group vs. scoped sudoers grant.** Do NOT add `scraper-egress` to the host `docker` group. Docker group membership is root-equivalent (a member can mount the host filesystem, escape containers, read any file as root via a bind mount) on the same host that runs the Kalshi executor and `live.db` — granting it here would defeat the entire point of a separate `nologin` service user. Instead, `scripts/deploy_scraper_egress.sh` installs a `/etc/sudoers.d/scraper-egress` drop-in scoped to exactly `scraper-egress ALL=(root) NOPASSWD: /usr/bin/docker compose -f /opt/docker/scraper-egress/docker-compose.yml *`, mirroring the narrow-NOPASSWD pattern `scripts/deploy.sh` already uses elsewhere in this repo. Reversibility: painful once tooling assumes group membership — every future consumer script would need parallel sudoers entries or a full docker-group audit to walk back. Decide now, not after the first deploy.

- **`FIREWALL_OUTBOUND_SUBNETS` scope.** Narrow from `10.0.0.0/24` (the whole LAN) to the minimum the tunnel actually needs to reach outside itself — a single `/32` for the LAN DNS resolver if the gluetun tunnel does not serve DNS internally, or empty/unset if `DNS_ADDRESS` inside the tunnel already handles resolution. The `/24` carve-out is a direct lateral path from a scraper's compromised or misbehaving egress container to finpipe Postgres (`10.0.0.250:5432`), the NAS, and the desktop's own LAN IP, all of which live on that subnet. This ships as the real default in `.env.example`, not a placeholder — getting it wrong silently reopens the exact lateral-movement risk this harness exists to close.

- **Residential-proxy swap claim, scoped honestly.** `network_mode: service:` is a VPN-tunnel-shaped primitive — it works because gluetun presents a network namespace to share. A residential proxy is a different shape: consumed via `HTTP_PROXY`/SOCKS env vars, or via a transparent-redirect sidecar (Redsocks/Privoxy + iptables `REDIRECT`), never namespace-sharing. FR6's contract language in this plan is corrected to claim only "VPN-backend-swappable" (ProtonVPN ↔ Mullvad, OpenVPN ↔ WireGuard) as a true drop-in; a future residential-proxy backend is documented as needing its own transparent-proxy shim, not a same-shape swap.

- **ProtonVPN concurrent-connection headroom.** Confirm the ProtonVPN account has simultaneous-connection headroom for a second tunnel before bring-up, alongside arr-stack's existing gluetun tunnel. Two options exist: run the scraper egress tunnel on the *same* ProtonVPN account as arr-stack (simpler, but a scraping-triggered account flag or suspension takes the torrent tunnel down too), or a *separate* account (isolates that failure mode, costs a second subscription). This plan does not pick one — it records the tradeoff so it's decided deliberately at deploy time, not rediscovered under incident pressure.

- **Repo visibility does not relax secret hygiene.** The repo has been PRIVATE since 2026-07-03 (per `scripts/check_clean.sh`'s header), not public — any earlier "public repo" framing in this feature's docs was wrong and is corrected below. This does not loosen anything: `.env` git-ignore, `chmod 600`, no credentials in logs/CLI output/inspect dumps, and the `check_clean.sh` hardening below all stand as written. Private-repo status is a control that can silently flip (collaborator added, repo re-forked, GitHub App misconfigured) and must never be the only thing standing between a committed credential and exposure.

## Architecture
```
                      Mac (this repo, dev/edit only)
                      deploy/scraper-egress/{docker-compose.yml,.env.example}
                      scripts/{deploy_scraper_egress.sh,leak_test_scraper_egress.sh}
                                        |
                                        |  rsync (code only, no secrets)
                                        v
 ================================ desktop ==================================
                                                                             
  service user: algo-factory          service user: scraper-egress (NEW,   
  (existing, unrelated)                nologin, distinct from media user,  
                                        NOT in docker group — narrow        
                                        sudoers.d grant instead)            
                                                                             
  Kalshi executor / financial          /opt/docker/scraper-egress/         
  pipeline containers/procs   <--X-->    docker-compose.yml (deployed copy)
  (real WAN IP, own network             .env  (live creds, chmod 600,      
   namespace — NEVER touched)            owned by scraper-egress, NOT      
                                          in any git checkout)              
                                                                             
                                        docker service: egress-gateway     
                                        container_name: gluetun-scraper    
                                        image: qmcgaw/gluetun               
                                        cap_add: NET_ADMIN                  
                                        network_mode: bridge (default;      
                                          NEVER host)                       
                                        no `ports:` block — control server  
                                          reachable via netns/exec only     
                                        FIREWALL=on                         
                                        FIREWALL_OUTBOUND_SUBNETS=<DNS      
                                          host>/32, or unset (NOT the       
                                          LAN /24 — see Design decisions)   
                                        mem_limit / cpus set (shared host   
                                          with live-order processes)        
                                              |                             
                                              | ProtonVPN tunnel (distinct  
                                              | SERVER_COUNTRIES from       
                                              | arr-stack's gluetun)        
                                              v                             
                                        Internet (throwaway VPN exit IP)   
                                                                             
                                        future consumers attach via:       
                                        network_mode: service:egress-gateway
                                        depends_on: [egress-gateway]        
                                        (not yet built — out of scope)      
 =============================================================================
                                        arr-stack gluetun (existing, torrent
                                        stack) — untouched, separate exit IP,
                                        separate container, no relationship
                                        to egress-gateway above. Its control
                                        server is queried read-only (localhost/
                                        netns) by the leak-test's isolation
                                        check — never exposed on a published
                                        port.
 =============================================================================
```
Key isolation properties: two gluetun containers, two ProtonVPN exit configs, two Linux service users, two `/opt/docker/*` directories, zero shared `network_mode` with anything Kalshi/finpipe-related, and no shared host-level Docker privilege (no `docker` group membership for `scraper-egress`). The `egress-gateway` compose **service key** (not the container name) is the stable contract consumers code against — swapping VPN backends (ProtonVPN ↔ Mullvad, OpenVPN ↔ WireGuard) only changes what's inside the `egress-gateway` service definition, never the consumer's `network_mode: service:egress-gateway` line. A future residential-proxy backend is a different shape (HTTP_PROXY/SOCKS, or a transparent-redirect shim) and is **not** claimed as a drop-in swap — see Design decisions.

## Data model
No data model changes. This is infrastructure only — no new tables, schemas, or persisted application state. (Gluetun's own runtime state file under `/opt/docker/scraper-egress/gluetun/` is opaque container state, not an algo-factory data model concern, and is desktop-local, never synced or committed.)

## API / interface contract

**1. Consumer attachment contract** (how a future scraper attaches — documented in `docs/scraper-egress-harness/consumer-contract.md`, separate from the gluetun backend implementation per FR5/FR6):
```yaml
# A future scraper service, in its OWN compose file or appended to
# deploy/scraper-egress/docker-compose.yml under a separate `profiles:` entry —
# out of scope to build now, this is the documented shape only.
services:
  reddit-scraper:            # example future consumer, NOT built by this feature
    image: some/scraper-image
    network_mode: "service:egress-gateway"
    depends_on:
      egress-gateway:
        condition: service_healthy
    mem_limit: <set by consumer>   # required of every future consumer, not optional —
    cpus: <set by consumer>        # this box also runs live orders (see Risk areas)
    # NOTE: no VPN_*, PROTON_*, or SERVER_COUNTRIES vars appear here —
    # the consumer never references ProtonVPN-specific config directly,
    # satisfying the VPN-backend-swap requirement (FR6). A residential-proxy
    # backend is explicitly NOT covered by this same shape — see Design decisions.
```
The contract is exactly two lines (`network_mode` + `depends_on`) plus a health-gate condition, plus a resource-limit requirement carried forward from this harness's own gluetun service. `service_healthy` only fires once gluetun's healthcheck confirms the tunnel is actually up (via `HEALTH_TARGET_ADDRESS`, an external ping through the tunnel) — not merely that the container process started. Nothing ProtonVPN-specific crosses into consumer service definitions.

**2. Leak-test script CLI/exit-code contract** (`scripts/leak_test_scraper_egress.sh`, desktop-only):
- Invocation: `sudo -u scraper-egress scripts/leak_test_scraper_egress.sh` (no args; reads the compose project path from a `COMPOSE_DIR` env var defaulting to `/opt/docker/scraper-egress`, and reads `VPN_TYPE` from the deployed `.env` at that path to select protocol-aware behavior below).
- Runs four assertions in order, each printing exactly one line in the form `PASS <check-name>` or `FAIL <check-name>` to stdout:
  - `PASS ip-exit` / `FAIL ip-exit` — the scraper tunnel's public IP, resolved via a named external IP-echo endpoint AND cross-checked against gluetun's own control-server `/v1/publicip/ip` (queried over localhost/netns, never a published port) as a second source of truth. Mismatch or unreachable-both fails the check.
  - `PASS dns-path` / `FAIL dns-path` — verifies the *actual resolution path* a lookup takes from inside the tunnel netns (e.g. a probe query against a canary domain, confirmed via the tunnel's own resolver, not just a static read of `resolv.conf`), consistent with `DNS_KEEP_NAMESERVER=off` in the env (below) so gluetun's own DNS-over-TLS resolver is what actually answers.
  - `PASS exit-isolation` / `FAIL exit-isolation` — the scraper's exit IP (from the `ip-exit` check above) must differ from arr-stack gluetun's *current* exit IP, queried from arr-stack gluetun's control server the same way (localhost/netns only). Runs every invocation, not just at first bring-up, since either tunnel's exit IP can change on reconnect.
  - `PASS fail-closed` / `FAIL fail-closed` — protocol-aware: branches on `VPN_TYPE`. In OpenVPN mode, kills the `openvpn` process inside `gluetun-scraper` (`pkill -TERM openvpn`). In WireGuard mode there is **no** `openvpn` process to kill — kernelspace WireGuard is a netlink-managed interface, userspace mode runs `wireguard-go` as gluetun's PID 1 supervisee — so the check instead tears down the WireGuard interface directly (interface delete / `wg-quick down` equivalent inside the container, per gluetun's actual WireGuard teardown path). Either way, the script **verifies the kill actually landed** before trusting any probe result — `pgrep openvpn` returning empty, or `wg show`/interface-state confirming the interface is gone — and `FAIL`s immediately if the tunnel is still up after the kill attempt (a no-op kill must never produce a silent PASS). Once teardown is confirmed, the script polls continuously (sub-second interval, not one bounded `curl -m 5`) across the down→reconnect window, since gluetun's `FIREWALL=on` iptables kill-switch **persists across reconnects** (it is not torn down and rebuilt) — the real risk being tested is a kill that never happened, not a race against the firewall rules disappearing. Any successful egress observed during the down window before the tunnel reports healthy again is a `FAIL`.
- Final line: `RESULT: <n>/4 passed`.
- Exit code: `0` iff all four assertions pass; otherwise exits `1` (non-zero, per FR10/AC6). Never partial-credit exit codes — callers (operator, future CI-on-desktop) only need zero-vs-nonzero.
- Restore-to-healthy is a `trap ... EXIT ERR` handler installed at the top of the script, not a happy-path final line — it fires on **any** exit path, including an SSH drop or Ctrl-C mid-test, and brings `egress-gateway` back to a verified-healthy state before the script's process actually exits.
- Never prints `.env` contents, never runs an unfiltered `docker logs egress-gateway`, never runs bare `docker inspect` or `docker compose config` against the live stack (both print resolved OpenVPN credentials in cleartext); only structured `docker inspect --format` health/state queries and probe-container stdout (IP addresses and DNS resolver addresses are not credentials and are safe to print).

**3. Env-file interface** (`deploy/scraper-egress/.env.example`, tracked; live values only in `deploy/scraper-egress/.env`, git-ignored, and its deployed copy `/opt/docker/scraper-egress/.env` on the desktop):
```
VPN_SERVICE_PROVIDER=
VPN_TYPE=
OPENVPN_USER=
OPENVPN_PASSWORD=
OPENVPN_PROTOCOL=
SERVER_COUNTRIES=
FIREWALL=on
FIREWALL_OUTBOUND_SUBNETS=
DNS_KEEP_NAMESERVER=off
FIREWALL_ENABLED_DISABLING_IT_SHOOTS_YOU_IN_YOUR_FOOT=
DNS_ADDRESS=
DNS_SERVER=
VPN_PORT_FORWARDING=off
HEALTH_TARGET_ADDRESS=
PUID=
PGID=
TZ=
```
Every var is present with an empty or safe-default placeholder. `FIREWALL=on` and `DNS_KEEP_NAMESERVER=off` are committed as literal fail-closed defaults since they are not secrets — `DNS_KEEP_NAMESERVER=off` ensures gluetun's own in-tunnel DNS resolver is authoritative (rather than leaking the host's `resolv.conf` nameserver into the tunnel netns), which the `dns-path` leak-test assertion depends on. `FIREWALL_OUTBOUND_SUBNETS` is deliberately left for the operator to fill with the narrowest possible value (a single DNS-host `/32`, or left empty if the tunnel serves its own DNS) — **not** `10.0.0.0/24` — per Design decisions; the deploy doc calls out why the LAN-wide subnet is a lateral-movement risk to finpipe Postgres, the NAS, and the desktop's own LAN IP. `FIREWALL_ENABLED_DISABLING_IT_SHOOTS_YOU_IN_YOUR_FOOT` is left blank/unset by convention — its own name is gluetun's built-in warning that setting it disables the kill-switch this whole feature exists to provide; `docs/scraper-egress-harness/consumer-contract.md` calls this out explicitly. `SERVER_COUNTRIES` must be filled by the operator with a value distinct from arr-stack's `gluetun.env` (AC2) — the deploy doc instructs comparing the two files on the desktop before first bring-up. Gluetun's control server (used by the `ip-exit` and `exit-isolation` leak-test checks) is enabled via env var but never exposed through a compose `ports:` block — see Integration points.

## Integration points
- `deploy/scraper-egress/docker-compose.yml` — new. Second gluetun stack, service key `egress-gateway`, `container_name: gluetun-scraper`, `cap_add: [NET_ADMIN]`, `devices: ["/dev/net/tun:/dev/net/tun"]`, `env_file: [.env]`, `volumes: ["./gluetun:/gluetun"]`, `restart: unless-stopped`, healthcheck via gluetun's own `HEALTH_TARGET_ADDRESS` (an external ping through the live tunnel, so `service_healthy` genuinely gates on tunnel-up, not just process-up — this is what future consumers' `depends_on: condition: service_healthy` relies on). Default bridge networking only — **never** `network_mode: host`; a config check asserts this at deploy time, since a host-networking gluetun would let its `FIREWALL=on` iptables rules apply to the host netns itself, which could firewall off the Kalshi executor. No `ports:` block for the control server (localhost/netns/`docker exec` access only — see deploy verification below). `mem_limit`/`cpus` (or `deploy.resources.limits`) set conservatively, since this host also runs live orders. **Before authoring this file, read the real `/opt/docker/arr-stack/docker-compose.yml` on the desktop — do not blind-`cp` it.** Copying a host-networking or custom-`ports:` config from arr-stack without adapting it would be catastrophic for the reasons above. Lives outside `src/` and `scripts/` because it's a Docker artifact, not Python — a new top-level `deploy/` directory parallels the existing top-level `systemd/` directory (deploy-time infra, not app code) without touching `systemd/`'s contents or conventions.
- `deploy/scraper-egress/.env.example` — new, tracked. Exact name `.env.example` (not a variant) so it lands directly on the existing `!.env.example` gitignore exception with zero pattern changes needed. Every var name from the grounding list, secrets blank; fail-closed defaults (`FIREWALL=on`, `DNS_KEEP_NAMESERVER=off`) committed as real values, `FIREWALL_OUTBOUND_SUBNETS` deliberately left for the operator to fill narrowly (not the LAN `/24` — see Design decisions and the env-file interface above).
- `deploy/scraper-egress/.env` — new path, never committed. Matches the existing unanchored `.env` gitignore pattern (git's basename-style matching for slash-free patterns already covers this at any depth — verified no new `.gitignore` pattern is required). Exists only transiently on the Mac if an operator drafts it there before transfer, and canonically at `/opt/docker/scraper-egress/.env` on the desktop, `chmod 600`, owned by `scraper-egress`. Live ProtonVPN/OpenVPN credentials are entered **only** on the desktop, via `sudo -u scraper-egress -e /opt/docker/scraper-egress/.env` — never drafted on the Mac first (Time Machine, iCloud sync, and editor swap-file exposure all apply to any Mac-resident plaintext credential file) and never echoed on a command line.
- `scripts/deploy_scraper_egress.sh` — new. Mirrors `scripts/deploy.sh`'s conventions (SSH_HOST=desktop-agent, idempotent `useradd --system --shell /usr/sbin/nologin` guarded by `id -u ... || useradd`, rsync code with `--exclude '.env'`) but is a **separate script**, not an edit to `deploy.sh` — satisfies the constraint that unrelated systemd-based deploy tooling stays untouched. Creates the `scraper-egress` user; does **not** add it to the `docker` group — instead installs a `/etc/sudoers.d/scraper-egress` drop-in scoped to exactly `docker compose -f /opt/docker/scraper-egress/docker-compose.yml *`, idempotently (install only if the file doesn't already match). Creates `/opt/docker/scraper-egress/`, rsyncs the compose file + `.env.example`. Template copy is guarded `[[ -f /opt/docker/scraper-egress/.env ]] || cp .env.example .env` so a re-run **never** overwrites operator-entered creds — idempotency for this script covers both user/sudoers creation *and* this guard, not user creation alone. Prints an instruction to fill in `.env` via `sudo -u scraper-egress -e /opt/docker/scraper-egress/.env` (never echoes or transfers real values itself). Deploy verification includes `docker port gluetun-scraper` returning empty (confirms no accidental `ports:` block exposing the control server). Re-running is a no-op past first creation (idempotent per NFR).
- `scripts/leak_test_scraper_egress.sh` — new. Bash, matching `scripts/`'s existing language convention (all sibling scripts in `scripts/` are bash or thin Python wrappers invoked by bash; this stays bash since it's pure `docker`/`curl`/`dig` orchestration, no algo-factory Python imports needed). Implements the four-assertion contract above, including the protocol-aware (`VPN_TYPE`-branching), kill-verified, continuously-polled fail-closed check and the `trap ... EXIT ERR` restore-to-healthy handler. Desktop-only — the Mac checkout has no Docker/desktop network to test against, consistent with `CLAUDE.md`'s existing "real execution happens on the desktop" routing rule.
- `docs/scraper-egress-harness/consumer-contract.md` — new. Houses the attachment-contract example (AC12) including the mandatory per-consumer resource-limit lines, the VPN-backend-swap guarantee scoped honestly per Design decisions (FR6 — explicitly *not* a residential-proxy drop-in), and an explicit restatement of the out-of-scope list (scraper implementations, stealth browser, cease-and-desist halt rail, rate governor, residential-proxy backend and its required transparent-proxy shim) for AC13's "documented in the harness's docs" requirement, even though `requirements.md`'s own Out of Scope section already technically satisfies it.
- `docs/scraper-egress-harness/deploy-and-rotate.md` — new. The credential install/rotation procedure (FR12): where the live `.env` lives, its required `chmod 600`/ownership, and how to rotate ProtonVPN credentials: `sudo -u scraper-egress -e /opt/docker/scraper-egress/.env` to edit in place, then `docker compose up -d --force-recreate` (**not** bare `restart`, which does not guarantee a rewritten `.env` is re-read into the container's environment). Explicitly forbids running bare `docker inspect <container>` or `docker compose config` against the live stack — both print resolved OpenVPN credentials in cleartext to stdout — permitting only `--format`-scoped state/health queries. Live credentials are entered ONLY on the desktop via `sudo -u scraper-egress -e`, never drafted on the Mac first and never echoed on a command line. Also carries the acceptance-criteria verification commands for AC9/AC10 (`stat`, `id`, `getent passwd`) to run on the desktop after deploy.
- `.gitignore` — no pattern change (existing `.env` / `.env.*` / `!.env.example` rules already cover `deploy/scraper-egress/.env` and `deploy/scraper-egress/.env.example` via git's basename-style matching for slash-free patterns). Optionally add a one-line **comment** near the secrets block noting the new directory is covered, for future-reader discoverability — not a functional change.
- `scripts/check_clean.sh` — **now edited** (scoped, justified change; previously left untouched, but this feature is the first to create nested secret-bearing paths, so the pre-existing gap becomes live rather than theoretical). Two additions: (1) a `git ls-files`-based nested-`.env` check that catches a force-added `.env` at any depth (the current `case "$f" in .env|.env.*)` is a full-path match, so it misses `deploy/scraper-egress/.env` entirely), plus a negative test proving the new check actually fires on a synthetic nested-`.env` fixture; (2) a ProtonVPN/OpenVPN credential content pattern added to the existing secret-content scan, since today's Alpaca-only regex would not catch a leaked `OPENVPN_PASSWORD` value even in a file the path-check does catch.

## Technology choices
- **gluetun + docker-compose**: new to this repo, justified purely by the constraint to mirror the proven arr-stack pattern rather than invent a new isolation mechanism (explicit constraint in requirements.md) — gluetun's `FIREWALL=on` kill-switch is already battle-tested on this exact desktop for the torrent stack, so reusing it for scraper egress is the lowest-risk path to a real fail-closed guarantee, and Docker's `network_mode: service:` primitive is the simplest way to give a consumer container zero-code network isolation without touching iptables directly.
- **Leak-test script in bash**: matches `scripts/`'s existing language convention (the repo is "pure-Python + systemd units" for application logic, but its operational/deploy scripts — `deploy.sh`, `backup_to_nas.sh`, etc. — are all bash). The leak-test is pure process/network orchestration (`docker run`, `docker exec`, `curl`, `dig`, `docker inspect --format`) with no algo-factory domain logic, so bash avoids pulling in a Python dependency (or a venv) for what is fundamentally a shell-out script, and keeps it runnable standalone on the desktop without activating the app's `.venv`.
- **New top-level `deploy/` directory** (vs. cramming compose files into `scripts/` or `systemd/`): keeps the first non-Python artifact visually and structurally separate from the Python app and its systemd units, so a future contributor scanning `systemd/` for "what services exist" isn't surprised by a Docker Compose file, and `scripts/` stays "things that shell out to or around the Python app" rather than absorbing an unrelated Docker stack's config.
- **Sudoers.d over docker-group** for `scraper-egress`'s deploy/operate privilege: matches `scripts/deploy.sh`'s existing narrow-NOPASSWD convention rather than introducing a new, broader privilege model just for this feature — see Design decisions for the reversibility argument.

## Risk areas
- **Fail-closed assertion is the hardest of the four to get right, and the original design would have false-passed on WireGuard.** `pkill openvpn` is a silent no-op when `VPN_TYPE=wireguard` (kernelspace WireGuard is a netlink interface with no `openvpn` process at all; userspace mode runs `wireguard-go`, not `openvpn`) — a script that doesn't verify the kill landed before probing would report `PASS fail-closed` while never having torn down the tunnel. The corrected design (protocol-aware kill, kill-verified via `pgrep`/`wg show`/interface-state before trusting any probe, continuous sub-second polling across the down→reconnect window, and a `trap ... EXIT ERR` restore-to-healthy handler that fires on any exit path including an SSH drop) closes this, but it remains the assertion most likely to regress silently if gluetun's WireGuard teardown internals change in a future image update — re-verify this check specifically after any `qmcgaw/gluetun` version bump.
- **Repo secret leak, even on a private repo.** The repo has been PRIVATE since 2026-07-03, which is the current baseline — not a reason to relax anything, since visibility can flip (added collaborator, re-fork, misconfigured GitHub App). `scripts/check_clean.sh`'s pre-existing `.env|.env.*` case-match was a full-path (not basename) match that would **not** have caught a force-added nested `.env` like `deploy/scraper-egress/.env`, and had no ProtonVPN/OpenVPN credential content pattern at all. This feature is the first to create nested secret-bearing paths in this repo, so that latent gap is fixed as part of this plan (see `check_clean.sh` in Integration points) rather than left as a documented-but-unaddressed risk. Operationally, the deploy doc still tells the operator to run `git ls-files deploy/ | grep -v '\.env\.example$'` (expect empty) before any push that touches this subtree, as defense in depth alongside the hardened gate.
- **Two gluetun containers on one host is genuinely new territory for this desktop** — untested for port/interface/iptables-chain collisions between arr-stack's gluetun and `egress-gateway` (both add `NET_ADMIN` and manipulate iptables independently). If gluetun's iptables rules aren't scoped per-container-netns cleanly, there's a small but real risk of one tunnel's firewall rules interfering with the other's, which would only surface at desktop deploy time, not from the Mac. Neither container gets `network_mode: host` (see Integration points config check), which keeps each tunnel's iptables rules scoped to its own netns and reduces — but does not eliminate — this risk.
- **`SERVER_COUNTRIES` divergence is operator-enforced, not machine-enforced.** AC2 requires the two gluetun configs differ; nothing in the compose file technically prevents an operator from copy-pasting the same `SERVER_COUNTRIES` value into both `.env` files. The leak-test's new `exit-isolation` assertion now catches the *symptom* of this (same exit IP as arr-stack) on every run, which is a stronger guard than the deploy doc's diff-the-two-files instruction alone, but the underlying config drift is still only prevented by that manual instruction.
- **Leak-test dependency on external IP-lookup services.** The `ip-exit` check's named external IP-echo endpoint is an availability risk outside this repo's control — if the lookup service is down or rate-limits, the assertion could false-fail. This is mitigated structurally, not just operationally: the check cross-checks against gluetun's own control-server `/v1/publicip/ip` (queried over localhost/netns) as a second, in-tunnel source of truth, so a single external outage doesn't produce a false `FAIL` on its own.
- **Gluetun's control server must never be reachable off-host.** Both gluetun services (arr-stack's and this feature's) are queried by the leak-test over localhost/netns/`docker exec` only — no compose `ports:` block exposes either control server, and deploy verification checks `docker port gluetun-scraper` is empty. An accidental published port here would let anything on the LAN query (or, depending on control-server auth config, potentially manipulate) either tunnel's state.
- **This host also runs live orders.** `egress-gateway` (and every future consumer per the attachment contract) carries explicit `mem_limit`/`cpus` limits so a scraper workload — however isolated at the network layer — cannot starve the Kalshi executor of host resources. This is a new requirement relative to arr-stack's own gluetun, which does not currently set these limits; it is not retrofitted onto arr-stack by this plan.
- **ProtonVPN account concurrency is unverified until checked.** If the account lacks headroom for a second simultaneous connection, first bring-up will fail non-obviously (auth succeeds, tunnel doesn't establish, or arr-stack's tunnel gets bumped). Confirm headroom, and the same-account-vs-separate-account tradeoff (Design decisions), before the first deploy attempt, not during it.
