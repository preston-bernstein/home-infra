# Personal AI Stack Spec

Full-stack personal AI assistant: web + mobile + CLI, local LLMs + Claude API, MCP tool use (home and external), RAG over the Obsidian vault. Frugal by default — Local Models run free, Cloud Model requires explicit selection and has a $0 hard cap until manually raised.

See [CONTEXT.md](../../CONTEXT.md) for terminology. See the vault `Network/AI Infrastructure.md` for deployed stack state and hardware details.

---

## Architecture

```
Clients
├── MacBook (prestons-macbook-pro)
│   ├── Claude Code CLI          — MCP-capable, Claude API
│   ├── aichat CLI               — MCP-capable, model-switchable (default: Ollama)
│   └── LibreChat (browser/PWA)  — via Tailscale → desktop :3080
│
├── iPhone
│   └── LibreChat PWA            — via Tailscale → https://multimedia.<tailnet>.ts.net
│
└── Desktop (multimedia, 10.0.0.243) — also a client for aichat CLI

Infrastructure
├── Desktop (10.0.0.243) — LibreChat stack
│   ├── LibreChat        :3080   ← Primary UI (web + PWA)
│   ├── MongoDB          :27017  ← LibreChat dep
│   ├── nginx            :443    ← TLS termination (tailscale cert)
│   └── Ollama           :11434  ← Local Models (localhost — zero hop)
│
└── NAS (house-of-light, 10.0.0.250) — services
    ├── LightRAG         :9621   ← RAG index
    ├── LightRAG MCP     :3001   ← Home MCP (SSE)
    ├── HA MCP           (HA Pi :8123, built-in)
    ├── fashion-monitor MCP :3002  ← Home MCP (future, owned by fashion-monitor repo)
    ├── financial-pipeline MCP :3003  ← Home MCP (future, owned by financial-pipeline repo)
    ├── nginx                   ← MCP reverse proxy (/mcp/lightrag, /mcp/fashion, etc.)
    ├── vault-indexer           ← nightly cron → LightRAG
    └── watchtower              ← nightly image updates

Remote access: Tailscale (all devices enrolled, subnet router on HA Pi)
```

---

## Models

| Model | Where | Use | Cost |
|---|---|---|---|
| `llama3.1:8b` | Ollama/desktop | Default chat + LightRAG graph extraction | Free |
| `llama3.2:3b` | Ollama/desktop | Fast lightweight chat | Free |
| `llama3.2-vision:11b` | Ollama/desktop | Image analysis | Free |
| `mxbai-embed-large` | Ollama/desktop | LightRAG embeddings (1024-dim) | Free |
| `claude-sonnet-4-6` | Anthropic API | Primary Cloud Model escalation | Billed |
| `claude-haiku-4-5` | Anthropic API | Optional cheap cloud escalation | Billed |

**Charge protection:** $0 monthly hard limit on Anthropic Console. Raise deliberately when needed. Cloud Models are available in all clients but non-functional until limit is raised.

---

## Vault Interaction Model

The vault is the source of truth. LightRAG is a derived read-only index. LibreChat agents query the vault via LightRAG MCP — they never write to it.

```
You write in Obsidian → Syncthing → NAS → nightly vault-indexer → LightRAG index
                                                                          ↓
                                                          LibreChat agent queries on demand
```

**v1 — Read-only:** Agents query, never write. Conversation insights you want to keep go back to Obsidian manually (or via Claude Code CLI with explicit direction).

**Future — Draft folder (v2):** Agent writes proposed notes to `Vault/Drafts/`. You review, approve, move into the vault. No autonomous writes to sensitive folders (Finances, Personal, etc.).

Direct LightRAG writes from LibreChat are explicitly avoided — they create drift that the nightly vault-indexer would clobber.

---

## Primary UI — LibreChat (Desktop)

Replaces Open WebUI (removed from NAS compose). See `compose/desktop/docker-compose.yml`.

### Endpoints configured in LibreChat
- Ollama: `http://localhost:11434` — all Local Models
- Anthropic: Claude Sonnet (primary), Haiku (optional) — $0 cap in effect
- Default endpoint: Ollama / `llama3.1:8b`

### Agents

| Agent | Model | MCP Tools |
|---|---|---|
| Vault Assistant | `llama3.1:8b` | LightRAG MCP |
| Home Assistant | `llama3.1:8b` | HA MCP |
| Research | `llama3.1:8b` | Brave Search MCP, fetch MCP |
| General | `llama3.1:8b` | (none — plain chat) |

### Image analysis
Upload image → select `llama3.2-vision:11b` → analyze. No special config beyond pulling the model.

### Video analysis (v1)
Manual: extract frames with `ffmpeg`, upload as images. No pipeline service yet.

### Remote access
- `tailscale cert` on desktop → cert for `multimedia.<tailnet>.ts.net`
- nginx on desktop: port 443, TLS termination, proxy to LibreChat :3080
- iPhone: open `https://multimedia.<tailnet>.ts.net` → Add to Home Screen → PWA

---

## CLI — aichat (MacBook + Desktop)

Install: `cargo install aichat` or via package manager.

