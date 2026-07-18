# Requirements: Scraper Egress-Isolation Harness

## Problem statement
algo-factory's desktop host runs a real-money Kalshi executor and the financial data pipeline on the desktop's real WAN IP. Future social-platform scrapers (Reddit public-JSON, YouTube transcripts, etc.) need outbound internet access from that same host, but any scraper that gets IP-banned or rate-flagged must never put the shared real IP at risk. The desktop already runs a proven gluetun+ProtonVPN kill-switch pattern (`/opt/docker/arr-stack`) for the torrent stack; this feature replicates that pattern as a second, independent tunnel dedicated to scraping, version-controlled inside algo-factory, so a scrape-induced ban lands on a throwaway VPN exit instead of the trading infrastructure. This is the egress-isolation substrate only — no scraper logic runs in it yet.

## Users / stakeholders
- Future social-platform scrapers (Reddit public-JSON, YouTube transcripts, etc.) — the harness's consumers, attaching via a documented network contract.
- Kalshi real-money executor and financial pipeline — the infra this harness must never share an egress path, network namespace, or IP with.
- Operator (deploys and verifies via `ssh desktop-agent` / `sudo -u <service-user>` on the desktop) — runs the leak-test and owns the credential file.
- Private algo-factory repo / `scripts/check_clean.sh` — the guard this harness's committed artifacts must satisfy.

## Functional requirements

1. The system shall provide a docker-compose definition for a second, independent gluetun container (distinct container name from the existing arr-stack gluetun) dedicated to scraper egress.
2. The system shall configure the scraper gluetun container with its own ProtonVPN exit configuration (`SERVER_COUNTRIES` or equivalent) distinct from the arr-stack gluetun's configuration, so the two containers do not share an exit IP.
3. The system shall enable `FIREWALL=on` on the scraper gluetun container so that when the ProtonVPN tunnel is down, the container has zero outbound internet connectivity and does not fall back to the host's routing.
4. The system shall scope `FIREWALL_OUTBOUND_SUBNETS` on the scraper gluetun container to the minimum the scraper needs — at most the DNS resolver host as a single /32, or empty if the tunnel itself provides DNS — routing all other egress exclusively through the ProtonVPN tunnel, and shall NOT carve out the full 10.0.0.0/24 LAN. The desktop's financial-pipeline Postgres (10.0.0.250:5432), the NAS, and the desktop's own LAN IP all live on that /24; a full-/24 exception would give a compromised scraper a direct network path to the exact infra this harness protects.
5. The system shall set `DNS_KEEP_NAMESERVER=off` on the scraper gluetun container so DNS resolution is forced through the tunnel's resolver and cannot silently fall back to the host's or ISP's nameserver.
6. The system shall define the compose file using container-isolated (default bridge) networking for the scraper gluetun container, never `network_mode: host`, verified by inspecting the compose file — host networking would apply gluetun's FIREWALL DROP rules to the desktop's real host network namespace and could firewall off the Kalshi executor's own egress.
7. The system shall NOT publish the gluetun container's control server, or any other port, to the host/LAN — the compose service shall carry no `ports:` mapping — verified by `docker port` on the container returning empty.
8. The system shall define a healthcheck on the scraper gluetun container that reflects real tunnel-up connectivity (via `HEALTH_TARGET_ADDRESS` or equivalent), so that a consumer's `depends_on: condition: service_healthy` gates on an established tunnel rather than merely on container start.
9. The system shall define a consumer attachment contract (e.g. `network_mode: service:<scraper-gluetun-container>` plus `depends_on` on the gluetun service) that any future scraper container uses to route through the tunnel, documented separately from the gluetun backend implementation.
10. The system shall document the consumer contract such that swapping the tunnel backend (e.g. to a residential-proxy backend) requires no change to how a consumer container attaches.
11. The system shall provide a `*.env.example` template, committed to the repo, in which secret-bearing variables (ProtonVPN username/password) are empty placeholders, while the non-secret fail-closed defaults — `FIREWALL=on`, the minimal `FIREWALL_OUTBOUND_SUBNETS` value, and `DNS_KEEP_NAMESERVER=off` — are committed as real literal values, so that any future change to those defaults appears as a reviewable diff rather than being hidden behind a placeholder.
12. The system shall read live ProtonVPN credentials only from a git-ignored env file, never from a committed file.
13. The system shall provide a leak-test script, runnable on the desktop, that performs the following as four separate pass/fail assertions:
    a. The system shall verify that a public-IP lookup made from inside the scraper container's network namespace returns the ProtonVPN exit IP and not the desktop's real WAN IP.
    b. The system shall verify that DNS resolution performed from inside the scraper container's network namespace actually resolves through the tunnel's resolver — via an active resolution check, not merely by inspecting `resolv.conf` — and does not reach the host's or ISP's resolver.
    c. The system shall verify, before trusting any post-kill egress probe, that the ProtonVPN tunnel was actually torn down — protocol-aware per `VPN_TYPE` (the OpenVPN process is gone in OpenVPN mode; the `wg` interface is down in WireGuard mode) — and shall FAIL this assertion, rather than reporting a false PASS, if the kill did not land. Only once teardown is confirmed shall it verify that an egress attempt from the attached container fails (times out or is refused) rather than succeeding via the host's real IP.
    d. The system shall verify, on every run, that the scraper tunnel's exit IP differs from the arr-stack gluetun's CURRENT exit IP (queried live, not inferred from `SERVER_COUNTRIES` divergence alone) — exit IPs drift on reconnect, so distinct exit-selection configuration alone is not a guarantee of a distinct IP.
