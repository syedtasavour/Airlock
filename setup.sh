#!/usr/bin/env bash
# airlock setup — get airlock working on a fresh / reset Mac.
#
# Prereq: you already restored this folder (from backup or `git clone`) to
# somewhere like ~/sandbox/airlock. Then just run:  bash setup.sh
#
# Idempotent: safe to run again any time.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
arch="$(uname -m)"
[ "$arch" = "arm64" ] && dmg="arm64" || dmg="amd64"

echo "▶ airlock setup  ($DIR)"
echo ""

# 1) Docker present & running -------------------------------------------------
if ! command -v docker >/dev/null 2>&1; then
  cat <<EOF
✗ Docker is not installed.

  Install Docker Desktop for your Mac ($arch), then re-run this script:
    https://desktop.docker.com/mac/main/$dmg/Docker.dmg

  Install from the terminal (needs your admin password):
    curl -L -o ~/Downloads/Docker.dmg "https://desktop.docker.com/mac/main/$dmg/Docker.dmg"
    sudo hdiutil attach ~/Downloads/Docker.dmg
    sudo /Volumes/Docker/Docker.app/Contents/MacOS/install --accept-license
    sudo hdiutil detach /Volumes/Docker
    open -a Docker        # wait ~30s for the engine

  Then run:  bash "$DIR/setup.sh"
EOF
  exit 1
fi

if ! docker info >/dev/null 2>&1; then
  echo "✗ Docker is installed but the engine isn't running."
  echo "  Start it:  open -a Docker   (wait ~30s), then re-run: bash \"$DIR/setup.sh\""
  exit 1
fi
echo "✓ Docker is installed and running"

# 2) secrets dir (Claude token lands here in dev/run; git-ignored) ------------
mkdir -p "$DIR/.secrets"; chmod 700 "$DIR/.secrets"
[ -f "$DIR/.secrets/.credentials.json" ] || : > "$DIR/.secrets/.credentials.json"
chmod 600 "$DIR/.secrets/.credentials.json"
mkdir -p "$DIR/.logs"   # proxy logs for `airlock blocked`
echo "✓ .secrets + .logs ready"

# 3) make scripts executable --------------------------------------------------
chmod +x "$DIR/airlock" "$DIR/entrypoint.sh" "$DIR/in-container.sh" "$DIR/setup.sh" 2>/dev/null || true
echo "✓ scripts executable"

# 4) shell alias --------------------------------------------------------------
add_alias() {
  local rc="$1"
  [ -e "$rc" ] || return 0
  if grep -q 'alias airlock=' "$rc" 2>/dev/null; then
    echo "✓ alias already present in $rc"
  else
    printf '\n# airlock — disposable hardened sandbox\nalias airlock="%s/airlock"\n' "$DIR" >> "$rc"
    echo "✓ alias added to $rc"
  fi
}
add_alias "$HOME/.zshrc"
add_alias "$HOME/.bashrc"

# 4b) habit guard: npm/pnpm/yarn/npx/bun/node typed inside a project on the
# Mac asks to run in airlock instead. Undo any time: airlock guard off
"$DIR/airlock" guard on | sed 's/^/  /'

# 5) build images -------------------------------------------------------------
echo ""
echo "▶ building images (first build ~3–5 min)…"
( cd "$DIR" && docker compose -f docker-compose.yml -f docker-compose.home-persistent.yml \
    --profile run --profile dev build )

# 6) quick self-test: whitelist blocks a random host --------------------------
echo ""
echo "▶ self-test: confirming the egress whitelist blocks unknown hosts…"
mkdir -p "$DIR/.state/selftest" "$DIR/.state/no-sessions/memory"
# not /tmp: the sandbox mounts the project at its own path, and /tmp is its tmpfs
if WORKSPACE="$DIR/.state/selftest" docker compose -f "$DIR/docker-compose.yml" \
     -f "$DIR/docker-compose.home-ephemeral.yml" --profile run run --rm -T untrusted \
     bash -c 'curl -sS -o /dev/null --max-time 15 https://example.com' >/dev/null 2>&1; then
  echo "⚠️  warning: example.com was reachable — whitelist may not be enforcing!"
else
  echo "✓ blocked example.com as expected"
fi
( cd "$DIR" && docker compose -f docker-compose.yml -f docker-compose.home-ephemeral.yml \
    --profile run down --remove-orphans >/dev/null 2>&1 || true )

cat <<EOF

✅ airlock is ready.

   Open a NEW terminal (or run: source ~/.zshrc), then:

     cd <a project you want to run>
     airlock run              # UNTRUSTED: locked down, whitelist network
     airlock dev              # YOUR code: full internet
     airlock run --ephemeral  # deploy sessions: logins die on exit
     airlock status           # what's running, ports, client home volumes
     airlock disk             # what's using Docker's disk (cleans itself daily)
     airlock --help           # all commands

   Multi-client: each project gets its own ports + proxy; each client gets its
   own home volume (caches + Claude history), resolved from \$AIRLOCK_CLIENT,
   a .airlock-client file, or the project's parent directory name.

   First run pops a macOS Keychain prompt for your Claude login → "Always Allow".
EOF
