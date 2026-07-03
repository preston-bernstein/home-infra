---
name: home-infra-config-reference
description: >
  Authoritative lookup table for every port, model, env var, command flag, hardcoded
  constant, and secret location in Preston's home-infra stack (NAS 10.0.0.250 +
  desktop 10.0.0.243 + HA Pi 10.0.0.5). Load when you need to answer "what port is X
  on", "which model does Y use", "what env vars does Z take", "where does this secret
  live", "what's the default value of", "how do I add a new service/port/MCP",
  "rotate a key/secret", or when
  writing/reviewing any compose file, .env file, or service config for this stack.
  Also the home for the Ollama broker lane table (11435/11436/11437/11438).
---

# home-infra Config Reference

Every configuration axis of the Personal AI Stack, extracted from the actual repo files
(`/Users/prestonbernstein/dev/home-infra`) on **2026-07-02**. Repo compose is INTENT;
live machine compose is RUNTIME TRUTH (sync contract — ASSUMPTION, see
`home-infra-architecture-contract`). Tables here flag where the two diverge.

**This skill decays fastest of the set.** Before trusting any volatile row, run the
re-verification one-liner in section 7.

Jargon used below:
- **broker** = ollama-resource-broker (repo `~/dev/ollama-resource-broker` on the desktop). Arbitrates the shared GPU; returns 503 when busy — clients must retry.
- **RAG Engine** = the LightRAG (today) / MiniRAG (migration target) container on the NAS. API details live in `rag-stack-reference`.
- **repo compose** = files under `compose/` in this repo. Deploy paths: NAS → `/volume1/docker/ai/docker-compose.yml`; desktop → `/opt/docker/librechat-stack/` (the header comment in `compose/desktop/docker-compose.yml` saying `/var/data/docker` is stale); embed-stack → `/opt/docker/embed-stack/`.

---

## 1. Ports (all machines) — as of 2026-07-02

Status legend:
- `[repo+live]` — in repo compose AND observed running via SSH 2026-07-02.
- `[repo-only]` — in repo compose, NOT observed running.
- `[live-only]` — observed running, in NO file of this repo (owned elsewhere or undocumented).

### NAS — house-of-light, 10.0.0.250

| Port | Service | Status | Notes |
|---|---|---|---|
| 9621 | lightrag (RAG Engine) | [repo+live] | `ghcr.io/hkuds/lightrag:latest`, maps 9621→9621 |
| 9622 | minirag | [repo-only, uncommitted] | Worktree compose maps `9622:9721` (MiniRAG internal port is **9721**). NOT running live. **CONFLICT — see next row.** |
| 9622 | lightrag-trading | [live-only] | **UNDOCUMENTED live reality**: maps 9622→9621, up on the NAS, appears in NO repo file. Repo assigns :9622 to minirag. Do NOT touch :9622 or resolve the conflict — confirm ownership with Preston first. Flagged in the drift register (`home-infra-architecture-contract`). |
| 5000 | registry (Docker registry:2) | [repo-only, uncommitted] | In the UNCOMMITTED migration worktree compose (not in any commit); NOT running live 2026-07-02. Prerequisite for the MiniRAG migration (`minirag-migration-campaign`). |
| 3002 | lightrag-mcp | [repo+live] | MCP endpoint path `/mcp`, streamable-http, stateless. Image also `EXPOSE 3001` (stale Dockerfile default — unused; compose flags win). |
| — | vault-indexer | [repo+live] | No published port; cron container, talks to lightrag over `ai-net` docker network (`ai_ai-net`). |
| — | tailscale-nas | [repo+live] | `network_mode: host`, hostname `house-of-light` |
| — | watchtower | [repo, not observed live] | Schedule `"0 0 4 * * *"` (4am — same hour as the indexer cron; coincidence, noted in drift register) |
| 80/443 | nginx (TLS for `house-of-light.tail04ee59.ts.net`) | [repo config-only] | `compose/nas/nginx.conf` exists but NO nginx service is in the repo compose; `/mcp/*` location blocks are commented out. How/whether nginx runs live is UNVERIFIED. |
| 2283 | immich | [live-only] | Family photo server, other project — not this repo |
| 3101 | financial-pipeline MCP | [live-only] | Other repo |
| 8282 | fashion-monitor ntfy | [live-only] | Other repo (its mcp-server + dashboard containers were crash-looping 2026-07-02) |

### Desktop — multimedia, 10.0.0.243

