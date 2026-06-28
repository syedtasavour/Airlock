# airlock — disposable Linux sandbox for running untrusted projects and
# deploying with throwaway CLI logins. Ships Vercel / Netlify / Heroku /
# Firebase / Wrangler + Claude Code.
# Runs as a NON-ROOT user; the root filesystem is mounted read-only by compose.
# Default Node is pinned to 24.16; nvm is available inside to switch versions.
FROM node:24.16-bookworm

# --- base tooling -----------------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
        curl \
        git \
        ca-certificates \
        gnupg \
        openssh-client \
        less \
        ripgrep \
    && rm -rf /var/lib/apt/lists/*

# --- Heroku CLI -------------------------------------------------------------
RUN curl -fsSL https://cli-assets.heroku.com/install.sh | sh

# --- deployment CLIs (installed globally, owned by root) ---------------------
# Installed to /usr/local so they survive the read-only root fs and the
# ephemeral (tmpfs) home. Credentials these tools write go to $HOME, which is
# wiped every spin -> each run starts logged out (safe for client accounts).
RUN npm install -g \
        vercel \
        netlify-cli \
        firebase-tools \
        wrangler \
    && npm cache clean --force

# --- Claude Code (native binary, baked into /opt) ---------------------------
# Modern Claude Code is a self-contained native binary whose launcher lives at
# $HOME/.local/bin/claude (the npm package is just a shim around it). Because our
# $HOME is a tmpfs that is wiped every spin, anything installed under $HOME at
# build time vanishes at runtime -> the launcher reports "missing or broken".
# Fix: install via the official installer into a throwaway build HOME, then
# relocate the self-contained binary to /opt/claude (persistent + survives the
# read-only root fs). entrypoint.sh symlinks it into $HOME/.local/bin each spin.
RUN mkdir -p /opt/claude \
    && BUILD_HOME="$(mktemp -d)" \
    && HOME="$BUILD_HOME" bash -c 'curl -fsSL https://claude.ai/install.sh | bash' \
    && cp "$(readlink -f "$BUILD_HOME/.local/bin/claude")" /opt/claude/claude \
    && chmod 755 /opt/claude/claude \
    && rm -rf "$BUILD_HOME"

# --- pnpm as the default package manager ------------------------------------
# Installed globally at build time so it works fully offline and under the
# read-only root fs (corepack's lazy "fetch latest at runtime" breaks in the
# network-restricted untrusted mode, so we bake a real pnpm binary instead).
ENV COREPACK_ENABLE_DOWNLOAD_PROMPT=0
RUN npm install -g pnpm && npm cache clean --force

# --- nvm (Node Version Manager), available inside the sandbox ---------------
# nvm.sh is baked read-only at /usr/local/nvm. At runtime NVM_DIR points at the
# writable (tmpfs) home, so `nvm install <ver>` works per-session. Default node
# stays 24.16 (from the base image); nvm is for switching when a project needs it.
RUN mkdir -p /usr/local/nvm \
    && curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh \
       | NVM_DIR=/usr/local/nvm PROFILE=/dev/null bash
# Load nvm in every interactive bash shell, with installs going to the home dir.
RUN printf '%s\n' \
    'export NVM_DIR="$HOME/.nvm"' \
    'mkdir -p "$NVM_DIR"' \
    '[ -s /usr/local/nvm/nvm.sh ] && \. /usr/local/nvm/nvm.sh' \
    >> /etc/bash.bashrc

# Seed login/session from the read-only host mount into the writable home.
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
# Friendly reminder if someone types `airlock` while already inside the sandbox.
COPY in-container.sh /usr/local/bin/airlock
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/airlock

# The base image already ships a non-root `node` user (uid/gid 1000).
USER node
ENV HOME=/home/node
# $HOME/.local/bin holds the per-spin claude symlink (created by entrypoint.sh);
# put it on PATH for non-interactive commands too (e.g. `airlock run claude …`).
ENV PATH=/home/node/.local/bin:$PATH
# The binary lives read-only in /opt and the home is ephemeral, so self-update
# can't persist anyway — disable it to avoid the "repair" nag and pointless
# re-downloads (which would also fail behind the run-mode egress whitelist).
ENV DISABLE_AUTOUPDATER=1
WORKDIR /workspace

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["bash"]
