---
name: home-infra-architecture-contract
description: Load this skill FIRST when working in the home-infra repo or on Preston's Personal AI Stack (NAS 10.0.0.250 / desktop 10.0.0.243) and you need to know WHY the system is shaped the way it is, which invariants must never be violated, or whether a file you are reading is stale. Triggers — "why is X on the NAS/desktop", "can I point this at Ollama", "the docs say :3001/:11434/SSE but reality differs", "is this spec current", port conflicts on :9622, planning any architectural change, or reconciling repo vs live-machine state. Keywords - Caddy, Authentik, Cloudflare Tunnel, Tailscale, forward auth, public vs internal service. Provides the design decisions with rationale (ADRs 0001–0012 distilled), the hard invariants, the AUTHORITATIVE drift register (repo vs live vs docs), and the known-weak points.
---

# home-infra Architecture Contract

The contract between intent (this repo) and reality (two live machines). Read this before trusting any doc in the repo and before proposing any structural change.

**What the system is** (zero-context orientation): Preston Bernstein's **Personal AI Stack** — a self-hosted AI assistant spanning a desktop PC and a Synology NAS. The Primary UI (**LibreChat**) talks to local LLMs (via **Ollama** behind a resource broker) and to tool servers (**MCPs** — Model Context Protocol services). An Obsidian note collection (the **Vault**) is compiled into an LLM-maintained **Wiki**, which a nightly **Vault Indexer** pushes into a **RAG Engine** (currently LightRAG, migrating to MiniRAG) so agents can answer questions over personal knowledge. Controlled vocabulary lives in `/Users/prestonbernstein/dev/home-infra/CONTEXT.md` — use its exact terms.

**The repo does not deploy anything.** `git@github.com:preston-bernstein/home-infra.git` (local checkout `/Users/prestonbernstein/dev/home-infra`) is a declarative mirror + docs. Humans (or directed agents) copy compose files to the machines and run `docker compose` by hand. No CI, no tests, no automation bridge — which is exactly why the drift register below exists.

**Sync contract** (ASSUMPTION — inferred convention, not written policy): repo compose is INTENT; the compose file on the machine is RUNTIME TRUTH. Change the repo first (or immediately after a live change), keep them convergent, and record any divergence in the drift register below. Behavior-changing actions go through `home-infra-change-control` — this skill never authorizes a change by itself.

## Topology — what runs where and why

