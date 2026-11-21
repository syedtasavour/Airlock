#!/usr/bin/env bash
# Shown when someone types `airlock ...` INSIDE the sandbox container.
# `airlock` is a host-only command — inside, you use the tools directly.
# AIRLOCK_SANDBOX (run|dev) is set by docker-compose.yml.

case "${AIRLOCK_SANDBOX:-}" in
  dev)
    mode="TRUSTED (dev)"
    net="Networking: full internet (trusted mode — not for untrusted code)."
    ;;
  run)
    mode="UNTRUSTED (run)"
    net="Networking: outbound goes through a whitelist proxy — only approved
  domains work. On the host: \`airlock blocked\` / \`airlock allow <domain>\`."
    ;;
  *)
    mode="sandbox"
    net="Networking: depends on the mode you launched (run = whitelist, dev = full)."
    ;;
esac

# Ephemeral homes are a tmpfs; persistent ones are a named volume.
if awk '$2 == "/home/node" && $3 == "tmpfs" { found = 1 } END { exit !found }' /proc/mounts 2>/dev/null; then
  home="Type \`exit\` to leave — the container AND your home are destroyed
  (logins, caches and Claude history are gone)."
else
  home="Type \`exit\` to leave — the container is destroyed, but this client's
  home volume (logins, caches, nvm versions, Claude history) is kept.
  Wipe it from the host with \`airlock reset\` or \`airlock run --fresh\`."
fi

cat <<EOF

  ✓ You're already INSIDE the airlock sandbox — ${mode}.
    Your working dir is the project you opened.

  No need for \`airlock\` in here. Just use the tools directly:

    node $(node -v 2>/dev/null) · pnpm · npm   run & build the project
    nvm install <ver>                switch Node version
    vercel · netlify · heroku        deploy CLIs
    firebase · wrangler              more deploy CLIs
    claude                           Claude Code (logged in, sessions saved on your Mac)

  Dev servers: open http://localhost:<port> on your Mac — no --host flag needed.
  Published: 3000-3005 4000 4173 4200 4321 5000-5001 5173-5175 6006 8000
             8080-8081 8787 9000 (1:1 unless the launch banner says one moved)

  ${net}

  ${home}

  airlock commands (run them in a terminal on your Mac):
    airlock run | dev       start a sandbox here    airlock exec    another terminal into it
    airlock allow           unblock a site          airlock blocked what was blocked
    airlock status          what's running          airlock disk    Docker disk usage
    airlock update          latest Node/Claude/CLIs airlock help    everything else

EOF
