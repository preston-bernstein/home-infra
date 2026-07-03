---
name: home-infra-build-and-deploy
description: Load when building, transferring, or deploying container images or compose stacks for Preston's home-infra AI stack — e.g. "build the vault-indexer image", "deploy the NAS compose", "push to the registry", "rebuild the environment from scratch", "why is my image exec format error / wrong architecture", "where do compose files go on the NAS/desktop", "what does watchtower update". Provides the buildx amd64 build pattern, NAS-registry vs docker-save/ssh-load transfer paths, deploy paths on both machines, the compose update workflow, watchtower behavior, and a from-scratch rebuild checklist with known traps.
---

# home-infra: Build and Deploy

Runbook for turning this repo's declared state into running containers on the two machines. Audience: an engineer or agent with zero prior context.

## 1. Mental model: repo = intent, machines = runtime

- The repo (`~/dev/home-infra`, github.com/preston-bernstein/home-infra) is a **declarative mirror**: compose files, Dockerfiles, docs. It is INTENT.
- **Nothing auto-deploys.** There is no CI, no GitOps, no sync agent. A human (or a directed agent) copies compose files onto the target machine and runs `docker compose` there by hand. Whatever is running on the machines is RUNTIME TRUTH; the two can and do drift (see `home-infra-architecture-contract` for the drift register).
- ASSUMPTION (labeled, per project convention): the sync contract is "change repo first, or immediately after; keep repo and live convergent; record divergence in the drift register."

Deploy paths (repo file → live location):

| Repo file | Machine | Live deploy path |
|---|---|---|
| `compose/nas/docker-compose.yml` | NAS 10.0.0.250 (house-of-light) | `/volume1/docker/ai/docker-compose.yml` |
| `compose/desktop/docker-compose.yml` | Desktop 10.0.0.243 (multimedia) | `/opt/docker/librechat-stack/docker-compose.yml` |
| `compose/desktop/embed-stack/docker-compose.yml` | Desktop 10.0.0.243 | `/opt/docker/embed-stack/docker-compose.yml` |