Config (`~/.config/aichat/config.yaml`):
```yaml
model: ollama:llama3.1:8b   # default — never charges
```

Model selection per invocation:
```bash
aichat "question"                                    # Ollama default
aichat -m ollama:llama3.2:3b "quick question"       # fast local
aichat -m claude:claude-sonnet-4-6 "hard question"  # explicit cloud (charges)
```

MCP config: Home MCPs at `http://10.0.0.250/mcp/<name>` (SSE, works via Tailscale when remote). External MCPs as stdio (Brave Search, fetch) installed per machine.

Install on both MacBook and desktop.

---

## CLI — Claude Code (MacBook)

MCP config in `~/.claude/settings.json` — add Home MCPs as SSE endpoints once NAS nginx is wired. External MCPs as stdio.

---

## Home MCPs (NAS — SSE transport)

Each runs as its own Docker service. See `compose/nas/docker-compose.yml`. nginx on NAS routes:

```
http://10.0.0.250/mcp/lightrag   → lightrag-mcp :3001
http://10.0.0.250/mcp/ha         → (proxied to HA Pi :8123/mcp)
http://10.0.0.250/mcp/fashion    → fashion-monitor-mcp :3002  (future)
http://10.0.0.250/mcp/financial  → financial-pipeline-mcp :3003  (future)
```

**Pattern for adding a new Home MCP:**
1. Add compose service on NAS with SSE server on next available port
2. Add nginx location block in `compose/nas/nginx.conf`
3. Register URL in LibreChat Agent config and aichat agent config

**Note on project-owned MCPs:** fashion-monitor and financial-pipeline MCPs are built and maintained in their own repos. home-infra compose just references their images and assigns ports.

### LightRAG MCP
Package: `daniel-lightrag-mcp`. Needs SSE mode — verify transport support before wiring; may need a thin wrapper. See `mcp/lightrag/`.

### HA MCP
HAOS built-in MCP server. Enable in HA Settings → integrations. Expose via NAS nginx or direct Tailscale to HA Pi (10.0.0.5:8123).

---

## External MCPs (stdio — per client)

Install on MacBook and desktop:
```bash
npx @modelcontextprotocol/server-brave-search  # needs BRAVE_API_KEY
npx @modelcontextprotocol/server-fetch
```

Configure in aichat and Claude Code `~/.claude/settings.json` per machine.

---

## Security

- All Home MCPs: LAN-only + Tailscale. No public port forwarding.
- LibreChat: HTTPS via tailscale cert. No public exposure.
- Anthropic API key: stored in LibreChat env + aichat config. $0 hard cap on Console.
- LightRAG API key: rotate off `CHANGE_ME` before wiring any MCP to it.

---

## Build Sequence

### Phase 1 — Fix embedding + vault-indexer (unblocks RAG)
- [ ] `ollama pull mxbai-embed-large` on desktop
- [ ] Update LightRAG compose: `EMBEDDING_MODEL=mxbai-embed-large`, restart
- [ ] Write `vault-indexer/indexer.py` — see [lightrag-vault-indexer.md](lightrag-vault-indexer.md)
- [ ] Write `vault-indexer/Dockerfile`
- [ ] Build + deploy to NAS, run initial index manually

### Phase 2 — LibreChat on desktop (replaces Open WebUI)
- [ ] Remove open-webui from NAS compose
- [ ] Deploy `compose/desktop/docker-compose.yml` on desktop
- [ ] Configure Ollama + Anthropic endpoints ($0 cap set first on Console)
- [ ] `ollama pull llama3.2-vision:11b` on desktop
- [ ] Set up nginx + `tailscale cert` on desktop
- [ ] Test PWA on iPhone via Tailscale

### Phase 3 — MCP infrastructure
- [ ] Verify `daniel-lightrag-mcp` SSE transport; wire or wrap in `mcp/lightrag/`
- [ ] Deploy LightRAG MCP service on NAS :3001
- [ ] Deploy nginx on NAS for `/mcp/*` routing
- [ ] Enable HA MCP in HAOS, wire to nginx
- [ ] Register MCPs in LibreChat agents + aichat config
- [ ] Create agents: Vault Assistant, Home Assistant, Research, General

### Phase 4 — CLI
- [ ] Install + configure aichat on MacBook and desktop
- [ ] Add Home MCPs + external MCPs to Claude Code `~/.claude/settings.json`

### Phase 5 — Future
- [ ] fashion-monitor MCP (built in fashion-monitor repo, deployed NAS :3002)
- [ ] financial-pipeline MCP (built in financial-pipeline repo, deployed NAS :3003)
- [ ] Vault draft folder (v2 write-back pattern)
- [ ] Video pipeline (ffmpeg + faster-whisper MCP on desktop)
- [ ] Raise Claude API hard limit when ready

---

## ADRs

- [0004 — LibreChat over Open WebUI](../adr/0004-librechat-over-open-webui.md)
- [0005 — LibreChat + MongoDB on desktop](../adr/0005-librechat-mongodb-on-desktop.md)
- [0006 — SSE transport for Home MCPs](../adr/0006-sse-transport-for-home-mcps.md)
- [0007 — One service per MCP + nginx](../adr/0007-one-service-per-mcp-nginx.md)
