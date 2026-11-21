# airlock — disposable Linux sandbox for running untrusted projects and
# deploying with throwaway CLI logins. Ships Vercel / Netlify / Heroku /
# Firebase / Wrangler + Claude Code.
# Runs as a NON-ROOT user; the root filesystem is mounted read-only by compose.
<<<<<<< Updated upstream
# Default Node is pinned to 24.22.3; nvm is available inside to switch versions.
FROM node:24.22.3-bookworm
=======
#
# ALWAYS CURRENT: nothing below is pinned. The base is the latest Node LTS,
# and every tool installs its latest release. `airlock update` (also run by
# itself in the background every few days) rebuilds with --pull and a new
# AIRLOCK_REFRESH value, which defeats Docker's layer cache. Before that, a
# plain rebuild kept reusing the cached layers, so the tools were frozen at
# whatever version the very first build happened to download.
# Need a specific Node major as the default? AIRLOCK_NODE_VERSION=24 airlock update
# (nvm inside switches per project either way).
ARG NODE_VERSION=lts
FROM node:${NODE_VERSION}

# Changes on every `airlock update`. Every RUN below sees build args as env,
# so a new value is a cache miss from here down: OS packages, npm, the CLIs,
# Claude, pnpm and nvm are all fetched fresh.
ARG AIRLOCK_REFRESH=0
>>>>>>> Stashed changes

