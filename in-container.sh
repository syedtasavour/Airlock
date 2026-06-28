#!/usr/bin/env bash
# Shown when someone types `airlock ...` INSIDE the sandbox container.
# `airlock` is a host-only command — inside, you use the tools directly.
cat <<'EOF'

  ✓ You're already INSIDE the airlock sandbox (/workspace = the project you opened).

  No need for `airlock` in here. Just use the tools directly:

    node / npm / pnpm / yarn        run & build the project
    vercel · netlify · heroku       deploy CLIs (log in fresh each spin)
    firebase · wrangler             more deploy CLIs
    claude                          Claude Code (dev mode only)

  Networking: outbound goes through a whitelist proxy — only approved domains
  work. Type `exit` to leave; the container is destroyed (fresh next spin).

EOF
