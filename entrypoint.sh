#!/usr/bin/env bash
# airlock entrypoint — seed the Claude login when AIRLOCK_SEED_CLAUDE=1.
#
# The login TOKEN is mounted from the host read-only; refreshes stay in the
# container's home and are never written back to the host.
#
# run: your global CLAUDE.md is a read-only copy, and history lives in this
#      client's /home/node volume (or a tmpfs with --ephemeral), so one
#      client's transcripts are never readable inside another's sandbox.
# dev: AIRLOCK_HOST_CLAUDE=1 links history and memory to the Mac's own
#      ~/.claude (mounted at /host-claude), read-write — see below.
set -e

# Link the baked native Claude binary into $HOME so its launcher path
# $HOME/.local/bin/claude exists. The real ~225MB self-contained binary lives
# read-only in /opt (see Dockerfile). Idempotent: safe on a persistent home
# volume, required on an ephemeral tmpfs one.
if [ -x /opt/claude/claude ]; then
  mkdir -p "$HOME/.local/bin"
  ln -sf /opt/claude/claude "$HOME/.local/bin/claude"
fi

if [ "${AIRLOCK_SEED_CLAUDE:-0}" = "1" ]; then
  mkdir -p "$HOME/.claude"

  creds="$HOME/.claude/.credentials.json"
  if [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
    # Long-lived token from `airlock login`: nothing refreshes it, so the Mac
    # and the sandboxes can't invalidate each other. Drop any copied OAuth
    # file so a stale one can never be picked over it.
    rm -f "$creds"
  elif [ -s /host-claude-creds.json ]; then
    # Keychain OAuth copy. The Mac and every sandbox share ONE refresh token,
    # and a refresh invalidates the old one — so only the side that refreshed
    # last holds a working login. Blindly copying the host file each spin put
    # a dead token into new sandboxes ("Login expired" seconds after start).
    # Keep whichever copy expires later: that's the one refreshed last.
    host_exp="$(jq -r '.claudeAiOauth.expiresAt // 0' /host-claude-creds.json 2>/dev/null || echo 0)"
    vol_exp="$(jq -r '.claudeAiOauth.expiresAt // 0' "$creds" 2>/dev/null || echo 0)"
    if [ "${host_exp:-0}" -ge "${vol_exp:-0}" ] 2>/dev/null || [ ! -s "$creds" ]; then
      cp /host-claude-creds.json "$creds" 2>/dev/null || true
    fi
    chmod 600 "$creds" 2>/dev/null || true
  fi

  # Your global CLAUDE.md, refreshed every spin so host edits always win over
  # whatever a previous session (or an agent) left in the persistent home.
  # Skipped in dev, where CLAUDE.md is the host file itself (linked below).
  if [ "${AIRLOCK_HOST_CLAUDE:-0}" != "1" ] && [ -s /host-claude-md ]; then
    cp /host-claude-md "$HOME/.claude/CLAUDE.md" 2>/dev/null || true
  fi

  # Minimal config on first run so Claude doesn't treat this as a fresh
  # install and force re-login. On a persistent home this is written once.
  if [ ! -f "$HOME/.claude.json" ]; then
    printf '{"hasCompletedOnboarding":true}\n' > "$HOME/.claude.json"
  fi
fi

# Host history + memory (dev mode only, AIRLOCK_HOST_CLAUDE=1). Each piece of
# ~/.claude that holds history or memory is symlinked to the Mac's copy, so
# what Claude writes here lands on the Mac and survives the container:
#   projects/       session transcripts (claude --resume) + per-project memory
#   file-history/   checkpoints, so /rewind works on a resumed session
#   history.jsonl   prompt history (up-arrow)
#   CLAUDE.md       your global instructions
# Everything else (.credentials.json, settings.json, plugins) stays in the
# client volume: no plaintext token is ever written into the Mac's ~/.claude,
# and the Mac's settings (host paths, hooks) never run in here.
HOST_CLAUDE="${AIRLOCK_HOST_CLAUDE_MOUNT:-/host-claude}"
link_host_claude() {  # $1 = name under ~/.claude   $2 = dir|file
  local src="$HOST_CLAUDE/$1" dst="$HOME/.claude/$1"
  if [ "$2" = dir ]; then
    mkdir -p "$src"
  elif [ ! -e "$src" ]; then
    (umask 077; : > "$src")
  fi
  # Whatever the volume held before this was linked (sessions from older
  # airlock versions) is set aside, never deleted.
  if [ -e "$dst" ] && [ ! -L "$dst" ]; then
    mv "$dst" "$dst.pre-host.$(date +%Y%m%d-%H%M%S)"
  fi
  ln -sfn "$src" "$dst"
}
if [ "${AIRLOCK_HOST_CLAUDE:-0}" = "1" ] && [ -d "$HOST_CLAUDE" ]; then
  mkdir -p "$HOME/.claude"
  link_host_claude projects dir
  link_host_claude file-history dir
  link_host_claude history.jsonl file
fi

# Global CLAUDE.md in dev: the wrapper mounts the REAL file read-write at
# /host-claude-md-rw. Not linked through /host-claude: your ~/.claude/CLAUDE.md
# can be a symlink (e.g. into a rules repo), and that target path doesn't exist
# in here, so the link dangled and dev's Claude saw no CLAUDE.md at all.
if [ "${AIRLOCK_HOST_CLAUDE:-0}" = "1" ] && [ -f /host-claude-md-rw ]; then
  mkdir -p "$HOME/.claude"
  md="$HOME/.claude/CLAUDE.md"
  if [ -e "$md" ] && [ ! -L "$md" ]; then
    mv "$md" "$md.pre-host.$(date +%Y%m%d-%H%M%S)"
  fi
  ln -sfn /host-claude-md-rw "$md"
fi

# Per-project sessions on the Mac (run mode). The wrapper mounts ONLY this
# project's ~/.claude/projects/<key>/ at /host-sessions (memory/ read-only),
# and the project sits at its Mac path, so Claude's own lookup for "sessions
# of this folder" lands on the Mac copy. Each project keeps its own history,
# it survives --rm and --ephemeral, and `claude --resume` works on both sides.
if [ -n "${AIRLOCK_SESSION_KEY:-}" ] && [ -d /host-sessions ]; then
  mkdir -p "$HOME/.claude/projects"
  dst="$HOME/.claude/projects/$AIRLOCK_SESSION_KEY"
  if [ -e "$dst" ] && [ ! -L "$dst" ]; then
    # Sessions this client's volume already held for this exact path move to
    # the Mac (never overwriting); the old folder is set aside, not deleted.
    for f in "$dst"/*.jsonl; do
      [ -e "$f" ] && [ ! -e "/host-sessions/${f##*/}" ] && cp -p "$f" /host-sessions/ 2>/dev/null || true
    done
    mv "$dst" "$dst.pre-host.$(date +%Y%m%d-%H%M%S)"
  fi
  ln -sfn /host-sessions "$dst"