# --- base tooling -----------------------------------------------------------
RUN apt-get update && apt-get upgrade -y \
    && apt-get install -y --no-install-recommends \
        curl \
        git \
        ca-certificates \
        gnupg \
        openssh-client \
        less \
        ripgrep \
        jq \
        zsh \
        zsh-autosuggestions \
        zsh-syntax-highlighting \
        fzf \
    && rm -rf /var/lib/apt/lists/*

# npm itself: the one bundled with the Node image lags behind.
RUN npm install -g npm@latest && npm cache clean --force

# --- Heroku CLI -------------------------------------------------------------
RUN curl -fsSL https://cli-assets.heroku.com/install.sh | sh

# --- deployment CLIs (installed globally, owned by root) ---------------------
# Installed to /usr/local so they survive the read-only root fs. Their logins
# go to $HOME: the client's home volume, or a tmpfs with --ephemeral.
RUN npm install -g \
        vercel@latest \
        netlify-cli@latest \
        firebase-tools@latest \
        wrangler@latest \
    && npm cache clean --force

# --- Claude Code (native binary, baked into /opt) ---------------------------
# Modern Claude Code is a self-contained native binary whose launcher lives at
# $HOME/.local/bin/claude. Anything installed under $HOME at build time is
# hidden at runtime by the home volume/tmpfs -> "missing or broken". So:
# install the LATEST release into a throwaway build HOME, then relocate the
# binary to /opt/claude (survives the read-only root fs). entrypoint.sh
# symlinks it into $HOME/.local/bin each spin.
RUN mkdir -p /opt/claude \
    && BUILD_HOME="$(mktemp -d)" \
    && HOME="$BUILD_HOME" bash -c 'curl -fsSL https://claude.ai/install.sh | bash -s latest' \
    && cp "$(readlink -f "$BUILD_HOME/.local/bin/claude")" /opt/claude/claude \
    && chmod 755 /opt/claude/claude \
    && rm -rf "$BUILD_HOME"

# --- pnpm as the default package manager ------------------------------------
# Installed globally at build time so it works fully offline and under the
# read-only root fs (corepack's lazy "fetch latest at runtime" breaks in the
# network-restricted untrusted mode, so we bake a real pnpm binary instead).
ENV COREPACK_ENABLE_DOWNLOAD_PROMPT=0
RUN npm install -g pnpm@latest && npm cache clean --force

# --- nvm (Node Version Manager), available inside the sandbox ---------------
# Latest nvm release (looked up at build time). nvm.sh is baked read-only at
# /usr/local/nvm; at runtime NVM_DIR is in the home volume, so `nvm install
# <ver>` versions persist per client. The default node is the image's LTS.
RUN mkdir -p /usr/local/nvm \
    && NVM_TAG="$(curl -fsSL https://api.github.com/repos/nvm-sh/nvm/releases/latest | jq -r .tag_name)" \
    && case "$NVM_TAG" in v*) ;; *) NVM_TAG=v0.40.3 ;; esac \
    && curl -fsSL "https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_TAG}/install.sh" \
       | NVM_DIR=/usr/local/nvm PROFILE=/dev/null bash
# Load nvm in every interactive bash shell, with installs going to the home dir.
RUN printf '%s\n' \
    'export NVM_DIR="$HOME/.nvm"' \
    'mkdir -p "$NVM_DIR"' \
    '[ -s /usr/local/nvm/nvm.sh ] && \. /usr/local/nvm/nvm.sh' \
    >> /etc/bash.bashrc

# What's inside, for `airlock update` / `airlock status` to show.
RUN { echo "node $(node -v)"; echo "npm $(npm -v)"; echo "pnpm $(pnpm -v)"; \
      echo "claude $(/opt/claude/claude --version 2>/dev/null | head -1)"; \
      echo "vercel $(vercel --version 2>/dev/null | tail -1)"; \
      echo "netlify $(netlify --version 2>/dev/null | head -1)"; \
      echo "heroku $(heroku --version 2>/dev/null | head -1)"; \
      echo "firebase $(firebase --version 2>/dev/null | head -1)"; \
      echo "wrangler $(wrangler --version 2>/dev/null | tail -1)"; } > /opt/airlock-versions.txt

# --- zsh: the same shell setup as your Mac ----------------------------------
# shell/zshrc.zsh is the one config both sides load (history with timestamps
# and durations, predictions, highlighting, ↑ prefix search, fzf Ctrl-R).
# skip_global_compinit: our config runs compinit itself, with its cache in $HOME.
COPY shell/zshrc.zsh /etc/zsh/airlock.zsh
RUN echo 'source /etc/zsh/airlock.zsh' >> /etc/zsh/zshrc \
    && echo 'skip_global_compinit=1' >> /etc/zsh/zshenv \
    && chmod 644 /etc/zsh/airlock.zsh \
    && chsh -s /bin/zsh node

# --- Claude Code statusline (both modes, same script as your Mac) ---------------------------------
# airlock ships its OWN copy of the statusline. It is baked into the image at
# build time and never read from the host's ~/.claude, so the sandbox gets the
# status bar without being granted any access to your Mac's Claude config.
# entrypoint.sh points settings.json at this path when AIRLOCK_STATUSLINE=1.
COPY statusline/statusline-command.sh /opt/airlock/statusline-command.sh
RUN chmod 755 /opt/airlock/statusline-command.sh

# --- port forwarder ---------------------------------------------------------
# Relays the container's own IP to 127.0.0.1 for the published ports, so dev
# servers that bind loopback (the default for Vite/Astro/Next) are reachable
# from the Mac without a --host flag. Only engages when nothing already holds
# the wildcard address, so --host keeps working untouched.
COPY sandbox/portforward.mjs /opt/airlock/portforward.mjs
RUN chmod 755 /opt/airlock/portforward.mjs

# Seed login/session from the read-only host mount into the writable home.
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
# Friendly reminder if someone types `airlock` while already inside the sandbox.
COPY in-container.sh /usr/local/bin/airlock
# Explicit modes: the source files may be owner-only (700/600) on the Mac, and
# COPY keeps that — a non-root user then can't read them ("Permission denied").
RUN chmod 755 /usr/local/bin/entrypoint.sh /usr/local/bin/airlock

# The base image already ships a non-root `node` user (uid/gid 1000).
USER node
ENV HOME=/home/node
# $HOME/.local/bin holds the per-spin claude symlink (created by entrypoint.sh);
# put it on PATH for non-interactive commands too (e.g. `airlock run claude …`).
ENV PATH=/home/node/.local/bin:$PATH
# The binary lives read-only in /opt and the per-spin symlink would override
# a self-update anyway. Freshness comes from `airlock update` instead (rebuilt
# with the latest Claude every few days), so disable the in-place updater.
ENV DISABLE_AUTOUPDATER=1
# Interactive shells, and the shell Claude Code's Bash tool snapshots, are zsh.
ENV SHELL=/bin/zsh
# Fallback marker for the statusline badge; compose overrides it with run|dev.
ENV AIRLOCK_SANDBOX=1
WORKDIR /workspace

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["zsh"]