| Port | Service | Status | Notes |
|---|---|---|---|
| 3080 | librechat | [repo+live] | `network_mode: host`; port comes from `PORT=3080` in `/opt/docker/librechat-stack/.env` |
| 27017 | mongodb | [repo+live] | LibreChat backing store |
| 3003 | vision-mcp | [repo+live] | host network; MCP path `/mcp` |
| 3004 | proton-email-mcp | [repo+live] | host network; MCP path `/mcp`; source built on-machine at `/opt/docker/librechat-stack/proton-email-mcp` (NOT in this repo) |
| 1143 / 1025 | protonmail-bridge IMAP / SMTP | [live-only container; ports referenced by repo env] | Bridge container is not in repo compose; proton-email-mcp reaches it on localhost |
| 7997 | infinity-siglip | [repo+live] | Bound to **127.0.0.1 only**. Never call directly — go via broker lane :11438 |
| 11434 | raw Ollama (host process) | [live, FORBIDDEN] | Never point anything here — broker lanes only (project owner standing instruction; enforced repo-wide by commit f2565b4) |
| 11435–11438 | ollama-resource-broker lanes (host process) | [live; managed in `~/dev/ollama-resource-broker`, not this repo] | See section 2 |
| various | caddy, authentik (server/worker/postgres/redis), cloudflared, tdarr | [live-only] | Other stacks; ports not tracked here (UNVERIFIED) |

### HA Pi — 10.0.0.5

| Port | Service | Status | Notes |
|---|---|---|---|
| 8123 | Home Assistant OS (built-in MCP) | [live; not managed by this repo] | Referenced by the commented-out `/mcp/ha` nginx location in `compose/nas/nginx.conf` |

---

## 2. Ollama broker lanes (non-negotiable invariant)

ALL Ollama traffic goes through the broker on the desktop. **Never `:11434`.** The GPU
is shared with gaming/Plex; the broker 503s when busy and clients must retry (see the
wiki-ingest retry ladder in section 4.9). Rationale and rule enforcement:
`home-infra-change-control`.

| Lane | URL | Use |
|---|---|---|
| Interactive | `http://10.0.0.243:11435` | Chat, real-time: LibreChat endpoint, RAG Engine `LLM_BINDING_HOST`, vision-mcp, wiki-ingest |
| Batch | `http://10.0.0.243:11436` | Embeddings, short batch: RAG Engine `EMBEDDING_BINDING_HOST` |
| Durable jobs | `http://10.0.0.243:11437/jobs` | Long batch, vision scoring (job-queue API) |
| Embed (SigLIP) | `http://10.0.0.243:11438` | Fronts infinity-siglip :7997; rewrites `/embeddings` → `/embeddings_image` (the unified route tokenizes `data:` URIs as text — wrong embeddings) |

Known exception that proves the rule: `mcp/vision/server.py` has code default
`OLLAMA_HOST=http://localhost:11434`, but compose overrides to `:11435`. The compose
value is the contract; the code default is a trap if you run the script bare.

---

## 3. Models

### Currently live (as of 2026-07-02)

| Model | Role | Configured in |
|---|---|---|
| `llama3.2:3b` | RAG Engine LLM (entity/relation extraction, query) | `compose/nas/docker-compose.yml` → lightrag `LLM_MODEL` |
| `mxbai-embed-large` | RAG Engine embeddings (1024-dim — see ADR 0001) | `compose/nas/docker-compose.yml` → lightrag `EMBEDDING_MODEL` |
| `llava:13b` | Vision (describe_image MCP tool) | `compose/desktop/docker-compose.yml` → vision-mcp `VISION_MODEL` (same default in `mcp/vision/server.py`) |
| `qwen3:8b` | LLM Wiki ingest + semantic lint | `wiki-ingest.py` `INGEST_MODEL` default |
| `llama3.2:3b` | LibreChat titleModel | `compose/desktop/librechat.yaml` |
| `google/siglip-so400m-patch14-384` | Image embeddings (estate-scraper corpus) | `compose/desktop/embed-stack/docker-compose.yml` → infinity-siglip `--model-id` |

### Migration target (NOT live — uncommitted worktree, ADRs 0010/0011)

