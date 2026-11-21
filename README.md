<div align="center">

# 🛡️ airlock

**A disposable, hardened Linux sandbox for running untrusted code and deploying
with throwaway CLI logins — without ever exposing your Mac's keys, files, or
secrets.**

</div>

---

Think of it as an airlock between sketchy code and your real machine: code goes
in, does its work, the container is destroyed on exit. Only the project folder
and a per-client home volume (or nothing at all, with `--ephemeral`) remain.

```bash
cd ~/some/cloned/oss-project
airlock run        # locked-down, throwaway shell — safe to run anything
```

---

## Table of contents
- [Why this matters](#why-this-matters)
- [When to use it (scenarios)](#when-to-use-it-scenarios)
- [Why use it even for your *own* code](#why-use-it-even-for-your-own-code)
- [Three modes](#three-modes)
- [Which mode? — use cases, rated by safety & cost](#which-mode--use-cases-rated-by-safety--cost)
- [Making it a habit — `airlock guard`](#making-it-a-habit--airlock-guard)
- [Disk space — why it filled up, and what keeps it clean now](#disk-space--why-it-filled-up-and-what-keeps-it-clean-now)
- [Setup (fresh / reset Mac)](#setup-fresh--reset-mac)
- [Quick start](#quick-start)
- [Commands](#commands)
- [Networking — the whitelist](#networking--the-whitelist)
- [Multiple terminals](#multiple-terminals)
- [Dev servers / ports](#dev-servers--ports)
- [Claude login & sessions](#claude-login--sessions)
- [Security model — and its limits](#security-model--and-its-limits)
- [Layout](#layout)
- [Copyright](#copyright)

---

## Why this matters

Modern software development means constantly running code you didn't write:
cloning open-source repos, `npm install`-ing hundreds of transitive
dependencies, trying out a tool from a random GitHub link. Any one of those can
contain a malicious **postinstall script** or a **compromised package** (this is
a real, common supply-chain attack).

On a normal Mac, that code runs as **you** — it can read `~/.ssh`, your cloud
credentials, browser tokens, `.env` files — and upload them anywhere. By the
time you notice, your keys are gone.

`airlock` removes both halves of that attack:

| Attack step | Without airlock | With airlock |
|---|---|---|
| Read your secrets | full home dir access | only the project folder is mounted |
| Send them out | any internet host | egress blocked except a domain whitelist |
| Persist / spread | writes anywhere | read-only root, throwaway container, home quarantined per client & mode |

This is the same model Anthropic uses to contain Claude Code:
**filesystem isolation + network egress control.** Either one alone is not
enough — isolation stops escape, egress control stops exfiltration.

---

## When to use it (scenarios)

- **Running untrusted open-source.** Clone it, `airlock run`, poke at it. If
  it's malware, it can't reach your keys or phone home.
- **Deploying for clients with many accounts.** Each client gets its own home
  volume, so one client's `vercel` / `heroku` login never shows up in another's
  sandbox. For a deploy whose login should die on exit, use
  `airlock run --ephemeral` — nothing is persisted on disk.
- **Trying a sketchy CLI / install script.** `curl … | bash`-style installers
  run contained instead of as you.
- **Reproducing a Linux-only bug** from your Mac without dual-booting.
- **Genuinely hostile code or an autonomous agent.** `airlock sbx` runs it in a
  microVM with its *own* kernel, so even a container-escape can't reach your Mac
  — with the same egress whitelist applied.

---

## Why use it even for your *own* code

`airlock dev` isn't about distrust — it's about a clean, consistent, disposable
workstation:

- **Linux parity with your deploy target.** Your code runs on Linux in
  production; building/testing in Linux catches "works on my Mac" bugs
  (path casing, native modules, line endings) *before* they ship.
- **Your Mac stays pristine.** No global `npm -g` sprawl, no version managers
  fighting, no leftover build junk. Blow the container away, your laptop is
  untouched.
- **Reproducible + shareable.** The environment is the `Dockerfile`. Same setup
  on any machine, and recoverable after a wipe (see Setup).
- **Blast radius.** A bad `rm -rf`, a runaway build, a fork bomb — capped by the
  container's CPU/memory/PID limits and read-only root, not your real disk.
- **Claude included.** `claude` is preinstalled and logged in, so you can do
  AI-assisted work inside the same clean box.

---

## Three modes

| | `airlock run` (UNTRUSTED) | `airlock dev` (TRUSTED) | `airlock sbx` (MICRO-VM) |
|---|---|---|---|
| **Use for** | OSS you don't trust | your own code | hostile code / agents |
| **Isolation** | container (shared kernel) | container (shared kernel) | **microVM (own kernel)** |
| **Host secrets** | Claude **token** + **this project's** sessions | Claude token **+ all history** | none (project only) |
| **Network** | 🔒 whitelist proxy only | 🌐 full internet | 🔒 whitelist proxy only |
| **Filesystem** | only the project dir | only the project dir | only the project dir |
| **Claude Code** | ✅ logged in · sessions saved on your Mac, per project | ✅ logged in (full history) | use `docker sandbox run claude` |
| **Cost** | light | light | heavier (VM RAM + boot) |

`run` and `dev` share the hardening: non-root user, **read-only root filesystem**,
all Linux capabilities dropped, no privilege escalation, memory / PID limits,
and a throwaway (`--rm`) container.

### Home directory: persistent (default) or ephemeral

The container is always destroyed on exit, but `/home/node` is not, by default:

| | default | `--ephemeral` |
|---|---|---|
| **`/home/node`** | named volume per **client** and per **mode** | RAM-backed tmpfs |
| **Survives exit** | caches, logins, nvm versions, Claude history | nothing |
| **Use for** | everyday work (fast restarts, warm caches) | deploy sessions, hostile code |

- The client comes from `$AIRLOCK_CLIENT`, then a `.airlock-client` file in the
  project, then the parent directory's name. Volumes are named
  `airlock-home-<client>-untrusted` and `airlock-home-<client>-dev`.
- `run` and `dev` **never share a home**. That split is a security boundary:
  a poisoned `~/.bashrc` or a shim in `~/.local/bin` written by untrusted code
  stays in the untrusted volume, so `dev` (full internet + your Claude history)
  never runs it.
- But within `run`, whatever untrusted code leaves in the home **is still there
  next spin**. For genuinely sketchy code, use `--ephemeral`, or wipe it:
  `airlock run --fresh` (this mode only) or `airlock reset [client]` (both).

`sbx` adds a **separate Linux kernel** (Docker Sandbox microVM) so even a
container-escape 0-day can't reach your Mac — with airlock's same egress
whitelist applied. It's the strongest, and the heaviest.

## Which mode? — use cases, rated by safety & cost

**Safety** = how well it contains hostile code. **Cost** = system resources +
startup time. Pick the lightest mode that covers your threat.

| Scenario | Mode | Safety | Cost |
|---|---|:---:|:---:|
| `npm install` / clone a random OSS repo | `run` | 🟢🟢🟢🟢 | 🪶 light |
| Run a `curl … \| bash` installer you don't trust | `run --ephemeral` | 🟢🟢🟢🟢 | 🪶 light |
| Deploy for a client (fresh `vercel`/`heroku` login) | `run --ephemeral` | 🟢🟢🟢🟢 | 🪶 light |
| Genuinely **hostile** code / malware analysis | `sbx` | 🟢🟢🟢🟢🟢 | 🔋 heavy |
| An **autonomous AI agent** with shell access | `sbx` | 🟢🟢🟢🟢🟢 | 🔋 heavy |
| Untrusted code that needs an **escape-proof** boundary | `sbx` | 🟢🟢🟢🟢🟢 | 🔋 heavy |
| Your **own** project — build/test on Linux | `dev` | 🟡🟡 | 🪶 light |
| Your own code + Claude with full history | `dev` | 🟡🟡 | 🪶 light |
| Reproduce a Linux-only bug from your Mac | `dev` | 🟡🟡 | 🪶 light |

**Rule of thumb:**
- **Default to `run`** for anything you don't trust — it already blocks secret
  theft (only the project is mounted) and exfiltration (whitelist). Light enough
  for all-day use, even on a 16 GB Air.
- **Escalate to `sbx`** only when a kernel-escape would be catastrophic (real
  malware, fully autonomous agents) and you can spare the RAM (a microVM can
  claim ~50% of host RAM while live).
- **Use `dev`** only for code you **wrote/trust** — it has full internet and your
  Claude history, so it's not for untrusted code.

> Why isn't `dev` "safe"? It's not meant to be — it trades isolation for
> convenience on *your own* code (full internet + history). The 🟡 rating is a
> reminder: never point `dev` at code you don't trust; use `run` or `sbx`.

### Safety ladder (most → least contained)

```
sbx   🟢🟢🟢🟢🟢   microVM (own kernel) + whitelist + no secrets   — hostile code, agents
run   🟢🟢🟢🟢     container + whitelist + token-only             — untrusted OSS, deploys
dev   🟡🟡         container + full internet + your history       — your own trusted code
```

---

## Making it a habit — `airlock guard`

airlock only protects you when you use it, and the dangerous moment is the
one you don't think about: typing `npm i` in a repo you were just given.
`airlock guard on` (setup turns it on) wraps `npm`, `npx`, `pnpm`, `yarn`,
`bun`, `node` and `corepack` in your Mac's shell. Inside a project (any folder
with a `package.json` below your home), typing one of them asks first:

```
  ⚠  airlock guard — `npm install` would run on your Mac, as you.
     project ~/Codebases/ClientCo/web
     Enter = airlock run   r = run (untrusted)   d = dev (your own code)
     h = on the Mac, just once   t = always allow on the Mac here   n = cancel
```

- **Enter** runs the exact command in airlock, mounting the repo root and
  starting in the same subfolder. If that project's sandbox is already open,
  it runs in that one. Your choice of `run`/`dev` is remembered per project.
- **t** trusts the project on the Mac for good (stored in
  `~/.config/airlock/trusted`; delete the line to undo).
- Only commands **you type** are affected: scripts, editors, git hooks and
  other tools still call the real binaries. Bypass once with `command npm …`
  or `AIRLOCK_GUARD=0 npm …`. Turn it off with `airlock guard off`.

---

## Disk space — why it filled up, and what keeps it clean now

After days of use across several projects, Docker reported its disk full.
The causes, and what airlock does about each now:

| What grew | Why | Now |
|---|---|---|
| npm / pnpm / yarn caches in each client's home volume | only ever grow; pnpm can't hard-link across the project mount, so its store is a full extra copy | trimmed when a volume's caches pass **3 GB** (`AIRLOCK_CACHE_LIMIT_GB`) |
| old sandbox images (~2 GB each) | every `airlock build` left the previous one behind | removed after each build and daily |
| BuildKit cache | never pruned | cache unused for 7 days is removed daily |
| volumes of clients you stopped working on | kept forever | flagged after **30 days** unused; `airlock clean --stale` deletes them |
| container logs | unbounded (the proxy logs every connection) | capped at 2 × 10 MB per container |
| leftover containers / networks (closed lid, crashed terminal) | exit cleanup never ran | removed daily (orphan networks also cause "no available IPv4 address pool") |

The light clean (`airlock clean --auto`) runs **by itself**, in the
background, at most once a day when you start `run` or `dev`. It never
deletes a volume, never touches one that's in use, and only removes package
caches, which re-download (logins, nvm versions and Claude history stay).
When Docker's disk passes 75 % or stale volumes pile up, the launch banner
says so. `airlock disk` shows the breakdown; `AIRLOCK_AUTO_CLEAN=0` turns
the daily run off.

`/tmp` inside the sandbox is now 1 GB (it was 256 MB, which large Next/Vite
builds filled up with `ENOSPC: no space left on device`).

---

## Setup (fresh / reset Mac)

If you wipe or replace your Mac, you get airlock back in three steps:

1. **Restore this folder** — from your backup, or `git clone <your-repo>` into
   e.g. `~/sandbox/airlock`. (Back the folder up! It's the source of truth. The
   `.secrets/` token is *not* backed up and doesn't need to be — it re-syncs
   from your Keychain.)

2. **Run setup:**
   ```bash
   bash ~/sandbox/airlock/setup.sh
   ```
   It checks (and guides installing) Docker, makes the `airlock` alias, creates
   `.secrets/`, builds the images, and self-tests that the whitelist blocks
   unknown hosts. It's safe to re-run.

3. **Open a new terminal** (or `source ~/.zshrc`) and go:
   ```bash
   cd <a project> && airlock run
   ```

If Docker isn't installed, `setup.sh` prints the exact commands to install
Docker Desktop for your chip, then you re-run it.

---

## Quick start

```bash
# UNTRUSTED: clone something sketchy and run it safely
cd ~/some/cloned/oss-project
airlock run                       # locked-down shell in the project folder
#   inside: npm install && npm run dev
#   open http://localhost:3000 on your Mac (the banner says if it moved)

# TRUSTED: work on your own code with Claude
cd ~/CodeBase/MyProject
airlock dev
#   inside: claude
```

The folder you launch from is mounted at the **same path** as on your Mac, in
both modes. In `run` it's the **only** project folder the container can see;
`dev` also gets your `~/.claude` history. Claude sessions are saved on your
Mac per project in both (see [Claude login & sessions](#claude-login--sessions)).

### Toolchain

- **Always the latest.** Node (latest **LTS**), npm, **pnpm**, **nvm**,
  **Claude Code** and the deploy CLIs (**vercel · netlify · heroku · firebase ·
  wrangler**) are never pinned. `airlock update` rebuilds with all of them at
  their newest release, and it **runs by itself in the background every 3 days**
  (`AIRLOCK_UPDATE_DAYS`, or `AIRLOCK_AUTO_UPDATE=0` to stop). A running
  sandbox keeps its versions; the next launch gets the new ones. `airlock
  status` shows what's installed and when it was last updated.
  (Before, a rebuild reused Docker's cached layers, so the tools stayed at
  whatever the first build downloaded.)
- Need a different default Node major? `AIRLOCK_NODE_VERSION=24 airlock update`.
  Per project, **nvm** switches inside: `nvm install 20 && nvm use 20`.
  nvm-installed versions live in the home volume, so they survive the next spin
  (with `--ephemeral`, they're gone on exit).
- Plus **git**, **ripgrep**, **jq** and **fzf**. All work offline in `run`.
- **zsh, set up the same as your Mac** (`shell/zshrc.zsh`, loaded by both):
  history with the time and duration of every command (`history -iD`), grey
  **predictions** from history as you type (→ accepts), syntax colours, ↑/↓
  search for commands starting with what you typed, Ctrl-R fuzzy history.
  Start a command with a space to keep it out of history. Inside the sandbox,
  history is **per project** (in the client's home volume), and the prompt
  shows `[airlock:run]` / `[airlock:dev]`.
- **Claude's status line** is the same script on the Mac and in both modes
  (`statusline/statusline-command.sh`), with an `airlock:run`/`airlock:dev`
  badge inside so you always know where you are.

---

## Commands

```
airlock run [CMD]   UNTRUSTED mode — whitelist-only network, per-project sessions
airlock dev [CMD]   TRUSTED mode — Claude login + full internet + Mac history
airlock sbx [CMD]   STRONGEST — Docker microVM (own kernel) + same whitelist
airlock exec [CMD]  open ANOTHER terminal into the running sandbox
  flags (run/dev):  --ephemeral  tmpfs home, destroyed on exit
                    --fresh      wipe this mode's home volume first
airlock reset [CL]  wipe a client's home volumes (both modes)
airlock allow [DOM] add domains to the whitelist (instant) — no args: pick from blocked
airlock blocked     list the URLs/hosts the proxy denied (not whitelisted)
airlock guard on    catch npm/pnpm/yarn/npx/bun/node typed on the Mac (see below)
airlock disk        what's using Docker's disk, per client volume
airlock clean       free disk: leftovers, old builds, package caches (also daily, auto)
  --stale / --deep  …also delete volumes unused 30 days / all build cache
airlock down        stop & remove THIS project's sandbox + proxy
airlock down --all  stop & remove every airlock project on this machine
airlock off         down --all, then quit Docker Desktop (frees its RAM)
airlock login       store a long-lived Claude token (no "Login expired")
airlock logout      remove that token
airlock status      show images, what's running, and whether it's SAFE
airlock build       (re)build the images
airlock rebuild     rebuild from scratch (no cache)
airlock update      latest Node LTS, Claude Code, npm/pnpm, deploy CLIs (auto every 3 days)
airlock logs        follow proxy logs live (watch what's allowed/blocked)
airlock help        show every command   (also: plain `airlock`, --help, -h)
```

Pass a one-off command instead of a shell: `airlock run npm test`,
`airlock dev claude`, `airlock exec vercel deploy`.

### Every launch tells you where you are

`airlock run` / `airlock dev` print a banner so you always know the mode, the
exact host path mounted, the network policy, and your login state. Colors show
on a terminal and auto-disable when piped.

```
  ────────────────────────────────────────────────────
  🔒 airlock · UNTRUSTED   safe — locked-down sandbox
  ────────────────────────────────────────────────────
  path      /Users/you/some/oss-project
  client    some · home volume airlock-home-some-untrusted
            ↳ mounted at the same path — the only project folder the box can see
  network   whitelist only · 36 domains allowed, everything else blocked
  secrets   none of your files · Claude token only
  sessions  saved on your Mac · ~/.claude/projects/-Users-you-some-oss-project · 3 so far · claude --resume
  home      persistent · per-client volume — caches & logins survive
  ports     1:1 3000-3005 4000 4173 4200 4321 5000-5001 5173-5175 6006 8000 8080-8081 8787 9000
            ↳ e.g. http://localhost:3000 · no --host needed, localhost servers are forwarded
  blocked   you get a macOS notification when a site is blocked · fix: airlock allow
  claude    logged in (synced from your Keychain)
  ────────────────────────────────────────────────────
  type 'exit' to leave — container is destroyed; this client's home volume is kept
```

### `airlock status`

A dashboard of images, what's running (labelled 🔒 SAFE / ⚠ TRUSTED), the two
modes, and the network whitelist shown as **readable domains** (not regex):

```
  Running now
    🔒 SAFE     airlock-untrusted-run-…   · untrusted · whitelist net · Up 5s

  Network whitelist  · 27 domains reachable in 'run' mode; all others blocked
    *.npmjs.org                   github.com
    *.github.com                  registry.yarnpkg.com
    *.vercel.com                  api.anthropic.com
    …
```

---

## Networking — the whitelist

In `run` mode the sandbox has **no direct internet**. It sits on an `internal`
Docker network and can only reach a small proxy (`tinyproxy`, default-deny). The
proxy forwards a request **only if the destination host matches a rule** in
`proxy/filter` — including HTTPS (it filters the `CONNECT` host).

Verified behavior:

```
github.com            -> HTTP 200   (allowed)
registry.npmjs.org    -> HTTP 200   (allowed)
example.com           -> 403 blocked
anything-not-listed   -> 403 blocked
```

**"The site doesn't load" in `run` is almost always the whitelist**, so airlock
now tells you instead of failing silently:

- a **macOS notification** the first time each host is blocked
  (`AIRLOCK_NOTIFY=0` to mute);
- on exit, a **list of everything blocked** that session.

Then allow what you trust:
```bash
airlock allow                     # pick from what was blocked (numbers, or 'a')
airlock allow files.example.com   # or name it — URLs/ports are fine, it keeps the host
airlock blocked                   # the full denied list (works after exit too)
```
The proxy matches the **host only**. A rule like `api.sanity.io:443` never
matched anything; `airlock allow` now strips the scheme, port and path for you.

Server-side code in Node (Next.js route handlers, `getServerSideProps`,
`next/font`, CMS SDKs) used to ignore the proxy and fail with `fetch failed`
even for whitelisted sites. `run` now sets `NODE_USE_ENV_PROXY=1`, which makes
Node 24's `fetch`/`http` use it. Node versions installed with nvm older than
24 don't support that.
The filter is bind-mounted into the proxy, so no rebuild is needed; if no
proxy is running, the change applies on the next `airlock run`.
Example `airlock blocked` output:
```
  Denied — not on the whitelist:
    ✗ https://tracker.evil-test.io     1×
    ✗ https://some-cdn.attacker.net    1×
```

Default whitelist: npm / yarn / pip / cargo, GitHub / GitLab, common deploy
targets (Vercel, Netlify, Heroku, Cloudflare, Firebase), Anthropic, `nodejs.org`
(for `nvm install`), `fonts.gstatic.com` (for `next/font`) and Sanity. Edit
`proxy/filter` for bulk changes (one extended-regex per line, matched against
the host). `airlock logs` shows what's being blocked.

> `dev` mode uses full internet (it's your trusted code). Only `run` is gated.

### `airlock sbx` — microVM mode (strongest)

`run` and `dev` are containers (shared host kernel). `airlock sbx` runs the
project inside a **Docker Sandbox microVM** — its *own* Linux kernel — so even a
container-escape 0-day can't reach your Mac. airlock applies its **same
default-deny egress whitelist** to the microVM's proxy, so it's **escape-proof
and exfil-proof** at once.

```bash
cd ~/some/cloned/oss-project
airlock sbx                 # boot (or reuse) a microVM, apply whitelist, drop in
airlock sbx npm test        # one-off command inside the microVM
airlock sbx --fresh         # delete the old box and start a clean one
airlock sbx down            # destroy this project's microVM
```

- Needs `docker sandbox` (Docker Desktop 4.58+). If it's missing, airlock tells
  you and you can fall back to `airlock run`.
- The microVM reuses airlock's tooling image as its template (Node, pnpm, deploy
  CLIs). Override with `AIRLOCK_SBX_TEMPLATE=<image>`, or set it empty to use
  Docker's default shell template.
- The same whitelist from `proxy/filter` is translated to the sandbox proxy
  (verified: non-whitelisted hosts get **403**, whitelisted hosts **200**). See
  what was blocked with `docker sandbox network log`.
- **Kept & reused by default** (per-project, one microVM). This matches Docker's
  model — sandboxes persist across restarts — so your `/login`, `nvm install`s,
  and other home-dir setup survive the next spin and startup is fast. Node and
  the deploy CLIs are baked into the image, so they're never reinstalled either
  way. `airlock sbx --fresh` deletes the old box and creates a clean one;
  `airlock sbx down` (or `airlock down`) destroys it.
- Claude isn't auto-seeded (the microVM mounts only your project), but because
  the box is **kept**, you just run `/login` once inside and it persists. Or use
  Docker's native agent: `docker sandbox run claude`.

> Reuse keeps the **isolation** (own kernel, no host secrets, whitelist) — that's
> what makes it a sandbox. It only drops the **fresh-start**, which matters for
> *untrusted* code. So: reuse for your repeated trusted work; use `--fresh` (or
> the throwaway `airlock run`) for genuinely hostile code where no carry-over is
> the point.

> Trade-off: a microVM uses more RAM and has a boot step, so it's heavier than
> `run`. Use `sbx` for genuinely hostile code or autonomous agents; `run` is
> fine for everyday untrusted installs.

When you exit an `airlock run` sandbox, the proxy and its network are **torn
down automatically** — nothing internet-connected lingers. (If a second
`airlock exec`/`run` terminal is still open, the proxy stays up until the last
one exits.)

---

## Multiple terminals

Don't run `airlock run` twice in the same project — that starts a *second*
container (its busy ports move to `1<port>`, so your URLs change).
Attach to the same one instead:

```bash
airlock run            # terminal 1: start it, run your app
airlock exec           # terminal 2, 3, …: jump into the SAME box
```

---

## Dev servers / ports

Every well-known dev-server port is published automatically — nothing to
configure, in both modes:

| Port(s) | Typically |
|---|---|
| `3000`–`3005` | Next.js, CRA, Remix, Nuxt, Express — and a 2nd/3rd app |
| `4200` · `4000` | Angular · Gatsby / Phoenix / GraphQL |
| `5173`–`5175` · `4173` | Vite (and the next ports it tries) · `vite preview` |
| `4321` | Astro |
| `5000` · `5001` | Flask, .NET, `serve` |
| `6006` | Storybook |
| `8000` | Django, FastAPI, Laravel |
| `8080` · `8081` | misc / proxies · Expo / Metro |
| `8787` | `wrangler dev` |
| `9000` | misc |

- **1:1 when free.** `localhost:3000` inside is `localhost:3000` on your Mac,
  so the URL your dev server prints is the one to open.
- **Only busy ports move.** If one is taken on your Mac (another project's box,
  or macOS AirPlay on `5000`), just that port moves to `1<port>`, then
  `2<port>`, … (`3000` → `13000`); the rest stay 1:1. The banner lists what moved.
- **No `--host` flag needed.** A built-in forwarder relays dev servers that bind
  only to `127.0.0.1` (the default for Vite, Next, Astro, …).
- **Your Mac only.** Ports are published on `127.0.0.1`, so other machines on
  your network can't reach what the sandbox is serving.

Need more? Add a `.airlock-ports` file to the project (`7000 7001`), or set
`AIRLOCK_EXTRA_PORTS="7000 7001"` for every project. `AIRLOCK_PORTS` replaces
the default list entirely.

---

## Claude login & sessions

`claude` is preinstalled and logged in in both modes. Because macOS keeps your
Claude login in the **Keychain** (not a file), `airlock` exports it to
`.secrets/.credentials.json` (chmod 600, git-ignored), mounts it read-only, and
copies it into the sandbox's home. Token refreshes stay in the sandbox's home
volume and are **never written back** to your Mac.

**Recommended: `airlock login`, once.** That Keychain login shares one refresh
token between your Mac and every sandbox, and each refresh invalidates the
old one — so after a few hours a new sandbox could start with a dead token
("Login expired · Please run /login"). `airlock login` runs `claude
setup-token` and stores the long-lived token in your Keychain; sandboxes then
get it as `CLAUDE_CODE_OAUTH_TOKEN`, which never refreshes and never fights
your Mac. Without it, airlock keeps whichever copy was refreshed last.

- `dev` mode uses your Mac's own Claude history and memory, read-write:
  `~/.claude/projects/` (sessions + per-project memory), `file-history/`,
  `history.jsonl` and `CLAUDE.md` are linked straight to the host. If your
  `~/.claude/CLAUDE.md` is a symlink (e.g. into a rules repo), dev mounts the
  real file it points to, read-write — the same text your Mac's Claude reads. The project
  is mounted at the **same path** as on your Mac, so `claude --resume` sees the
  same sessions on both sides, and they survive the container. The login token
  and settings stay in the sandbox's volume.
- `run` mode saves **this project's sessions on your Mac**, exactly where your
  Mac's Claude keeps them: `~/.claude/projects/<project path>/`. Every project
  has its own history, it survives `--rm` and `--ephemeral`, and
  `claude --resume` / `claude --continue` work on both sides — start in the
  sandbox, resume on the Mac, or the other way round. Only that one folder is
  mounted: other projects' (other clients') sessions, your global prompt
  history (`history.jsonl`) and file checkpoints never enter a `run` sandbox,
  and the project's `memory/` is **read-only** inside, so untrusted code can't
  plant instructions your Mac's Claude would load. CLAUDE.md is a read-only
  copy refreshed every spin. Sessions an older airlock kept in the client
  volume for the same path move to the Mac on the next spin; old ones from
  the `/workspace` days (all projects mixed) stay in the volume.
  `AIRLOCK_RUN_HISTORY=0` keeps `run` sessions in the client volume instead.
- First run pops a **Keychain prompt** → click **Always Allow**.
- If Claude says "Not logged in," run `/login` inside, or set `ANTHROPIC_API_KEY`
  before launching.

---

## Security model — and its limits

**What it protects against:** a malicious dependency or script reading your home
directory / keys (filesystem isolation) and exfiltrating data (egress whitelist),
plus persistence and resource-exhaustion (read-only root, throwaway container,
CPU/mem/PID caps).

**What it does NOT protect against — be honest:**

- **Shared kernel (`run`/`dev`).** These are containers, not VMs. A kernel-level
  container escape (0-day) would defeat them. For maximum isolation use
  **`airlock sbx`**, which runs in a microVM with its own kernel.
- **The project dir is read-write.** Untrusted code can modify files in the
  folder you opened (that's your project). It can't touch anything else.
- **The home volume persists by default.** Anything untrusted code writes to
  `/home/node` in `run` (a modified `~/.bashrc`, a fake binary on `PATH`) is
  still there next `run` for that client. It can't reach `dev`'s home, but for
  hostile code use `--ephemeral`, or `airlock reset` afterwards.
- **Whitelisted domains are trusted.** If you `allow` a domain, code can talk to
  it; GitHub/npm can host arbitrary content. Keep the list tight.
- **The Claude token is present in untrusted mode** (so `claude` works there).
  Untrusted code could read it. The proxy blocks exfil to random hosts, but a
  whitelisted domain could in theory carry it out. If that matters: set
  `AIRLOCK_SEED_CLAUDE=0` for `untrusted` in `docker-compose.yml`. If a token is
  ever exposed, revoke it with `/logout` or rotate your login.
- **`run` sessions are written to your Mac.** Untrusted code in the box can
  read and edit that project's transcripts (never memory, never other
  projects). A tampered transcript is untrusted text, like the project's own
  files; be as careful resuming it as you are reading that code.
- **Dev mode is not for untrusted code** — it has full internet and your
  history. Use `airlock run` for anything you don't trust.

---

## Layout

```
~/sandbox/airlock/
├── airlock              # the host CLI (aliased as `airlock`)
├── setup.sh             # one-shot restore on a fresh/reset Mac
├── Dockerfile           # sandbox image (Node + deploy CLIs + Claude)
├── docker-compose.yml   # two profiles (run/dev) + proxy + networks + limits
├── docker-compose.home-persistent.yml  # default: per-client, per-mode home volume
├── docker-compose.home-ephemeral.yml   # --ephemeral: tmpfs home, wiped on exit
├── entrypoint.sh        # seeds Claude login (token-only in run, full in dev)
├── in-container.sh      # `airlock` reminder shown inside the box
├── proxy/
│   ├── Dockerfile       # tinyproxy image
│   ├── tinyproxy.conf   # default-deny egress config
│   └── filter           # the domain whitelist (edit / `airlock allow`), bind-mounted
├── shell/
│   ├── guard.sh         # `airlock guard`: catches npm/pnpm/… typed on the Mac
│   └── zshrc.zsh        # shared zsh setup (Mac + sandbox)
├── sandbox/
│   └── portforward.mjs  # relays loopback-bound dev servers to the host
├── terminal/
│   ├── make-profile.js  # builds the "Airlock" Terminal.app profile (font, spacing, cursor…)
│   └── Airlock.terminal # the generated profile — `open` it to import
├── statusline/
│   └── statusline-command.sh  # Claude status bar baked into the image (dev)
├── .secrets/            # exported Claude token + CLAUDE.md copy (git-ignored)
├── .logs/               # last proxy log per project, for `airlock blocked`
├── .state/              # volume last-used stamps, daily-clean marker (git-ignored)
└── README.md
```

---

## Copyright

© 2026 Syed Tasavour. Personal developer tooling.

Provided **as-is, without warranty of any kind**. `airlock` raises the cost of
an attack significantly but is not a guarantee of safety — see
[Security model — and its limits](#security-model--and-its-limits). You are
responsible for the code you run and the domains you whitelist.

You're free to copy, modify, and reuse this for your own setup.
