# Spec Challenge Notes

## Agents run
- Requirements Auditor (haiku): 10 issues found, 8 accepted
- Scope & Dependency Auditor (sonnet): 7 issues found, 6 accepted
- Design Devil's Advocate (sonnet): 8 issues found, 8 accepted
- Implementation Realist (sonnet): 17 issues found, 15 accepted
- Steps & Sequencing Critic (sonnet): 12 issues found, 12 accepted
- Data Model Critic (sonnet): 13 issues found, 11 accepted
- Security/Threat Auditor (haiku): 12 issues found, 10 accepted

## Changes made
- **Architecture fix**: Prometheus now scrapes node_exporter and cAdvisor *directly* via native `scrape_configs`, instead of Alloy remote-writing metrics to it. The original design made AC5 ("Prometheus targets page shows node_exporter/cAdvisor as UP") architecturally impossible and left an unauthenticated remote-write receiver open on the LAN (cardinality-bomb/DoS vector). Alloy is now logs-only (Docker discovery + shipping to Loki). Confirmed independently by two reviewers.
- **cAdvisor/Alloy Docker-socket fix**: the plan originally pinned all six containers to the non-root `observability` UID, which conflicts with cAdvisor's and Alloy's hard requirement to read `/var/run/docker.sock` (root:docker, mode 660) — this would have crash-looped the two services most central to the stack's job. cAdvisor and Alloy now run as their image defaults; the other four services keep the UID pin. Documented why this doesn't violate CONVENTIONS.md's "never docker-group" rule (that governs the host service user, not a container's internal process).
- **Financial-data leak prevented**: FR4(c) originally shipped *all* Docker container logs on the desktop to the new shared Loki with no opt-in — which would have swept financial-pipeline's live Plaid/Betterment/Fidelity/Vanguard adapter logs into shared storage with zero redaction, flagged independently by both the Scope Auditor and Security Auditor. Log discovery is now scoped to an explicit allow-list/opt-in; financial-pipeline stays untouched until it's deliberately repointed in a later, separate change.
- **Port collision avoided**: verified live against the desktop (not hypothetical) — host port 8080 is already bound by `gluetun` (arr-stack). Added a hard "no `ports:` block for cAdvisor/node_exporter" rule so a default cAdvisor tutorial config can't collide with it.
- **Datasource UID correctness bug fixed**: the original plan suggested dashboard JSON could use Grafana's `${DS_PROMETHEUS}`/`${DS_LOKI}` template variables — those only resolve via the UI *import* wizard, not file-based *provisioning* (what this stack uses). Datasources now get fixed, explicit `uid:` values; dashboards reference those literal UIDs directly. Confirmed independently by three reviewers — this would have silently broken every panel.
- **Bind mounts replace named volumes**, matching actual repo precedent (scraper-egress, embed-stack) instead of the plan's claimed-but-inconsistent rationale; added a missing `alloy-data` mount for Alloy's log-position state, and a missing `loki/loki-config.yml` integration point with retention limits so Loki doesn't grow unbounded (Prometheus got equivalent retention flags).
- **deploy.sh's "structurally identical to scraper-egress" claim corrected** — scraper-egress rsyncs 3 flat files; this stack needs a real recursive sync across 4+ subdirectories. deploy.sh now also captures the real `id -u/-g observability` into `.env` (the old plan assumed a UID nothing guaranteed) and generates a random Grafana admin password instead of leaving it at default.
- **Steps re-sequenced and split**: Step 2 (dashboard export) now correctly depends on Step 1a (datasources.yml's final fixed UIDs must exist first) instead of being marked independent/parallel. Steps 1, 3, and 6 were each split (1a/1b, 3a/3b, 6a-6d) to stay within the 15min-2hr per-step time box and to make the previously-vague AC7 "renders successfully" test into an actual checklist.

## Critiques rejected
- Alloy River-config label injection from Docker container names — theoretical, low-probability given Alloy's structured (non-string-interpolated) label model; noted as a one-line hygiene comment rather than a blocking fix.
- UID-space collision with other desktop service users (finpipe, scraper-egress) — `useradd --system` allocates from the OS's dynamic UID range automatically; no real collision risk, no action needed.
- Full Authentik/OIDC integration for Grafana — named explicitly in Risk areas as a considered-and-deferred decision (single-operator, LAN-only for now); building it now would be disproportionate scope for this pass. Revisit via a follow-up ADR if broader access is ever needed.
- Network-naming and volume-naming inconsistency with sibling stacks (hyphen vs. underscore) — real but cosmetic; noted in README rather than forcing a rename, since both styles already coexist on the host.
- Alloy discovery-completeness proof (verifying literally every container gets discovered) — nice-to-have, not blocking; a spot-check via named containers is sufficient for this phase's acceptance criteria.

## Open questions requiring human input
- **Resource ceiling is still undefined.** Every service now gets mandatory conservative `mem_limit`/`cpus` values, but the actual numeric target for "acceptable idle CPU/memory usage on the desktop" was never provided and can't be derived from repo context — flagged in requirements.md as `[threshold TBD]`, needs Preston's number once the stack is running and `docker stats` gives a real baseline.
- **When/how financial-pipeline and fashion-monitor actually get repointed** at the shared stack (removing their own Grafana/Loki) is explicitly deferred to a follow-on change after this build is verified — per the original task framing, not a gap introduced by this challenge pass.