| Model | Role | Configured in |
|---|---|---|
| `qwen2.5:14b` | MiniRAG LLM (replaces llama3.2:3b; 8b-class JSON extraction fails ~35% per ADR 0010) | uncommitted `compose/nas/docker-compose.yml` → minirag `LLM_MODEL` |
| `bge-m3` | MiniRAG embeddings (replaces mxbai; 8192-token context vs mxbai degrading past ~1k — ADR 0011) | uncommitted `compose/nas/docker-compose.yml` → minirag `EMBEDDING_MODEL` |

Both must be pulled on the desktop (`ollama pull qwen2.5:14b && ollama pull bge-m3`)
before MiniRAG deploy — see `minirag-migration-campaign`.

Stale model references you will encounter (do NOT copy them into new config):
`docs/specs/ai-stack.md` (llama3.1:8b, raw :11434) is badly stale; `librechat.yaml`
`models.default` lists llama3.1:8b / llama3.1:70b / llama3.2:3b / llava:13b — that is a
UI menu with `fetch: true`, not a statement of what is pulled or fits in VRAM.

---

## 4. Per-service configuration

"Where set" is the file in THIS repo; deployed copies live at the deploy paths in the
preamble. **Production** = load-bearing today. **Experimental** = uncommitted /
migration / not running.

### 4.1 lightrag (NAS :9621) — production

Set in `compose/nas/docker-compose.yml`; secret interpolated from `/volume1/docker/ai/.env` on the NAS.

| Env var | Value | What it does |
|---|---|---|
| `LLM_BINDING` | `ollama` | LLM backend type |
| `LLM_MODEL` | `llama3.2:3b` | Extraction/query LLM |
| `LLM_BINDING_HOST` | `http://10.0.0.243:11435` | Broker interactive lane |
| `EMBEDDING_BINDING` | `ollama` | Embedding backend type |
| `EMBEDDING_MODEL` | `mxbai-embed-large` | Embedding model (changing it mid-index breaks everything — dim mismatch, ADR 0001) |
| `EMBEDDING_BINDING_HOST` | `http://10.0.0.243:11436` | Broker batch lane |
| `WORKING_DIR` | `/app/data/rag_storage` | Index storage inside container (host: `/volume1/docker/ai/lightrag`) |
| `LIGHTRAG_API_KEY` | `${LIGHTRAG_API_KEY}` | API auth (clients send `X-API-Key` header) |

Volumes: `/volume1/docker/ai/lightrag:/app/data`, `/volume1/obsidian-vault:/vault:ro`.

### 4.2 minirag (NAS :9622) — experimental (uncommitted, not running)

Set in the uncommitted worktree `compose/nas/docker-compose.yml`. Image
`10.0.0.250:5000/minirag:latest` — must be built from source (no GHCR image; Dockerfile
needs a dummy `touch .env`) and pushed to the NAS registry, which is also not running
yet. Same env var names as lightrag (verified against MiniRAG source per
`docs/specs/minirag-migration.md`), differing values:

| Env var | Value |
|---|---|
| `LLM_MODEL` | `qwen2.5:14b` |
| `EMBEDDING_MODEL` | `bge-m3` |
| everything else | identical to lightrag (both lanes, `WORKING_DIR`, `LIGHTRAG_API_KEY`) |

Port mapping `9622:9721` (internal port 9721, not 9621). Volume
`/volume1/docker/ai/minirag:/app/data`. Deployment is gated by the :9622 conflict —
see `minirag-migration-campaign`.

### 4.3 vault-indexer (NAS, no port) — production

Nightly incremental Obsidian→RAG indexer. Env vars read in `vault-indexer/indexer.py`;
compose sets the first three.

| Env var | Code default | Compose value | What it does |
|---|---|---|---|
| `LIGHTRAG_URL` | `http://lightrag:9621` | `http://lightrag:9621` | RAG Engine base URL (docker-network hostname) |
| `LIGHTRAG_API_KEY` | `changeme` | `${LIGHTRAG_API_KEY}` | **Code default is `changeme` — the compose value is mandatory.** (`changeme` was once committed live — see `home-infra-failure-archaeology`) |
| `VAULT_PATH` | `/vault` | `/vault` | Vault mount (host `/volume1/obsidian-vault`, ro) |
| `STATE_DIR` | `/state` | (not set — default) | Directory for state + log (host `/volume1/docker/ai/vault-indexer`) |
| `STATE_FILE` | `${STATE_DIR}/hashes.json` | (not set — default) | Hash-state JSON path. **Override semantics:** setting `STATE_FILE` repoints ONLY the hash state — the log stays at `${STATE_DIR}/indexer.log`. This is how the migration runs a parallel index (`STATE_FILE=/state/hashes-minirag.json` + `LIGHTRAG_URL` → MiniRAG) without touching the production `hashes.json`. Uncommitted-worktree feature. |

