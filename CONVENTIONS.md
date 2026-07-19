# Home-lab conventions (cross-cutting)

The rules that apply across **all** of Preston's home-lab repos — not any single project.
Per-repo `CLAUDE.md` files should link here rather than each restating these, so there's one
source of truth and less drift. Project-specific rules stay in that project's `CLAUDE.md`;
this file is only for things true everywhere.

Authoritative for a given rule = wherever the "deeper" pointer sends you; this file is the
index + the short version.

## 1. Dedicated service users — never `preston`

Every service deployed to the desktop or NAS runs under its **own dedicated nologin service
user** (e.g. `algo-factory`, `scraper-egress`, `finpipe`, media user), never `preston` and
never `root` for the app itself. This bounds blast radius: a compromised service can't reach
another's data or the host.

Corollary (learned from the scraper-egress build): granting a service user the `docker` group
is **host-root-equivalent** and defeats the point — use a **narrow `/etc/sudoers.d/<svc>`
grant** scoped to the exact command instead.

## 2. Mac is dev/edit-only; execution happens on the desktop

For any repo with a desktop deployment, the Mac checkout is for **editing and committing
only**. Scripts, backtests, DB reads/writes, ingestion, deploys, and anything touching live
data run **on the desktop** as the service user:

```bash
ssh desktop-agent
sudo -u <service-user> <command>
```

A Mac checkout often has its own disposable `data/` that will silently produce
plausible-but-wrong output instead of erroring — so **the canonical live data is the desktop
copy**, and scripts must take explicit paths to it (never rely on a checkout-relative default).
Deeper: each repo's own `CLAUDE.md`.

## 3. SSH + sudo to the home-lab boxes

Always the `agent` user with `~/.ssh/agent_ed25519`, never `preston@` unless explicitly asked.
`ssh desktop-agent` (10.0.0.243), `ssh nas-agent` (10.0.0.250). Both have `NOPASSWD: ALL` sudo
for `agent` — use `sudo` freely.

## 4. Ollama only through the broker — never raw `:11434`

All local inference goes through `~/dev/ollama-resource-broker` on the desktop (the GPU is
shared with gaming/Plex; the broker arbitrates). Use the broker ports, never raw Ollama:
- `10.0.0.243:11435` — interactive (chat, real-time, `llm` CLI)
- `10.0.0.243:11436` — batch (embeddings, short vision)
- `10.0.0.243:11437/jobs` — durable jobs (long batch, vision scoring)

Any code/config/tool that calls Ollama must use a broker URL.

## 5. Secrets: never committed, even in private repos

Real secrets never land in git — repos get flipped public/forked/leaked. `.env` is
git-ignored, only `.env.example` (empty placeholders) is tracked. Live credentials are entered
**on the desktop only** (never drafted on the Mac — Time Machine/iCloud/editor-swap exposure),
never echoed on a command line. A `check_clean.sh`-style gate that blocks tracked `.env` (at
any depth) and credential-shaped content before push is the pattern.

## 6. Commit attribution — Preston only

Commits and PRs are authored to **Preston Bernstein <contact@prestonbernstein.com>**. Never a
`Co-Authored-By: Claude` trailer, never AI/Claude/Anthropic mentioned in commit or PR text.

## 7. Scraping: isolated egress + logged-out/slow/stop-on-notice

Scraping public data with anti-bot handling is accepted for private, non-redistributed use
(don't push "use the paid API / respect ToS" abstention). The discipline that keeps it both
safe and lawful:
- **Logged-out + public-only** (no fake accounts on gated content; no ToS contract forms).
- **Low, steady rate** (defeats the "server impairment" legal theory; avoids the ban).
- **Isolated egress** — scraper traffic exits through the **shared egress gateway**
  (`compose/desktop/scraper-egress/`, ADR 0014), NEVER the desktop's real IP that the Kalshi
  executor / financial pipeline share. Attach via `network_mode: service:egress-gateway`.
- **Cease-and-desist = coded hard stop** — evading a block after explicit notice is the one
  CFAA tripwire; halt, never auto-rotate to evade.

Deeper: vault `Development/Research/insulated-scraping-architecture.md`.

## 8. Shared services vs shared libraries (where cross-cutting things live)

- **Shared *services*** (deployed once, consumed at runtime via a network/API contract): the
  egress gateway, the ollama broker, llm-gateway, Pi-hole, RAG. **Home: `home-infra`.
  Mechanism: attach, don't import/copy.**
- **Shared *libraries*** (imported as code — e.g. a Playwright-stealth / rate-governor /
  stop-on-C&D scraper toolkit): **imported and versioned**, home in a dedicated lib repo — see
  ADR 0015. Don't copy-paste cross-project code between product repos.

Product repos own their domain logic and *attach to* / *import* the shared layers above.
Polyrepo is deliberate: scoped per-repo context (a focused repo + its `CLAUDE.md`) beats one
sprawling tree.

## 9. ntfy alerts: JSON body, never header-based publish

TypeScript ntfy alerting posts a JSON body, not ntfy's header-based publish API — headers must
be ASCII-only, and emoji in a title throws `Cannot convert argument to a ByteString` on Node's
real `fetch`. `financial-pipeline`'s header-based version would hit this the moment a
non-ASCII title is passed (`X-Title`), and its `.catch(() => {})` — just as real today —
swallows every failure with zero logging across all 5 call sites. Don't copy either shape.

```typescript
interface NtfyPublishPayload {
  title: string; message: string; priority: 1 | 2 | 3 | 4 | 5;
  tags?: string[]; click?: string; attach?: string;
}

async function publish(ntfyUrl: string, topic: string, token: string | undefined, payload: NtfyPublishPayload): Promise<boolean> {
  const headers: Record<string, string> = { "Content-Type": "application/json" };
  if (token) headers["Authorization"] = `Bearer ${token}`;
  try {
    const res = await fetch(ntfyUrl, { method: "POST", headers, body: JSON.stringify({ topic, ...payload }) });
    if (!res.ok) console.error("ntfy publish failed", res.status); return res.ok;
  } catch (err) {
    console.error("ntfy publish threw", err); return false; // real file logs both branches via its own logger
  }
}
```

`priority` is `1 | 2 | 3 | 4 | 5` (ntfy's valid range); `click`/`attach` must be valid URLs, not
arbitrary strings. Documented here, not packaged — at ~15 lines it's too small for ADR-0015.
Deeper: `fashion-monitor/packages/core/src/alerts/ntfy.ts` (canonical, JSON-body),
`financial-pipeline/packages/adapter-utils/src/ntfy.ts` (header-based, avoid).

---

**Repos that should link here from their `CLAUDE.md`:** algo-factory, algo-corpus,
financial-pipeline, estate-scraper, resale-inventory, fashion-monitor, social-growth-bot,
media-scan-gate, and any new home-lab service. (Linked so far: algo-factory, algo-corpus.)
