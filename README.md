<div align="center">

# 🛡️ airlock

**A disposable, hardened Linux sandbox for running untrusted code and deploying
with throwaway CLI logins — without ever exposing your Mac's keys, files, or
secrets.**

</div>

---

Think of it as an airlock between sketchy code and your real machine: code goes
in, does its work, the container is destroyed on exit. Nothing leaks out.

```bash
cd ~/some/cloned/oss-project
airlock run        # locked-down, throwaway shell — safe to run anything
```

---

## Table of contents
- [Why this matters](#why-this-matters)
- [When to use it (scenarios)](#when-to-use-it-scenarios)
- [Why use it even for your *own* code](#why-use-it-even-for-your-own-code)
- [Two modes](#two-modes)
- [Setup (fresh / reset Mac)](#setup-fresh--reset-mac)
- [Quick start](#quick-start)
- [Commands](#commands)
- [Networking — the whitelist](#networking--the-whitelist)
- [Multiple terminals](#multiple-terminals)
- [Dev servers / ports](#dev-servers--ports)
- [Claude login](#claude-login)
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
| Persist / spread | writes anywhere | read-only root, throwaway container |

This is the same model Anthropic uses to contain Claude Code:
**filesystem isolation + network egress control.** Either one alone is not
enough — isolation stops escape, egress control stops exfiltration.

---

## When to use it (scenarios)

- **Running untrusted open-source.** Clone it, `airlock run`, poke at it. If
  it's malware, it can't reach your keys or phone home.
- **Deploying for clients with many accounts.** Each spin is logged out, so you
  `vercel login` / `heroku login` fresh as the right client every time — no
  cross-account mix-ups, no credentials persisted on disk.
- **Trying a sketchy CLI / install script.** `curl … | bash`-style installers
  run contained instead of as you.
- **Reproducing a Linux-only bug** from your Mac without dual-booting.

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

## Two modes

| | `airlock run` (UNTRUSTED) | `airlock dev` (TRUSTED) |
|---|---|---|
| **Use for** | OSS you don't trust | your own code |
| **Host secrets** | only the Claude **token** | Claude token **+ history** |
| **Network** | 🔒 whitelist proxy only | 🌐 full internet |
| **Filesystem** | only the project dir | only the project dir |
| **Claude Code** | ✅ logged in (no history) | ✅ logged in (full history) |

Both share the hardening: non-root user, **read-only root filesystem**, all
Linux capabilities dropped, no privilege escalation, RAM-backed ephemeral home,
CPU / memory / PID limits, and a throwaway (`--rm`) container.

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
airlock run                       # locked-down shell at /workspace
#   inside: npm install && npm run dev -- -H 0.0.0.0
#   open http://localhost:3000 on your Mac

# TRUSTED: work on your own code with Claude
cd ~/CodeBase/MyProject
airlock dev
#   inside: claude
```

The folder you launch from becomes `/workspace` — the **only** host folder the
container can see.

### Toolchain

- **Node 24.16** (default), **pnpm** and **npm** preinstalled and working offline.
- **nvm** is available to switch Node versions: `nvm install 20 && nvm use 20`.
  Because the sandbox home is ephemeral, nvm-installed versions last for the
  current session (re-install next spin). The default 24.16 is always present.
- Deploy CLIs: **vercel · netlify · heroku · firebase · wrangler**. Plus
  **git**, **ripgrep**, and **claude** (Claude Code).

---

## Commands

```
airlock run [CMD]   UNTRUSTED mode — no history, whitelist-only network
airlock dev [CMD]   TRUSTED mode — Claude login + full internet
airlock exec [CMD]  open ANOTHER terminal into the running sandbox
airlock allow DOM   add a domain to the egress whitelist (then rebuild)
airlock down        stop & remove sandbox + proxy containers
airlock status      show images, what's running, and whether it's SAFE
airlock build       (re)build the images
airlock rebuild     rebuild from scratch (no cache)
airlock logs        follow proxy logs (watch what's allowed/blocked)
airlock help        show help   (also --help, -h)
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
            ↳ mounted at /workspace — the only host folder the box can see
  network   whitelist only · 27 domains allowed, everything else blocked
  secrets   none of your files · Claude token only, no history
  ports     3000 3001 5173 4000 8080 → http://localhost:<port> on your Mac
  claude    logged in (synced from your Keychain)
  ────────────────────────────────────────────────────
  type 'exit' to leave — the container is destroyed (fresh next spin)
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

Add a domain:
```bash
airlock allow files.example.com
airlock rebuild          # bake the new whitelist into the proxy image
```

Default whitelist: npm / yarn / pip / cargo, GitHub / GitLab, common deploy
targets (Vercel, Netlify, Heroku, Cloudflare, Firebase), and Anthropic. Edit
`proxy/filter` for bulk changes (one extended-regex per line, matched against
the host). `airlock logs` shows what's being blocked.

> `dev` mode uses full internet (it's your trusted code). Only `run` is gated.

---

## Multiple terminals

Don't run `airlock run` twice — that starts a *second* container and collides on
the published ports. Attach to the same one instead:

```bash
airlock run            # terminal 1: start it, run your app
airlock exec           # terminal 2, 3, …: jump into the SAME box
```

---

## Dev servers / ports

Ports `3000`, `3001`, `5173`, `4000`, `8080` are forwarded to your Mac. **Bind
your dev server to `0.0.0.0`**, not localhost, or the host can't reach it:

```bash
npm run dev -- -H 0.0.0.0         # Next.js / CRA
npm run dev -- --host 0.0.0.0     # Vite
```
Then open `http://localhost:3000`. Need another port? Add it to `ports:` in
`docker-compose.yml`, then `airlock build`.

---

## Claude login

`claude` is preinstalled and logged in in both modes. Because macOS keeps your
Claude login in the **Keychain** (not a file), `airlock` exports it to
`.secrets/.credentials.json` (chmod 600, git-ignored), mounts it read-only, and
copies it into the container's ephemeral home. Token refreshes stay in the
container and are **never written back** to your Mac.

- `dev` mode also mounts your `~/.claude` history; `run` mode mounts **only the
  token** (no past conversations).
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

- **Shared kernel.** This is containers, not a VM. A kernel-level container
  escape (0-day) would defeat it. For maximum isolation, run on a throwaway VM.
- **The project dir is read-write.** Untrusted code can modify files in the
  folder you opened (that's your project). It can't touch anything else.
- **Whitelisted domains are trusted.** If you `allow` a domain, code can talk to
  it; GitHub/npm can host arbitrary content. Keep the list tight.
- **The Claude token is present in untrusted mode** (so `claude` works there).
  Untrusted code could read it. The proxy blocks exfil to random hosts, but a
  whitelisted domain could in theory carry it out. If that matters: set
  `AIRLOCK_SEED_CLAUDE=0` for `untrusted` in `docker-compose.yml`. If a token is
  ever exposed, revoke it with `/logout` or rotate your login.
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
├── entrypoint.sh        # seeds Claude login (token-only in run, full in dev)
├── in-container.sh      # `airlock` reminder shown inside the box
├── proxy/
│   ├── Dockerfile       # tinyproxy image
│   ├── tinyproxy.conf   # default-deny egress config
│   └── filter           # the domain whitelist (edit / `airlock allow`)
├── .secrets/            # exported Claude token (git-ignored, chmod 600)
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