Hardcoded constants in `indexer.py` — **changing any of these requires editing the file
and rebuilding the `vault-indexer:latest` image** (see `home-infra-build-and-deploy`);
they are NOT env-tunable:

| Constant | Value | What it does |
|---|---|---|
| `BATCH_SIZE` | `10` | Files per `/documents/texts` POST |
| `BATCH_SLEEP_S` | `2` | Sleep between batches |
| `TRACK_TIMEOUT_S` | `60` | Max wait polling `track_status` per batch (partial results saved on timeout) |
| `ARCHIVE_DAYS` | `30` | Two-stage delete: files missing from vault are archived, auto-deleted after 30 days (ADR 0003) |
| `LOG_MAX_BYTES` | `1048576` (1 MiB) | Rotating log cap, `backupCount=1` |
| `EXCLUDE_DIRS` | `{.agents, .claude, .obsidian, _raw}` | Top-level vault dirs skipped (`_raw` added in uncommitted worktree — ADR 0012) |

CLI: no args = index run; `--cleanup` = interactive archived-doc review/delete
(operations: `home-infra-run-and-operate`).

Cron (in-container, `vault-indexer/crontab`): `0 4 * * *` — 4am. Spec prose still says
2am in places; the crontab is truth (drift register item).

### 4.4 lightrag-mcp (NAS :3002) — production

No env vars — configured entirely by **command flags** in `compose/nas/docker-compose.yml`:

```
lightrag-mcp --host lightrag --port 9621 --api-key ${LIGHTRAG_API_KEY}
  --mcp-transport streamable-http --mcp-host 0.0.0.0 --mcp-port 3002
  --mcp-streamable-http-path /mcp --mcp-stateless-http
```

Caveats: the API key is on the command line (visible via `docker inspect`); the image's
Dockerfile CMD defaults to port **3001** and its README says package
`daniel-lightrag-mcp` — both stale; the Dockerfile actually pip-installs `lightrag-mcp`
and compose's :3002 flags override the CMD. Compose is truth.

### 4.5 librechat (desktop :3080) — production

Env via `env_file: .env` → `/opt/docker/librechat-stack/.env` (template
`compose/desktop/.env.example`):

| Env var | Example/default | What it does |
|---|---|---|
| `MONGO_URI` | `mongodb://localhost:27017/LibreChat` | Mongo connection |
| `HOST` / `PORT` | `0.0.0.0` / `3080` | Bind address/port (host network) |
| `ALLOW_REGISTRATION` | `true` | Open signup toggle |
| `JWT_SECRET` / `JWT_REFRESH_SECRET` | secret | Session tokens — `openssl rand -hex 32` |
| `OLLAMA_BASE_URL` | `http://localhost:11435` | Broker interactive lane |
| `PROTON_USERNAME` / `PROTON_PASSWORD` | secret | Consumed by the proton-email-mcp service via compose interpolation (same `.env`) |
| `ANTHROPIC_API_KEY` | commented out | Optional; only set deliberately |

File config `compose/desktop/librechat.yaml` (mounted ro at `/app/librechat.yaml`):
- Ollama endpoint `baseURL: http://localhost:11435/v1`, `apiKey: "ollama"`, `titleModel: llama3.2:3b`, `fetch: true`.
- `mcpSettings.allowedDomains` — **REQUIRED for every private-LAN MCP URL** (SSRF protection; LibreChat silently blocks otherwise). Current entries: `http://10.0.0.250:3002`, `http://localhost:3003`, `http://localhost:3004`.
- `mcpServers`: lightrag `http://10.0.0.250:3002/mcp`, vision `http://localhost:3003/mcp`, proton-email `http://localhost:3004/mcp` — all `streamable-http`.

### 4.6 vision-mcp (desktop :3003) — production

Env read in `mcp/vision/server.py`, set in `compose/desktop/docker-compose.yml`:

| Env var | Code default | Compose value | What it does |
|---|---|---|---|
| `OLLAMA_HOST` | `http://localhost:11434` | `http://localhost:11435` | **Code default violates the broker rule — compose override is the contract** |
| `VISION_MODEL` | `llava:13b` | `llava:13b` | Model for `describe_image` (`/api/generate`) |
| `LIBRECHAT_HOST` | `http://localhost:3080` | `http://localhost:3080` | Resolves `/api/files/...` image paths |
| `MCP_PORT` | `3003` | `3003` | streamable-http on `0.0.0.0`, path `/mcp` |