fi

# zsh: all config is global (/etc/zsh/airlock.zsh). An empty ~/.zshrc stops
# zsh's first-run "new user" wizard from taking over the terminal.
[ -e "$HOME/.zshrc" ] || printf '# airlock: shared config lives in /etc/zsh/airlock.zsh — add your own below.\n' > "$HOME/.zshrc"

# Statusline (both modes, AIRLOCK_STATUSLINE=1). The script is baked into
# the image at /opt/airlock — nothing here reads the host's ~/.claude, so dev
# gets the same status bar without any access to your Mac's Claude config.
# Merged into settings.json rather than overwriting it, so anything you set
# inside the sandbox survives the next spin.
if [ "${AIRLOCK_STATUSLINE:-0}" = "1" ] && [ -x /opt/airlock/statusline-command.sh ]; then
  mkdir -p "$HOME/.claude"
  settings="$HOME/.claude/settings.json"
  baked='{"statusLine":{"type":"command","command":"bash /opt/airlock/statusline-command.sh","padding":1,"refreshInterval":30}}'
  if [ -s "$settings" ] && jq -e . "$settings" >/dev/null 2>&1; then
    tmp="$(mktemp)"
    if jq --argjson s "$baked" '. * $s' "$settings" > "$tmp" 2>/dev/null; then
      mv "$tmp" "$settings"
    else
      rm -f "$tmp"
    fi
  else
    printf '%s\n' "$baked" > "$settings"
  fi
fi

# Port forwarder (AIRLOCK_FORWARD=1). Backgrounded; it polls /proc and only
# binds a port when a loopback-only listener appears, so it costs nothing when
# no dev server is running and never fights one that binds 0.0.0.0 itself.
if [ "${AIRLOCK_FORWARD:-0}" = "1" ] && [ -f /opt/airlock/portforward.mjs ]; then
  node /opt/airlock/portforward.mjs >/dev/null 2>&1 &
fi

exec "$@"