14. The system shall print a single explicit PASS or FAIL result per assertion (13a, 13b, 13c, 13d) when the leak-test script runs, and shall exit non-zero if any assertion fails.
15. The system shall provide a deploy procedure that installs the scraper gluetun stack on the desktop under a dedicated `nologin` service user distinct from the existing algo-factory app service user and the media service user.
16. The system shall provide a deploy procedure that grants the scraper service user permission to run the harness's docker compose via a narrow sudoers grant scoped to exactly the harness compose file (mirroring `scripts/deploy.sh`'s existing narrow-NOPASSWD sudoers pattern), and shall NOT add the scraper service user to the `docker` group — docker-group membership is host-root-equivalent and would defeat the isolation from the Kalshi executor / `live.db` this harness exists to provide.
17. The system shall document, in the repo, how to install and rotate the credential env file (ownership, permissions, location) as part of the deploy procedure.
18. The system shall be excluded from `git ls-files` for the live credential env file — no file containing real ProtonVPN credentials shall ever be tracked by git.
19. The system shall, before first bring-up, confirm the ProtonVPN account's simultaneous-connection headroom is sufficient for a second concurrent tunnel alongside the existing arr-stack tunnel, and shall document, as a deliberate decision, whether the scraper tunnel uses the same ProtonVPN account/credential set as the arr-stack tunnel or a separate one — using the same account means scraping-induced account flagging could also take down the torrent tunnel.

## Non-functional requirements
- The live credential env file shall be `chmod 600` and owned by the dedicated scraper service user.
- The live credential env file shall never appear in `git ls-files` output; only its `*.example` counterpart is tracked.
- No script, log, or console output produced by this harness shall print the contents of the credential env file (VPN username/password) in plaintext.
- The scraper gluetun container's network stack shall be isolated from the containers/services used by the Kalshi executor and financial pipeline (no shared `network_mode`, no shared container namespace).
- The scraper gluetun container's ProtonVPN exit configuration shall differ from the arr-stack gluetun's, so the two never present the same exit IP.
- The scraper gluetun container shall declare conservative CPU/memory limits so a future attached consumer cannot starve or OOM the co-resident real-money Kalshi executor.
- All new committed artifacts (compose file, `*.env.example`, scripts, docs) shall pass `scripts/check_clean.sh` with no modification to the script's existing secret patterns required to admit a real secret.
- The deploy procedure shall be idempotent — re-running it shall not duplicate the service user, containers, or systemd/compose registration.