### 4.7 proton-email-mcp (desktop :3004) — production

Source lives on the desktop at `/opt/docker/librechat-stack/proton-email-mcp` (not in
this repo) — env names below are from compose only; code defaults UNVERIFIED.

| Env var | Compose value | What it does |
|---|---|---|
| `MCP_TRANSPORT` / `MCP_HOST` / `MCP_PORT` | `streamable-http` / `0.0.0.0` / `3004` | MCP server binding |
| `PROTON_USERNAME` | `${PROTON_USERNAME}` | Proton account (secret via desktop `.env`) |
| `PROTON_PASSWORD` | `${PROTON_PASSWORD}` | **Bridge app password, NOT the Proton account password** (from the bridge CLI `info` command) |
| `PROTON_BRIDGE_HOST` | `localhost` | protonmail-bridge container (host network) |
| `PROTON_BRIDGE_IMAP_PORT` / `PROTON_BRIDGE_SMTP_PORT` | `1143` / `1025` | Bridge IMAP/SMTP |

### 4.8 infinity-siglip (desktop, loopback :7997) — production

`compose/desktop/embed-stack/docker-compose.yml`. Deploy `/opt/docker/embed-stack/`,
owner: `embed` service user (all desktop services run under dedicated nologin service
users — project owner standing instruction).

| Setting | Value | Why |
|---|---|---|
| `cpus` | `8.0` | Caps embed batches on the shared 32-core box |
| `OMP_NUM_THREADS` / `MKL_NUM_THREADS` / `OPENBLAS_NUM_THREADS` | `8` | Stop torch/BLAS oversubscribing past the cpu cap |
| `HF_HOME` | `/cache` (host `/opt/docker/embed-stack/hf-cache`) | Model cache |
| `DO_NOT_TRACK` | `1` | Telemetry off |
| command | `v2 --model-id=google/siglip-so400m-patch14-384 --served-model-name=siglip-so400m-patch14-384 --engine=torch --device=cpu --host=127.0.0.1 --port=7997` | CPU on purpose: Infinity's ROCm image supports MI200/MI300 only, not RDNA4/gfx1201 |

Reached ONLY via broker lane :11438 (path rewrite — section 2).

### 4.9 wiki-ingest.py (runs on the MACBOOK) — experimental (untracked, ADR 0012)

Plain script at repo root — no container, no rebuild: edit the file to change constants.

| Env var | Default | What it does |
|---|---|---|
| `VAULT_PATH` | `~/dev/Obsidian/Home Network Vault` | LOCAL MacBook vault clone (not the NAS mount) |
| `OLLAMA_URL` | `http://10.0.0.243:11435` | Broker interactive lane (CONTEXT.md says Lint uses :11436 — the code uses :11435 for everything; drift register item) |
| `INGEST_MODEL` | `qwen3:8b` | Ingest + semantic-lint model |
| `BATCH_SIZE` | `1` | `1` = incremental (one capture per LLM call, full merge context — the intended mode); `>1` = bulk mode, weaker merging |

Constants in the file:

| Constant | Value | What it does |
|---|---|---|
| `MAX_RETRIES` / `RETRY_DELAYS` | `5` / `[10, 30, 60, 120, 180]` s | Retry ladder on broker 503 and request errors |
| `RELEVANT_PAGE_CHAR_BUDGET` | `10_000` | Char budget of existing wiki pages passed as merge context |
| `SEMANTIC_LINT_PAGE_BATCH` | `8` | Pages per LLM call during `--semantic-lint` (each truncated to 1500 chars) |

KNOWN BUG: `--semantic-lint` alone also runs a full ingest — lint-only is
`--lint --semantic-lint` together; see `home-infra-failure-archaeology` F10.
Operations: `home-infra-run-and-operate`.

---

## 5. Secrets map (names + locations ONLY — never copy values anywhere)

Repo rule: real values live only in `.env` ON the machines; the repo commits
`.env.example` templates. Generation for hex secrets: `openssl rand -hex 32`.

