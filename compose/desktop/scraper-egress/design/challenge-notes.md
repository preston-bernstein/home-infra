# Spec Challenge Notes

## Agents run
- Requirements Auditor (haiku): 4 issues found, 3 accepted
- Scope & Dependency Auditor (sonnet): 9 issues found, 7 accepted
- Design Devil's Advocate (sonnet): 8 issues found, 7 accepted
- Implementation Realist (sonnet): 7 major issues found, 7 accepted
- Steps & Sequencing Critic (sonnet): 8 issues found, 7 accepted
- Data Model Critic (haiku): 3 issues found, 3 accepted (no data model — pivoted to healthcheck/reconnect/drift)
- Security/Threat Auditor (sonnet — upgraded from the skill's default haiku because this feature IS a security control; noted, not silent): 11 issues found, 10 accepted

## Changes made
- **Fail-closed test was structurally broken and would false-PASS.** `pkill openvpn` is a silent no-op under WireGuard mode (no openvpn process exists), so the kill-switch's own verification could report PASS having never broken the tunnel. Redesigned protocol-aware (branch on VPN_TYPE), verify the kill actually landed (pgrep / wg show) before trusting the probe, and — since gluetun's FIREWALL=on iptables rules persist across reconnects — poll continuously across the outage window rather than one bounded curl. This was the single most important fix; the whole feature's guarantee depended on a test that didn't test it.
- **docker-group membership → narrow sudoers.** Adding the scraper service user to the `docker` group is host-root-equivalent — it could read `live.db`, the Kalshi creds, and mount `/`, collapsing the exact isolation this harness exists to provide. Replaced with a sudoers.d grant scoped to just the harness compose file (mirrors the repo's existing narrow-sudoers pattern).
- **`FIREWALL_OUTBOUND_SUBNETS` narrowed from the full 10.0.0.0/24 to DNS-only (or empty).** The broad LAN carve-out gave a compromised scraper a direct network path to the finpipe Postgres (10.0.0.250:5432), the NAS, and the desktop itself — lateral access to the protected infra, by design. Now scoped to the minimum.
- **Added a 4th leak-test assertion: scraper exit IP ≠ arr-stack (torrent) gluetun's *current* exit IP** — the actual isolation property. The spec previously only checked ≠ desktop WAN IP; two gluetun stacks pointed at the same Proton server would both pass while sharing an exit.
- **Added the missing commit→push→desktop-pull bridge step.** Steps jumped from Mac authoring to desktop deploy with nothing syncing the code to the desktop's git checkout (which deploys from git) — a hard build-blocker. Now an explicit step with every desktop step depending on it.
- **Control-server exposure + host-netns guards.** Explicit "no `ports:` mapping" (gluetun's control server must not be LAN-reachable) and "never `network_mode: host`" (host networking would apply the FIREWALL DROP rules to the desktop's real netns and could firewall off the Kalshi executor) — both now acceptance criteria, plus a "read the real arr-stack compose before authoring, don't blind-cp" instruction.
- **Secret-hygiene hardening:** `.env`-clobber-on-redeploy guard (a second deploy must not overwrite operator creds), forbid bare `docker inspect`/`docker compose config` (print resolved creds cleartext), never draft `.env` on the Mac (Time Machine/iCloud/swap exposure), and a scoped `check_clean.sh` hardening to catch a force-added *nested* `.env` (its current match is top-level-path-only and has no ProtonVPN cred pattern) with a negative test proving the gap closed.

## Critiques rejected
- **consumer-contract.md is redundant with requirements.md's out-of-scope section** (Design agent, self-labeled lowest-stakes) — kept the doc: it's the future scraper's onboarding surface (attach example + honest backend-swap caveat + resource-limit requirement), made non-redundant rather than deleted.
- **"Two gluetun containers' iptables chains will collide"** (in the original plan's own risk section) — the Realist showed this is unfounded under default bridge networking (each container's netns is private); folded into the host-networking guard instead of kept as a standalone risk.

## Open questions requiring human input
- **ProtonVPN account decision (needs Preston + a real check before bring-up, NOT before build):** same account as arr-stack (a second concurrent tunnel — must confirm the plan tier's simultaneous-connection headroom, and accept that scraping-induced account flagging could also drop the torrent tunnel) vs a separate account/credential set. The build can author with same-account assumed + documented; Phase 8 bring-up verification must confirm the headroom. Flagged in the report.
- **Minor build-reconcile (not blocking):** AC12 still reads "check_clean.sh passes ... unmodified in its existing secret-detection logic," but the plan now adds an *additive* nested-`.env` hardening to check_clean.sh. These are compatible (the hardening only adds detection; the harness's own files still pass) — new-story should treat AC12 as "harness files pass the gate (post-hardening)," not as a prohibition on the additive edit.