## Constraints
- Must mirror the existing proven `/opt/docker/arr-stack` gluetun pattern (image `qmcgaw/gluetun`, `cap_add: NET_ADMIN`, `device: /dev/net/tun`, `env_file`-sourced credentials, `FIREWALL=on`, `FIREWALL_OUTBOUND_SUBNETS`) rather than inventing a new isolation mechanism.
- Must run as a second, separate gluetun container/stack — must not modify, share, or depend on the arr-stack gluetun container.
- This is the first docker-compose introduced into algo-factory; the rest of the repo is pure-Python + systemd units. The compose file and any supporting scripts must not require changes to the existing systemd-based deploy tooling for unrelated services.
- The repo is private (since 2026-07-03, per `scripts/check_clean.sh`'s own header). This does not relax secret-hygiene requirements: secrets must never be committed regardless of repo visibility, since a private repo can be re-flipped to public, forked, or leaked. `scripts/check_clean.sh` gates every push. All secret-bearing files must be git-ignored per the existing `.env` / `.env.*` / `!.env.example` pattern in `.gitignore`.
- Real deploy and real leak-test verification can only be executed on the desktop (`ssh desktop-agent`), where gluetun, the ProtonVPN credentials, and the shared financial infra physically reside. The harness must be authorable and committable from the Mac dev checkout without requiring desktop access to write the code.
- Must deploy under its own dedicated `nologin` service user, separate from the existing `algo-factory` app service user (`/home/algo-factory`) and the media stack's service user.
- The consumer attachment contract must not hardcode ProtonVPN-specific configuration in a way that couples future scraper containers to that backend.

## Out of scope
- The scraper implementations themselves (Reddit public-JSON, YouTube transcripts, or any other platform scraper).
- The stealth browser layer (Patchright or any browser-automation component).
- The stop-on-cease-and-desist halt rail.
- The rate governor / request-pacing logic.
- Any residential-proxy backend implementation (only the documented future swap-in point is required now).

## Acceptance criteria
1. `docker compose config` (or equivalent) on the scraper compose file succeeds with only placeholder values substituted from `*.env.example`.
2. The scraper gluetun container name and `SERVER_COUNTRIES` (or equivalent exit-selection variable) are distinct from the arr-stack gluetun's, verified by inspecting both compose files.
3. The compose file uses container-isolated (default bridge) networking for the scraper gluetun container, not `network_mode: host`, verified by inspecting the compose file.
4. `docker port <scraper-gluetun-container>` returns empty — no port (including the control server) is published to the host/LAN.
5. The deployed `FIREWALL_OUTBOUND_SUBNETS` value is confirmed to be at most a single DNS-resolver /32 (or empty), not a broad LAN range such as 10.0.0.0/24, verified by inspecting the deployed compose/env config.
6. With the tunnel up, the leak-test script's public-IP assertion (13a) reports PASS: the IP observed from inside the attached network namespace equals the ProtonVPN exit IP and differs from the desktop's real WAN IP.
7. With the tunnel up, the leak-test script's exit-IP-divergence assertion (13d) reports PASS: the scraper tunnel's exit IP differs from the arr-stack gluetun's CURRENT exit IP, re-checked on that run rather than assumed from static config.
8. With the tunnel up, the leak-test script's DNS assertion (13b) reports PASS: DNS resolution from inside the attached network namespace is confirmed, via an active resolution check, to actually resolve through the tunnel path and not reach the host/ISP resolver.
9. With the tunnel forced down, the leak-test script's fail-closed assertion (13c) reports PASS only after confirming the tunnel was actually torn down (protocol-aware per `VPN_TYPE`), and reports FAIL rather than a false PASS if the kill did not land; when teardown is confirmed, an egress attempt from the attached container fails rather than succeeding via the host's real IP.
10. The leak-test script exits 0 only when all four assertions (6, 7, 8, 9) pass, and exits non-zero if any one fails.
11. `git ls-files` run against the repo contains no file with real ProtonVPN credentials; only a `*.env.example` with placeholder values is tracked.
12. `scripts/check_clean.sh` passes with the harness's files committed, unmodified in its existing secret-detection logic.
13. On the desktop, the live credential env file is confirmed `chmod 600` and owned by the dedicated scraper service user (via `stat`/`ls -l`).
14. The dedicated scraper service user is confirmed distinct from both the `algo-factory` service user and the media service user (via `id`/`getent passwd` on the desktop).
15. The scraper service user is confirmed NOT a member of the `docker` group (via `id`/`groups` on the desktop).
16. Re-running the deploy procedure does not duplicate the service user or containers, and does not overwrite an already-populated live credential env file with the blank `*.env.example` template — a second run preserves any operator-entered ProtonVPN credentials.
17. No plaintext VPN credential appears in any script output, log file, or console output produced when running the deploy procedure or the leak-test script.
18. A documented example (in the harness's docs) shows a consumer container attaching via the network contract (e.g. `network_mode: service:<scraper-gluetun-container>` + `depends_on`) without referencing ProtonVPN-specific variables directly in the consumer's own service definition.
19. The harness's documentation explicitly lists the scraper implementations, stealth browser, cease-and-desist halt rail, and rate governor as out of scope for this feature.