| Machine | Name / IP | Runs | Why here |
|---|---|---|---|
| Desktop | `multimedia` / 10.0.0.243 | LibreChat + MongoDB, Ollama + resource broker (host, not containers), vision-mcp :3003, proton-email-mcp :3004, infinity-siglip (loopback :7997), Caddy, Authentik (server/worker/postgres/redis), cloudflared | 62GB RAM, RX 9070 XT 16GB VRAM. ADR 0005: the NAS was already 3.2GB into swap; MongoDB + Node would sink it. Co-locating LibreChat with Ollama makes LLM calls localhost. GPU is shared with gaming/Plex — hence the broker. |
| NAS | `house-of-light` / 10.0.0.250 | RAG Engine (lightrag :9621), lightrag-mcp :3002, vault-indexer (cron), tailscale-nas; compose also declares registry :5000, minirag :9622, watchtower (none of those three live yet — see drift #8) | Synology DS1522+, Ryzen R1600, only 7.7GB RAM. Storage-adjacent services only: the vault lives on the NAS (`/volume1/obsidian-vault`, Syncthing-synced), so the indexer and RAG store sit next to the data. |
| HA Pi | 10.0.0.5 | Home Assistant OS (:8123, built-in HA MCP) | Appliance; not managed by this repo. |

Docker on the NAS is at `/usr/local/bin/docker` and NOT in sudo's PATH — always `sudo /usr/local/bin/docker ...` (verified 2026-07-02: plain `sudo docker` → command not found). SSH as `agent@`, never `preston@` — full access pattern in `home-infra-run-and-operate`.

## Load-bearing design decisions (distilled from ADRs 0001–0012 + CONTEXT.md)

Read the one-paragraph ADR files in `/Users/prestonbernstein/dev/home-infra/docs/adr/` for full text. What matters and why:

1. **Broker mediation for ALL Ollama access** (commit f2565b4, project owner standing instructions). The GPU is shared with gaming and Plex; the `ollama-resource-broker` (repo `~/dev/ollama-resource-broker` on the desktop) arbitrates and returns 503 when the GPU is busy — clients must retry with backoff (see `wiki-ingest.py` `chat()`: 10/30/60/120/180s ladder). Lanes: `:11435` interactive, `:11436` batch/embeddings, `:11437/jobs` durable jobs, `:11438` Infinity SigLIP embed lane. Raw `:11434` is never a valid target. Full lane/model table: `home-infra-config-reference`; broker theory: `rag-stack-reference`.

2. **Vault → Indexer → RAG Engine: the index is a derived, disposable artifact.** The vault (`/volume1/obsidian-vault`) is the single source of truth; it is mounted **read-only** (`:ro`) into both lightrag and vault-indexer containers. The indexer (`vault-indexer/indexer.py`) is hash-based incremental, batch-inserts via `/documents/texts` then polls `track_status` for doc_ids (ADR 0002 — the POST response alone gives no IDs), and archives missing files 30 days before deleting (ADR 0003 — Syncthing hiccups look like deletions). Consequence: the RAG index can always be rebuilt from the vault; the reverse is never true. Nothing may write "up" into the vault as a side effect of querying.

3. **LLM Wiki compiled layer** (ADR 0012, Karpathy pattern). The RAG Engine indexes `wiki/` inside the vault, NOT raw notes. Captures land in `_raw/`, get compiled by `wiki-ingest.py` (runs on the MacBook, qwen3:8b via broker) into cross-linked wiki pages, then the captures are deleted. `indexer.py` excludes `_raw/` (`EXCLUDE_DIRS = {".agents", ".claude", ".obsidian", "_raw"}`). Why: the RAG Engine performs better on structured, cross-linked input, and retrieval quality compounds as the wiki grows. Operating the ingest: `home-infra-run-and-operate`.

4. **Agents never write the RAG Engine directly from chat.** LibreChat agents reach the RAG Engine only through `lightrag-mcp` (query path); all inserts/deletes flow through the vault → indexer pipeline. This keeps decision #2 true — a chat session that inserted documents would create index content with no vault source, unrebuildable and invisible to state tracking.

5. **One Docker service per Home MCP** (ADR 0007). Each MCP is its own compose service on its own port (lightrag-mcp :3002, vision :3003, proton-email :3004, financial-pipeline :3101). The mcpo single-gateway pattern was explicitly rejected (CONTEXT.md bans the term "MCP Gateway" for anything live). Adding an MCP = add a compose service, same operation every time. Note: ADR 0007's nginx `/mcp/<name>` path-routing half is NOT live — the location blocks in `compose/nas/nginx.conf` are commented out; clients hit ports directly per `compose/desktop/librechat.yaml`. Transport is `streamable-http` everywhere (ADR 0006 says SSE — see drift #7). LibreChat additionally requires `mcpSettings.allowedDomains` for private-LAN MCP URLs (SSRF protection; it silently blocks otherwise).

6. **Access and auth: three concentric layers** (ADRs 0008, 0009). (a) **Tailscale** — mesh VPN, demoted to admin/SSH and Internal Services only. (b) **Cloudflare Tunnel** (`cloudflared` on the desktop) — outbound-only tunnel publishing Public Services at `*.houseoflight.dev`; chosen over router port-forwards to avoid exposing the residential IP. (c) **Caddy + Authentik** on the desktop — Authentik is the single IdP; OIDC-capable services (LibreChat, HA) are OIDC Clients; everything else gets Caddy `forward_auth` (Caddy chosen over Traefik because explicit upstreams handle cross-host proxying to 10.0.0.250/10.0.0.5 cleanly; NPM rejected — no native forward auth). Access Groups: `admin`, `household`, `social`.

7. **LibreChat over Open WebUI** (ADR 0004): Open WebUI has no MCP client; MCP tool use is a first-class requirement. (But see drift #11 — an open-webui container is still running on the NAS.)

8. **MiniRAG over LightRAG — the in-flight migration** (ADRs 0010, 0011, uncommitted in the worktree as of 2026-07-02). LightRAG's entity extraction needs structured JSON the 16GB-VRAM-fitting models can't reliably produce (~35% doc failure measured on llama3.1:8b; HKUDS recommends 32b+, which doesn't fit). MiniRAG (same lab) is SLM-first, near-identical API, so lightrag-mcp is expected (UNVERIFIED — spec Step 3 is TBD) to be reusable. Embeddings switch mxbai-embed-large → bge-m3 at the same time (ADR 0011: mxbai degrades past ~1k tokens; bge-m3 handles 8192; free switch since full re-index anyway). Execution lives in `minirag-migration-campaign`.

## Invariants — must hold at all times

Each row: the rule, why, and what breaks if violated. These restate one-liners; the non-negotiables with full incident history live in `home-infra-change-control`.

| Invariant | Rationale (one line) | If violated |
|---|---|---|
| Never point anything at raw Ollama `:11434`; broker lanes only | GPU is shared with gaming/Plex; broker arbitrates contention | Unarbitrated load stutters games/Plex and starves other lanes; the client also bypasses 503 backpressure and fails unpredictably under load |
| Vault is source of truth; RAG index is disposable and rebuildable | Index is derived state; vault mounts are `:ro` by design | If unique content lives only in the index, a re-index (e.g. the MiniRAG migration, which requires one) silently destroys it |
| Agents never write the RAG Engine directly from chat; inserts go vault → indexer only | Indexer state (`hashes.json`, doc_ids) is the only deletion/rebuild ledger | Orphan documents with no vault source: untracked, undeletable via state, lost on rebuild |
| Secrets never in the repo — real values in `.env` on-machine, `.env.example` committed | Public-adjacent repo; incident: `LIGHTRAG_API_KEY=changeme` WAS committed (fixed in 3ec836f); the hardcoded `OVERSEERR_KEY` lived only in a working-tree script and was sanitized before any commit — it never entered git history (per `home-infra-failure-archaeology` F5) | Credential leak via git history; key rotation churn (full story: `home-infra-failure-archaeology`) |
| Respect the NAS memory budget — no memory-heavy services on the NAS (ADR 0005) | DS1522+ has 7.7GB RAM and was already at 3.2GB swap | Swap thrash degrades every NAS service at once, including the RAG Engine and Syncthing |
| Embedding model dims must match the vector store (ADR 0001) | nomic (768-dim) vs LightRAG's 1024-dim default blocked ALL indexing, silently | Zero documents index; switching models after seeding forces a full re-index |
| Desktop services run under dedicated nologin service users, never `preston`; agents SSH as `agent@` (project owner standing instructions) | Blast-radius containment and auditability | A compromised or misbehaving service has Preston's full account |
| Commits/PRs in this repo are authored by Preston only — no Claude attribution, no Co-Authored-By (project owner standing instructions) | Owner policy | — |
| Behavior-changing actions go through `home-infra-change-control` | This skill describes; it never authorizes | Ungated changes widen the drift register you are reading |

## Drift register — AUTHORITATIVE copy (verified 2026-07-02)

This table is the single home for repo-vs-live-vs-docs divergence (sibling skills cross-reference it; do not duplicate it elsewhere). Severity: **high** = can cause wrong action or blocks live work; **medium** = will mislead a runbook-follower; **low** = cosmetic/historic. "Owner" = suggested reconciliation path, always via `home-infra-change-control`.

| # | What the repo says | What reality says | Severity | Suggested reconciliation owner |
|---|---|---|---|---|
| 1 | `docs/specs/ai-stack.md`: raw Ollama `:11434`, default model llama3.1:8b, mxbai embeddings, LightRAG MCP `:3001` over SSE, aichat CLI plans, nginx `/mcp/<name>` routing, Phase 1–5 checklists unticked | Broker lanes `:11435+` (commit f2565b4), lightrag runs llama3.2:3b, MCP is `:3002` streamable-http hit directly, work happened but boxes never ticked | High (worst single doc — misleads any zero-context reader) | Docs rewrite or an explicit "HISTORICAL — see CONTEXT.md" banner; `home-infra-docs-and-writing` style, Preston approves |
| 2 | `mcp/lightrag/README.md`: package `daniel-lightrag-mcp`, SSE, port 3001 | `mcp/lightrag/Dockerfile` pip-installs `lightrag-mcp` with streamable-http; compose overrides the CMD to `--mcp-port 3002`; live container maps :3002 and EXPOSEs an unused 3001 | Medium | Rewrite README + drop stale `EXPOSE 3001`/CMD port from Dockerfile |
| 3 | `docs/specs/lightrag-vault-indexer.md` prose says "2am cron" | `vault-indexer/crontab` (uncommitted worktree change) says `0 4 * * *`; watchtower compose schedule `"0 0 4 * * *"` is the same 4am hour (co-scheduling coincidence worth knowing) | Low | One-word spec fix when the worktree commits |
| 4 | `CONTEXT.md` "Lint … Uses a local model (Ollama broker `:11436`)" | `wiki-ingest.py` uses `OLLAMA_URL` default `http://10.0.0.243:11435` for everything, lint included | Low–Medium (lane semantics: lint is batch-shaped, arguably belongs on :11436) | Decide intended lane, then fix whichever side is wrong — Preston call |
| 5 | Spec `docs/specs/lightrag-vault-indexer.md` (lines 53, 154): state at `/volume1/docker/vault-indexer/` | `compose/nas/docker-compose.yml`: `/volume1/docker/ai/vault-indexer:/state` (the real path) | Medium (a runbook-follower inspects/edits the wrong state dir) | Spec fix |
| 6 | `compose/desktop/docker-compose.yml` header: deploy path `/var/data/docker/docker-compose.yml` | Actual deploy path `/opt/docker/librechat-stack/` (verified via SSH 2026-07-02: `/var/data/docker` does not exist on the desktop) | Medium | Header comment fix |
| 7 | ADR 0006: "Use SSE transport for all Home MCPs" | Everything live is `streamable-http` (compose lightrag-mcp command, `librechat.yaml` all three mcpServers) — MCP spec evolved after the ADR | Low (the decision's real content — network-hosted, multi-client, not stdio — still holds) | Short superseding ADR, not an edit to 0006 |
| 8 | NAS compose declares `registry` (:5000), `minirag` (9622:9721), `watchtower` | Live NAS (docker ps 2026-07-02) runs NONE of those three, and DOES run `lightrag-trading` (0.0.0.0:9622→9621, Up 5h) which appears in no repo file — directly occupying minirag's planned port | **High — blocks migration Step 1; see known-weak points** | Preston MUST rule on lightrag-trading ownership first; then `minirag-migration-campaign` handles registry/minirag; watchtower: start it or remove it from compose |
| 9 | ~~`wiki-ingest.py` docstring: `--semantic-lint` runs "structural + semantic (LLM) lint"~~ | **CLOSED 2026-07-03** — entry-point conditional fixed; a bare `--semantic-lint` now only lints, matching the docstring. See `home-infra-failure-archaeology` F10. | — | Resolved |
| 10 | ADR 0010 cites ~35% extraction failure measured on llama3.1:8b | Committed compose runs lightrag with `LLM_MODEL=llama3.2:3b` — even smaller, so the "extraction quality bad" conclusion is directionally safe, but the cited numbers were never measured on 3b | Low | Optional: re-measure per `rag-evaluation-methodology`, or add a one-line note to the ADR context |
| 11 | *(additional, observed during 2026-07-02 verification)* ADR 0004: "Open WebUI is removed from the NAS compose entirely" — and the compose file is indeed clean | An `open-webui` container is still Up 4 weeks on the NAS (0.0.0.0:3000→8080) (authoring-session SSH observation 2026-07-02; not independently re-verified) | Low–Medium (unmanaged service, RAM cost on a memory-pressured NAS) | FLAG only — confirm with Preston whether it is intentionally retained; do not stop it unilaterally |

## Known-weak points (stated plainly)

- **`lightrag-trading` on NAS :9622 — FLAG ONLY, never resolve unilaterally.** Live container, Up 5h as of 2026-07-02, mapped 9622→9621, present in zero repo files. The repo's uncommitted compose assigns :9622 to minirag, so the MiniRAG migration cannot deploy until this is settled. It may be a deliberate second LightRAG instance for a trading corpus (name suggests so — ASSUMPTION). **Required action: ask Preston who owns it and where its config lives. Do not stop, rename, or re-port it, and do not "just pick another port" for minirag without his sign-off.**
- **lightrag-mcp ↔ MiniRAG compatibility is UNVERIFIED.** ADR 0010 claims near-identical API; `docs/specs/minirag-migration.md` Step 3 is explicitly TBD. Treat reuse as a hypothesis to test, not a fact — `minirag-migration-campaign` owns the verification.
- **fashion-monitor crash-loop** (`fashion-monitor-mcp-server-1` and `-dashboard-1` Restarting on the NAS, observed 2026-07-02). Owned by the separate fashion-monitor repo — OUT OF SCOPE here; noted so you don't misattribute NAS symptoms to this stack.
- **No CI, no tests, no automation bridge repo→machines.** Every deploy is manual; nothing catches repo/live divergence except humans updating the register above. Evidence standards: `home-infra-validation-and-qa`.
- **`docs/specs/ai-stack.md` is badly rotted** (drift #1). Treat it as historical intent only. Terminology of record is `CONTEXT.md`; runtime truth is the machines.

## When NOT to use this skill

- Looking up a specific port, env var, model name, or default → `home-infra-config-reference` (authoritative tables live there, not here).
- Executing or planning the MiniRAG migration → `minirag-migration-campaign`.
- Actually making any change (compose edits, restarts, deploys, code fixes listed in the drift register) → `home-infra-change-control` first, then `home-infra-build-and-deploy` / `home-infra-run-and-operate`.
- Debugging a live symptom → `home-infra-debugging-playbook`; past incidents in full → `home-infra-failure-archaeology`.
- RAG Engine API details, MCP transport theory → `rag-stack-reference`.

## Provenance and maintenance

- Facts verified 2026-07-02 against repo state (commit 6cbd3a1 + uncommitted MiniRAG-migration worktree changes) and live containers observed via SSH 2026-07-02.
- ADR distillations from `docs/adr/0001..0012` (0010–0012 uncommitted); vocabulary from `CONTEXT.md`; sync contract and lightrag-trading interpretation are labeled ASSUMPTIONS.
- Re-verification one-liners (run all before trusting volatile rows):
  - Repo state: `git -C /Users/prestonbernstein/dev/home-infra log --oneline -5 && git -C /Users/prestonbernstein/dev/home-infra status --short`
  - NAS live containers (drift #8, #11, weak points): `ssh -i ~/.ssh/agent_ed25519 agent@10.0.0.250 'sudo /usr/local/bin/docker ps --format "{{.Names}}\t{{.Ports}}\t{{.Status}}"'`
  - Desktop live containers + deploy path (drift #6): `ssh -i ~/.ssh/agent_ed25519 agent@10.0.0.243 'ls -d /opt/docker/librechat-stack /var/data/docker; docker ps --format "{{.Names}}\t{{.Ports}}"'`
  - Drift #1: `grep -n '11434\|llama3.1\|:3001\|SSE' /Users/prestonbernstein/dev/home-infra/docs/specs/ai-stack.md`
  - Drift #2: `grep -n 'daniel\|3001\|SSE' /Users/prestonbernstein/dev/home-infra/mcp/lightrag/README.md /Users/prestonbernstein/dev/home-infra/mcp/lightrag/Dockerfile`
  - Drift #3: `cat /Users/prestonbernstein/dev/home-infra/vault-indexer/crontab && grep -n '2am' /Users/prestonbernstein/dev/home-infra/docs/specs/lightrag-vault-indexer.md`
  - Drift #4: `grep -n '11435\|11436' /Users/prestonbernstein/dev/home-infra/CONTEXT.md /Users/prestonbernstein/dev/home-infra/wiki-ingest.py`
  - Drift #5: `grep -n 'vault-indexer/' /Users/prestonbernstein/dev/home-infra/docs/specs/lightrag-vault-indexer.md /Users/prestonbernstein/dev/home-infra/compose/nas/docker-compose.yml`
  - Drift #7: `grep -n 'streamable-http' /Users/prestonbernstein/dev/home-infra/compose/nas/docker-compose.yml /Users/prestonbernstein/dev/home-infra/compose/desktop/librechat.yaml`
  - Drift #9: `sed -n '388,402p' /Users/prestonbernstein/dev/home-infra/wiki-ingest.py`
  - Drift #10: `grep -n 'LLM_MODEL' /Users/prestonbernstein/dev/home-infra/compose/nas/docker-compose.yml && grep -n 'llama3.1' /Users/prestonbernstein/dev/home-infra/docs/adr/0010-minirag-over-lightrag.md`
- When any row stops matching reality, update THIS file (it owns the register) and notify siblings only if they cross-reference the changed row.