| Secret | Lives at | Consumed by | Rotation touchpoints |
|---|---|---|---|
| `LIGHTRAG_API_KEY` | `/volume1/docker/ai/.env` (NAS) | lightrag + minirag + vault-indexer env; lightrag-mcp **command line** (compose interpolation — visible in `docker inspect`) | Edit NAS `.env`, then recreate lightrag, vault-indexer, lightrag-mcp (and minirag once live): `docker compose up -d --force-recreate <services>`. No client outside the NAS holds it (LibreChat talks to :3002/mcp, which holds the key). |
| `TS_AUTHKEY` | `/volume1/docker/ai/.env` (NAS) | tailscale-nas (one-time auth) | Leave blank after first auth — state persists in `/volume1/docker/tailscale` |
| `JWT_SECRET`, `JWT_REFRESH_SECRET` | `/opt/docker/librechat-stack/.env` (desktop) | librechat | Rotate → restart librechat; invalidates sessions |
| `PROTON_USERNAME`, `PROTON_PASSWORD` | `/opt/docker/librechat-stack/.env` (desktop) | proton-email-mcp (via compose interpolation) | Bridge app password from the protonmail-bridge CLI (`info`), NOT the account password; rotate → recreate proton-email-mcp |
| `ANTHROPIC_API_KEY` | `/opt/docker/librechat-stack/.env` (desktop, optional/commented) | librechat | Set only deliberately |
| `SONARR_KEY` … `OVERSEERR_KEY` | root `.env` next to `media-ip-migrate.sh` (historic one-off; template root `.env.example`) | media-ip-migrate.sh | Historic — the secrets-in-repo incident lived here (commit 3ec836f fixed; story in `home-infra-failure-archaeology`) |

Rotation touchpoints are live-machine changes — apply via `home-infra-change-control` (Class C).

---

## 6. How to add a new config axis / new service+port

The repeatable pattern (ADR 0007: one Docker service per MCP, own port, nginx path —
"the same operation every time"). All behavior-changing steps go through
`home-infra-change-control` first.

