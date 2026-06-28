# airlock — disposable Linux sandbox for running untrusted projects and
# deploying with throwaway CLI logins. Ships Vercel / Netlify / Heroku /
# Firebase / Wrangler + Claude Code.
# Runs as a NON-ROOT user; the root filesystem is mounted read-only by compose.
FROM node:20-bookworm

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

# --- deployment CLIs + Claude Code (installed globally, owned by root) -------
# Installed to /usr/local so they survive the read-only root fs and the
# ephemeral (tmpfs) home. Credentials these tools write go to $HOME, which is
# wiped every spin -> each run starts logged out (safe for client accounts).
RUN npm install -g \
        vercel \
        netlify-cli \
        firebase-tools \
        wrangler \
        @anthropic-ai/claude-code \
    && npm cache clean --force

# Seed login/session from the read-only host mount into the writable home.
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
# Friendly reminder if someone types `airlock` while already inside the sandbox.
COPY in-container.sh /usr/local/bin/airlock
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/airlock

# The base image already ships a non-root `node` user (uid/gid 1000).
USER node
ENV HOME=/home/node
WORKDIR /workspace

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["bash"]
