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
echo "✓ .secrets ready"

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

# 5) build images -------------------------------------------------------------
echo ""
echo "▶ building images (first build ~3–5 min)…"
( cd "$DIR" && docker compose --profile run --profile dev build )

# 6) quick self-test: whitelist blocks a random host --------------------------
echo ""
echo "▶ self-test: confirming the egress whitelist blocks unknown hosts…"
if WORKSPACE=/tmp docker compose -f "$DIR/docker-compose.yml" --profile run run --rm -T untrusted \
     bash -c 'curl -sS -o /dev/null --max-time 15 https://example.com' >/dev/null 2>&1; then
  echo "⚠️  warning: example.com was reachable — whitelist may not be enforcing!"
else
  echo "✓ blocked example.com as expected"
fi
( cd "$DIR" && docker compose --profile run down --remove-orphans >/dev/null 2>&1 || true )

cat <<EOF

✅ airlock is ready.

   Open a NEW terminal (or run: source ~/.zshrc), then:

     cd <a project you want to run>
     airlock run      # UNTRUSTED: locked down, whitelist network
     airlock dev      # YOUR code: Claude + full internet
     airlock status   # see what's running and whether it's safe
     airlock --help   # all commands

   First run pops a macOS Keychain prompt for your Claude login → "Always Allow".
EOF
