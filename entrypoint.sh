#!/usr/bin/env bash
# airlock entrypoint — seed Claude login when AIRLOCK_SEED_CLAUDE=1.
#
# DEV mode mounts your full ~/.claude (history + config) read-only -> Claude
# reuses your whole session. UNTRUSTED mode mounts ONLY the login token, so
# Claude is logged in but your past conversations are NOT exposed to untrusted
# code; a minimal ~/.claude.json is generated to skip onboarding.
#
# Anything Claude writes (token refresh, new history) stays in the ephemeral
# container and is discarded on exit — never written back to the host.
set -e

if [ "${AIRLOCK_SEED_CLAUDE:-0}" = "1" ]; then
  mkdir -p "$HOME/.claude"

  # Full session/history (DEV mode only — this mount is absent in untrusted).
  if [ -d /host-claude ]; then
    cp -a /host-claude/. "$HOME/.claude/" 2>/dev/null || true
  fi

  # Login token (both modes). Copied last so it always wins.
  if [ -s /host-claude-creds.json ]; then
    cp /host-claude-creds.json "$HOME/.claude/.credentials.json" 2>/dev/null || true
  fi

  # Config: real one in dev mode; minimal generated one in untrusted mode so
  # Claude doesn't treat it as a fresh install and force re-login.
  if [ -f /host-claude.json ]; then
    cp /host-claude.json "$HOME/.claude.json" 2>/dev/null || true
  elif [ ! -f "$HOME/.claude.json" ]; then
    printf '{"hasCompletedOnboarding":true}\n' > "$HOME/.claude.json"
  fi

  chmod -R u+rw "$HOME/.claude" "$HOME/.claude.json" 2>/dev/null || true
fi

exec "$@"