**Trap:** the header comment in `compose/desktop/docker-compose.yml` says deploy path `/var/data/docker/` — that comment is STALE. The real path is `/opt/docker/librechat-stack/` (the compose's own volume mounts confirm it: `/opt/docker/librechat-stack/data/...`).

**Change control:** deploying, restarting, or reconfiguring a *live* service is a gated, behavior-changing action — class (c) in `home-infra-change-control`. Read that skill before touching anything running. Image builds on the MacBook are ungated; repo compose/config EDITS are Class B per `home-infra-change-control` (secrets scan + `:11434` grep + human review of the diff).

## 2. Image build pattern (MacBook → amd64 targets)

The build machine is an ARM MacBook (Apple Silicon). Both target machines are x86_64. A plain `docker build` on the Mac produces an arm64 image that will fail on the target with `exec format error`.

**ALWAYS build with:**

```bash
docker buildx build --platform linux/amd64 -t <image>:latest <context-dir>
```

Custom images defined in this repo (as of 2026-07-02):

| Image | Build context | Runs on | Notes |
|---|---|---|---|
| `vault-indexer:latest` | `vault-indexer/` | NAS | `python:3.12-slim` + cron; copies `indexer.py` + `crontab` (nightly 4am run). Rebuild whenever `indexer.py` or `crontab` changes — the code is baked in, not volume-mounted. |
| `lightrag-mcp:latest` | `mcp/lightrag/` | NAS | Dockerfile pip-installs **`lightrag-mcp`**. The README in that directory says `daniel-lightrag-mcp` and port 3001 — both STALE. The Dockerfile is truth for the package name; compose is truth for the port (:3002; the Dockerfile's `EXPOSE 3001` + CMD port 3001 are overridden by the compose `command:` block). |
| `vision-mcp:latest` | `mcp/vision/` | Desktop | `python:3.12-slim` + fastmcp/httpx + `server.py`, port 3003. |
| `10.0.0.250:5000/minirag:latest` | cloned HKUDS/MiniRAG source | NAS (migration, not yet live) | **No pre-built GHCR image exists** — must build from source. **Trap:** the upstream Dockerfile `COPY`s a `.env` that is not in their repo; you must `touch .env` in the clone or the build fails. See `docs/specs/minirag-migration.md` Prerequisites. |

MiniRAG build trap: the upstream Dockerfile `COPY`s a `.env` that the HKUDS repo does not
ship — `touch` one in the clone before the buildx amd64 build, or the build fails at a
COPY step. Exact commands: `minirag-migration-campaign` Phase 2.

(Not `proton-email-mcp` — that builds on the desktop itself from `/opt/docker/librechat-stack/proton-email-mcp`, per the desktop compose `build:` block; its source is not in this repo.)

## 3. Getting images onto the machines

### Path A — NAS registry (the intended pattern)

The NAS compose declares a `registry:2` service on `:5000` backed by `/volume1/docker/registry`. Intended flow:

```bash
docker push 10.0.0.250:5000/<image>:latest
# then on the NAS:
sudo /usr/local/bin/docker compose pull <service>
```

Two flags before relying on this:

1. **The registry was NOT running live as of 2026-07-02** (observed via SSH: container absent). It exists only in the repo compose. Starting it is itself a deploy — gate via `home-infra-change-control`, then `sudo /usr/local/bin/docker compose up -d registry` in `/volume1/docker/ai/`.
2. It is a plain-HTTP registry. Pushing from macOS Docker Desktop requires `"insecure-registries": ["10.0.0.250:5000"]` in Docker Desktop → Settings → Docker Engine (then Apply & Restart). **UNVERIFIED whether the MacBook already has this configured** — check with `docker info | grep -A2 -i insecure` before your first push; an unconfigured push fails with `http: server gave HTTP response to HTTPS client`.

### Path B — save/ssh-load stream (proven fallback)

Works today with nothing extra running. Synology **blocks rsync-over-ssh**, and `scp` to Synology needs the legacy `-O` flag — so stream instead of copying a tarball:

```bash
# NAS target:
docker save vault-indexer:latest | ssh -i ~/.ssh/agent_ed25519 agent@10.0.0.250 \
  'sudo /usr/local/bin/docker load'

# Desktop target:
docker save vision-mcp:latest | ssh -i ~/.ssh/agent_ed25519 agent@10.0.0.243 \
  'sudo docker load'
```

Images loaded this way are referenced by bare local tags in compose (`vault-indexer:latest`, `lightrag-mcp:latest`, `vision-mcp:latest`) — never `docker compose pull` them; pull would fail (no remote) or, worse for registry-tagged names, overwrite your local build.

## 4. Deploy / update workflow

SSH as `agent@` (never `preston@`) — see `home-infra-run-and-operate` for the full access pattern. On the NAS, docker lives at `/usr/local/bin/docker` and is NOT in sudo's PATH: `sudo docker` → command not found. Always `sudo /usr/local/bin/docker`.

Standard update of one service (example: vault-indexer on NAS):

```bash
# 1. Build on Mac (amd64!) and transfer (section 2 + 3)
# 2. Copy updated compose if it changed:
scp -O -i ~/.ssh/agent_ed25519 compose/nas/docker-compose.yml agent@10.0.0.250:/tmp/
ssh -i ~/.ssh/agent_ed25519 agent@10.0.0.250 \
  'sudo cp /tmp/docker-compose.yml /volume1/docker/ai/docker-compose.yml'
# 3. Recreate just that service:
ssh -i ~/.ssh/agent_ed25519 agent@10.0.0.250 \
  'cd /volume1/docker/ai && sudo /usr/local/bin/docker compose up -d vault-indexer'
# 4. Verify:
ssh -i ~/.ssh/agent_ed25519 agent@10.0.0.250 \
  'sudo /usr/local/bin/docker logs --tail 50 vault-indexer'
```

`.env` files live **on-machine only**, next to each compose file — never in the repo. Templates are committed as `.env.example` (repo root, `compose/nas/`, `compose/desktop/`). These are **dotfiles: plain `ls` hides them** — use `ls -la`. Secrets referenced by compose (e.g. `LIGHTRAG_API_KEY` in `/volume1/docker/ai/.env` on the NAS; `JWT_SECRET`, `PROTON_*` in `/opt/docker/librechat-stack/.env` on the desktop) stay on the machines. Never copy secret values into skills, docs, or commits.

## 5. Watchtower (NAS auto-updates)

The NAS compose runs `containrrr/watchtower` with `--schedule "0 0 4 * * *" --cleanup` — **nightly at 4:00 AM** (6-field cron with seconds). Note: the vault-indexer cron also runs at 4am (`vault-indexer/crontab`) — same hour, coincidence worth knowing when reading 4am logs.

- **Auto-updated:** services on public-registry images with movable tags — `tailscale/tailscale:latest`, `ghcr.io/hkuds/lightrag:latest`, `registry:2`, watchtower itself.
- **NOT auto-updated:** locally-loaded images (`vault-indexer:latest`, `lightrag-mcp:latest`) — there is no remote to pull from, so watchtower's pull finds nothing newer. Update these only by rebuilding and re-loading (sections 2–3).
- **Risk:** a `:latest` bump can change behavior overnight with no human in the loop (e.g. lightrag upstream changes its API at 4am). If a NAS service breaks "by itself" in the early morning, check `sudo /usr/local/bin/docker logs watchtower` and the image's created date (`docker inspect -f '{{.Created}}' <image>`) before debugging anything else.
- As of 2026-07-02 watchtower was **in the repo compose but not observed running live** — another repo-vs-live drift; confirm with `docker ps` before assuming nightly updates happen.

## 6. From-scratch rebuild checklist

Order matters. Everything below is derived from repo files; live-machine specifics labeled where unverifiable.

**On the NAS (10.0.0.250):**

1. Create the external docker network **before any `compose up`** — the NAS compose declares `ai-net` as `external: true, name: ai_ai-net`, so compose will not create it and errors out if missing:
   ```bash
   sudo /usr/local/bin/docker network create ai_ai-net
   ```
2. Create paths (from compose volume mounts): `/volume1/docker/ai/` (compose + `.env` home), `/volume1/docker/ai/lightrag/`, `/volume1/docker/ai/vault-indexer/` (state + logs), `/volume1/docker/ai/minirag/` (migration), `/volume1/docker/registry/`, `/volume1/docker/tailscale/`. The Obsidian vault at `/volume1/obsidian-vault` (owner `sc-syncthing`) is mounted read-only into lightrag and vault-indexer — it must already exist; never write into it casually (Syncthing propagates everywhere).
3. `.env`: copy `compose/nas/.env.example` → `/volume1/docker/ai/.env`; set `LIGHTRAG_API_KEY` (`openssl rand -hex 32`) and a fresh `TS_AUTHKEY`.
4. Tailscale: on first boot the container auths with `TS_AUTHKEY`, then persists state in `/volume1/docker/tailscale` — blank the key after first auth (per `.env.example`). Hostname `house-of-light`; serve config expected at `/var/lib/tailscale/serve-config.json` inside the container (UNVERIFIED whether a serve-config file needs pre-seeding on a truly fresh volume).
5. Load custom images (section 3), copy compose, `sudo /usr/local/bin/docker compose up -d`, check `docker logs` per service.

**On the desktop (10.0.0.243):**

1. Pull Ollama models (Ollama + broker run on the host, not in containers). Referenced across the repo's compose/spec files:
   - Current stack: `llama3.2:3b` (lightrag LLM), `mxbai-embed-large` (lightrag embeddings), `llava:13b` (vision-mcp).
   - MiniRAG migration (pull before deploying MiniRAG — first index blocks on model load): `qwen2.5:14b`, `bge-m3`.
   - Wiki ingest (`wiki-ingest.py`, runs on the MacBook but inference is on this host): `qwen3:8b`.
2. Ensure ollama-resource-broker is running (`~/dev/ollama-resource-broker` on the desktop; lanes :11435/:11436/:11437, :11438 for embed). **Nothing may point at raw `:11434`** — see `home-infra-change-control`.
3. Create `/opt/docker/librechat-stack/` (+ `data/librechat`, `data/mongodb`) and `/opt/docker/embed-stack/` (+ `hf-cache`). **New desktop services run under dedicated nologin service users, never `preston`** (project owner standing instruction; e.g. embed-stack owner is `embed`).
4. `.env`: copy `compose/desktop/.env.example` → `/opt/docker/librechat-stack/.env`; fill `JWT_SECRET`/`JWT_REFRESH_SECRET`, Proton Bridge creds.
5. Copy `compose/desktop/librechat.yaml` → `/opt/docker/librechat-stack/librechat.yaml` (mounted ro). It must keep `mcpSettings.allowedDomains` — LibreChat silently blocks private-LAN MCP servers without it (SSRF protection).
6. Load `vision-mcp:latest`; `docker compose up -d` in each stack dir; embed-stack's infinity-siglip has a 180s health-check start period — wait before judging it unhealthy.

## 7. Known traps (read before your first build/deploy)

| Trap | Symptom | Fix |
|---|---|---|
| Missing `--platform linux/amd64` on Mac build | `exec format error` on NAS/desktop | Rebuild with `docker buildx build --platform linux/amd64` |
| MiniRAG Dockerfile requires `.env` absent from upstream repo | build fails at a COPY step | `touch <clone>/.env` before building |
| `sudo docker` on NAS | `command not found` | `sudo /usr/local/bin/docker` |
| `ai-net` network missing | `network ai_ai-net declared as external, but could not be found` | `docker network create ai_ai-net` first |
| `.env.example` files are dotfiles | "there are no env templates in the repo" | `ls -la`; they exist at repo root, `compose/nas/`, `compose/desktop/` |
| Desktop compose header says `/var/data/docker` | deploy to wrong path | Real path is `/opt/docker/librechat-stack/` (stale comment) |
| `mcp/lightrag/README.md` says `daniel-lightrag-mcp` / :3001 | wrong package installed, wrong port probed | Dockerfile installs `lightrag-mcp`; compose runs it on :3002 |
| rsync to Synology | rsync-over-ssh blocked | `docker save \| ssh ... docker load`; plain scp needs `-O` |
| New desktop service run as `preston` | violates standing instruction | dedicated nologin service user per service |
| NAS `:9622` | live NAS runs undocumented `lightrag-trading` on :9622 (as of 2026-07-02); repo minirag moved to `:9623` 2026-07-03, no longer contests it | FLAG — confirm ownership with Preston before touching :9622; do not resolve unilaterally |

## When NOT to use this skill

- Day-2 operations (SSH patterns, manual indexer runs, cron, logs, wiki-ingest) → `home-infra-run-and-operate`.
- Executing the MiniRAG migration step-by-step (deploy order, verification gates, rollback) → `minirag-migration-campaign`; this skill only covers *how to build/transfer* its image.
- Port/env-var/model reference tables → `home-infra-config-reference`.
- Whether a change is allowed at all → `home-infra-change-control`.

## Provenance and maintenance

- Facts verified 2026-07-02 against repo state (commit 6cbd3a1 + uncommitted MiniRAG-migration worktree changes) and live containers observed via SSH 2026-07-02 (registry, watchtower, minirag not running; lightrag-trading on :9622 present).
- Sources: `compose/nas/docker-compose.yml`, `compose/desktop/docker-compose.yml`, `compose/desktop/embed-stack/docker-compose.yml`, `vault-indexer/Dockerfile`, `vault-indexer/crontab`, `mcp/lightrag/Dockerfile` + README, `mcp/vision/Dockerfile`, `docs/specs/minirag-migration.md` (Prerequisites + Step 1), `docs/specs/lightrag-vault-indexer.md` (Dockerfile/build section), `.env.example` files. Service-user and SSH-identity rules: project owner standing instructions.
- Re-verification one-liners:
  - Deploy paths / network / watchtower schedule: `grep -n "Deploy path\|ai_ai-net\|--schedule" compose/*/docker-compose.yml`
  - lightrag-mcp package name: `grep lightrag-mcp mcp/lightrag/Dockerfile`
  - Registry running? `ssh -i ~/.ssh/agent_ed25519 agent@10.0.0.250 'sudo /usr/local/bin/docker ps --format "{{.Names}} {{.Ports}}" | grep -E "registry|watchtower|minirag|9622"'`
  - Mac insecure-registry config: `docker info 2>/dev/null | grep -A3 -i insecure`
  - Model list drift: `grep -rn "MODEL=" compose/ docs/specs/minirag-migration.md`