1. **Pick the port.** Check section 1 AND live reality (`docker ps` on both machines —
   :9622 taught us the repo doesn't know everything). MCPs so far: 3002–3004; RAG
   engines: 9621+.
2. **Add the compose service** in the right repo file (`compose/nas/` or
   `compose/desktop/`), repo-first (sync contract). Any Ollama access uses a broker
   lane URL from section 2 — never :11434. Desktop services get a dedicated nologin
   service user.
3. **Secrets:** new secret → add `NAME=REPLACE_ME` + generation comment to the matching
   `.env.example`, real value only in the on-machine `.env`, add a row to section 5.
4. **nginx location** (`compose/nas/nginx.conf`): the ADR 0007 `/mcp/<name>` pattern is
   currently COMMENTED OUT — clients hit ports directly. Follow current practice
   (direct port) unless you're deliberately activating the nginx pattern.
5. **If it's an MCP for LibreChat** (`compose/desktop/librechat.yaml`): add the base
   URL to `mcpSettings.allowedDomains` (mandatory — silently blocked otherwise) AND an
   entry under `mcpServers` with `type: streamable-http`, path `/mcp`.
6. **Deploy by hand** (this repo deploys nothing automatically): copy compose to the
   deploy path, `docker compose up -d <service>` — details in
   `home-infra-build-and-deploy`.
7. **Register it here**: port row in section 1, env table in section 4, secret row in
   section 5, re-verification line in section 7. Update the drift register in
   `home-infra-architecture-contract` if repo and live diverge even briefly.

New env var on an EXISTING service: same steps minus port; remember `docker compose up
-d --force-recreate <service>` — `restart` does not re-read compose env.

---

## 7. Re-verification (run before trusting a table)

Repo greps (run from `/Users/prestonbernstein/dev/home-infra`):

| Table | Command |
|---|---|
| Ports in repo compose | `grep -rn -E '"[0-9]+:[0-9]+"|--port|MCP_PORT|PORT=' compose/ mcp/` |
| Broker lane usage (and :11434 violations) | `grep -rn -E '1143[4-8]' compose/ mcp/ vault-indexer/ wiki-ingest.py` — any `:11434` outside a code-default-with-compose-override is a violation |
| Models | `grep -rn -E 'LLM_MODEL|EMBEDDING_MODEL|VISION_MODEL|INGEST_MODEL|model-id|titleModel' compose/ mcp/ wiki-ingest.py` |
| lightrag/minirag env | `grep -n -A14 'lightrag:\|minirag:' compose/nas/docker-compose.yml` |
| vault-indexer env + constants | `grep -n -E 'os.environ|^[A-Z_]+ =' vault-indexer/indexer.py` and `cat vault-indexer/crontab` |
| lightrag-mcp flags | `grep -n -A20 'lightrag-mcp:' compose/nas/docker-compose.yml` |
| librechat MCP/domains | `cat compose/desktop/librechat.yaml` |
| wiki-ingest config | `sed -n '26,48p' wiki-ingest.py` |
| Secret templates | `cat .env.example compose/nas/.env.example compose/desktop/.env.example` (dotfiles — plain `ls` hides them; use `ls -la`) |
| Uncommitted vs committed | `git status --short && git diff compose/nas/docker-compose.yml vault-indexer/` |

Live checks (read-only SSH; `agent@`, never `preston@` — access pattern in
`home-infra-run-and-operate`):

```bash
# NAS — note: docker is NOT in sudo PATH on Synology
ssh -i ~/.ssh/agent_ed25519 agent@10.0.0.250 'sudo /usr/local/bin/docker ps --format "{{.Names}}\t{{.Ports}}\t{{.Status}}"'

# Desktop
ssh -i ~/.ssh/agent_ed25519 agent@10.0.0.243 'docker ps --format "{{.Names}}\t{{.Ports}}\t{{.Status}}"'

# Broker lanes answer? (root 404 on :11435 is NORMAL — not a failure)
for p in 11435 11436 11437 11438; do curl -s -o /dev/null -w "$p %{http_code}\n" --max-time 3 http://10.0.0.243:$p/; done

# Deployed env-var truth for one container (never print secret VALUES into logs/chat)
ssh -i ~/.ssh/agent_ed25519 agent@10.0.0.250 'sudo /usr/local/bin/docker inspect lightrag --format "{{range .Config.Env}}{{println .}}{{end}}" | grep -v -i key'
```

Any repo-vs-live mismatch you find: record it in the drift register
(`home-infra-architecture-contract`), don't silently "fix" either side.

---

## When NOT to use this skill

- **Why the stack is shaped this way / RAG Engine API endpoints, auth, query modes / graph-RAG and embedding theory / MCP transport theory** → `rag-stack-reference`.
- **Actually operating things** (SSH sessions, manual indexer runs, reading logs, running wiki-ingest) → `home-infra-run-and-operate`.
- **Building/pushing images and deploying compose changes** → `home-infra-build-and-deploy`.
- **Executing the MiniRAG migration** → `minirag-migration-campaign`.
- **Whether a change is allowed at all** → `home-infra-change-control`.
- **Authoritative drift register / invariants** → `home-infra-architecture-contract` (this file only flags drift it collides with).
- **Incident back-stories** → `home-infra-failure-archaeology`.

## Provenance and maintenance

- Facts verified 2026-07-02 against repo state (commit 6cbd3a1 + uncommitted MiniRAG-migration worktree changes: modified `compose/nas/docker-compose.yml`, `vault-indexer/indexer.py`, `vault-indexer/crontab`; untracked `wiki-ingest.py`, ADRs 0010–0012, `docs/specs/minirag-migration.md`) and live containers observed via SSH 2026-07-02 (2026-07-02 authoring-pass observations; not re-observed since).
- Sources read directly: `compose/nas/docker-compose.yml`, `compose/nas/nginx.conf`, `compose/nas/.env.example`, `compose/desktop/docker-compose.yml`, `compose/desktop/.env.example`, `compose/desktop/librechat.yaml`, `compose/desktop/embed-stack/docker-compose.yml`, root `.env.example`, `vault-indexer/indexer.py`, `vault-indexer/crontab`, `vault-indexer/Dockerfile`, `wiki-ingest.py`, `mcp/vision/server.py`, `mcp/lightrag/Dockerfile`, `docs/adr/0007-one-service-per-mcp-nginx.md`, `docs/specs/minirag-migration.md`.
- Items labeled UNVERIFIED above: nginx live deployment mechanism on the NAS; proton-email-mcp code defaults (source off-repo); ports of caddy/authentik/cloudflared/tdarr. The repo↔live sync contract is a labeled ASSUMPTION.
- Re-verification: run the section 7 one-liners; every table row is covered by one of them. This skill decays fastest — re-run section 7 whenever the answer matters, and always after any compose change or migration step.
- Unwritten rules cited (broker-only, service users, agent SSH identity, secrets never in repo): source "project owner standing instructions".
