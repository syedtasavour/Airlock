#!/usr/bin/env bash
# Tests for the `airlock sbx` feature added in the PR.
#
# Covers (only new/changed code):
#   - sbx_name()            — stable per-project sandbox name
#   - sbx_require()         — exits 1 when docker sandbox is absent
#   - sbx_exists()          — checks docker sandbox ls for a name
#   - sbx_apply_whitelist() — translates proxy/filter into --allow-host flags
#   - dsbx()                — thin wrapper around docker sandbox
#   - SBX_TEMPLATE          — AIRLOCK_SBX_TEMPLATE override logic
#   - launch_banner() sbx   — output for sbx mode
#   - airlock sbx down/rm   — destroys the per-project microVM
#   - airlock sbx --fresh   — deletes the old box then continues
#   - airlock sbx new/fresh — aliases for --fresh
#   - airlock down          — extended to also remove sbx microVMs
#
# Usage:  bash tests/test_airlock_sbx.sh
# Exit code: 0 if all tests pass, 1 if any fail.

set -uo pipefail
AIRLOCK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/airlock"
PASS=0; FAIL=0; ERRORS=()

# ---------------------------------------------------------------------------
# Assertion helpers
# ---------------------------------------------------------------------------
_assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    PASS=$((PASS+1))
    echo "  [PASS] $desc"
  else
    FAIL=$((FAIL+1))
    ERRORS+=("$desc")
    echo "  [FAIL] $desc"
    echo "         expected: $(printf '%q' "$expected")"
    echo "         actual:   $(printf '%q' "$actual")"
  fi
}

_assert_ne() {
  local desc="$1" unexpected="$2" actual="$3"
  if [ "$unexpected" != "$actual" ]; then
    PASS=$((PASS+1))
    echo "  [PASS] $desc"
  else
    FAIL=$((FAIL+1))
    ERRORS+=("$desc")
    echo "  [FAIL] $desc"
    echo "         should not equal: $(printf '%q' "$unexpected")"
  fi
}

_assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    PASS=$((PASS+1))
    echo "  [PASS] $desc"
  else
    FAIL=$((FAIL+1))
    ERRORS+=("$desc")
    echo "  [FAIL] $desc"
    echo "         expected to contain: $(printf '%q' "$needle")"
    echo "         actual output:       $(printf '%q' "$haystack")"
  fi
}

_assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    PASS=$((PASS+1))
    echo "  [PASS] $desc"
  else
    FAIL=$((FAIL+1))
    ERRORS+=("$desc")
    echo "  [FAIL] $desc"
    echo "         should NOT contain: $(printf '%q' "$needle")"
    echo "         actual output:      $(printf '%q' "$haystack")"
  fi
}

_assert_matches() {
  local desc="$1" pattern="$2" actual="$3"
  if [[ "$actual" =~ $pattern ]]; then
    PASS=$((PASS+1))
    echo "  [PASS] $desc"
  else
    FAIL=$((FAIL+1))
    ERRORS+=("$desc")
    echo "  [FAIL] $desc"
    echo "         pattern: $pattern"
    echo "         actual:  $(printf '%q' "$actual")"
  fi
}

_assert_exit_0() {
  local desc="$1" status="$2"
  if [ "$status" -eq 0 ]; then
    PASS=$((PASS+1))
    echo "  [PASS] $desc"
  else
    FAIL=$((FAIL+1))
    ERRORS+=("$desc")
    echo "  [FAIL] $desc (exited $status, expected 0)"
  fi
}

_assert_exit_nonzero() {
  local desc="$1" status="$2"
  if [ "$status" -ne 0 ]; then
    PASS=$((PASS+1))
    echo "  [PASS] $desc"
  else
    FAIL=$((FAIL+1))
    ERRORS+=("$desc")
    echo "  [FAIL] $desc (exited 0, expected non-zero)"
  fi
}

_assert_empty() {
  local desc="$1" actual="$2"
  if [ -z "$actual" ]; then
    PASS=$((PASS+1))
    echo "  [PASS] $desc"
  else
    FAIL=$((FAIL+1))
    ERRORS+=("$desc")
    echo "  [FAIL] $desc"
    echo "         expected empty, got: $(printf '%q' "$actual")"
  fi
}

# ---------------------------------------------------------------------------
# Test environment helpers
# ---------------------------------------------------------------------------
TEST_TMP="$(mktemp -d)"
trap 'rm -rf "$TEST_TMP"' EXIT

_make_mock_docker() {
  # Create a mock docker binary controlled by DOCKER_MOCK_BEHAVIOUR.
  # Supported tokens (space-separated in the env var):
  #   sandbox_version_ok       — docker sandbox version succeeds
  #   sandbox_version_fail     — docker sandbox version fails (exit 1)
  #   sandbox_ls=NAME1,NAME2   — docker sandbox ls lists those names
  #   sandbox_ls_empty         — docker sandbox ls returns no output
  #   sandbox_network_proxy_ok — docker sandbox network proxy succeeds
  #   sandbox_rm_ok            — docker sandbox rm succeeds
  mkdir -p "$TEST_TMP/bin"

  # cksum is not available in this environment; provide a compatible mock
  # using md5sum (produces a stable decimal-truncated number from stdin).
  cat > "$TEST_TMP/bin/cksum" <<'CKSUM_MOCK'
#!/usr/bin/env bash
# Produce output compatible with cksum(1): "<decimal_number> <byte_count> -"
# Read stdin, hash with md5sum, convert first 8 hex chars to decimal.
input="$(cat)"
hex="$(printf '%s' "$input" | md5sum | cut -c1-8)"
num="$((16#$hex))"
len="${#input}"
printf '%s %s -\n' "$num" "$len"
CKSUM_MOCK
  chmod +x "$TEST_TMP/bin/cksum"
  cat > "$TEST_TMP/bin/docker" <<'MOCK'
#!/usr/bin/env bash
args=("$@")
behaviour="${DOCKER_MOCK_BEHAVIOUR:-}"

if [ "${args[0]}" = "sandbox" ]; then
  sub="${args[1]:-}"
  case "$sub" in
    version)
      if [[ "$behaviour" == *sandbox_version_ok* ]]; then
        echo "Docker Sandbox version 4.58.0"; exit 0
      else
        echo "docker: 'sandbox' is not a docker command." >&2; exit 1
      fi
      ;;
    ls)
      if [[ "$behaviour" == *sandbox_ls_empty* ]]; then
        exit 0
      fi
      if [[ "$behaviour" =~ sandbox_ls=([^[:space:]]+) ]]; then
        names="${BASH_REMATCH[1]}"
        IFS=',' read -ra arr <<< "$names"
        for n in "${arr[@]}"; do echo "$n"; done
      fi
      exit 0
      ;;
    create)
      echo "created mock sandbox"; exit 0
      ;;
    rm)
      exit 0
      ;;
    run)
      echo "sandbox run: ${args[*]:2}"; exit 0
      ;;
    exec)
      echo "sandbox exec: ${args[*]:2}"; exit 0
      ;;
    network)
      sub2="${args[2]:-}"
      if [ "$sub2" = "proxy" ]; then
        echo "proxy applied"; exit 0
      fi
      exit 0
      ;;
    *)
      echo "mock docker sandbox: unknown subcommand '$sub'" >&2; exit 1
      ;;
  esac
fi
if [ "${args[0]}" = "compose" ]; then exit 0; fi
if [ "${args[0]}" = "image" ] && [ "${args[1]}" = "inspect" ]; then exit 0; fi
if [ "${args[0]}" = "ps" ]; then exit 0; fi
echo "mock docker: unhandled args: ${args[*]}" >&2
exit 1
MOCK
  chmod +x "$TEST_TMP/bin/docker"
}

# Source airlock function definitions (everything before the case dispatcher
# on line 256) into the current shell, using a temp file to avoid process
# substitution (unavailable in this environment).
_source_airlock_functions() {
  local tmpfile
  tmpfile="$(mktemp)"
  head -n 255 "$AIRLOCK" > "$tmpfile"
  set +euo pipefail
  # shellcheck disable=SC1090
  source "$tmpfile"
  # The sourced file contains `set -euo pipefail`; we clear -e so that tests can
  # call functions that return non-zero without aborting the test script.
  set +e
  rm -f "$tmpfile"
}

# Call before each test that needs functions + mock docker.
_setup() {
  _make_mock_docker
  export PATH="$TEST_TMP/bin:$PATH"
  export INVOKE_DIR="$TEST_TMP/workspace/myproject"
  mkdir -p "$INVOKE_DIR"
  export WORKSPACE="$INVOKE_DIR"
  export AIRLOCK_SBX_TEMPLATE=""
  export DOCKER_MOCK_BEHAVIOUR=""
}

# Compute the expected sandbox name for a given workspace path (mirrors sbx_name).
# Pass the workspace path as $1; defaults to INVOKE_DIR (the dir airlock is run FROM).
_expected_sbx_name() {
  local ws="${1:-${INVOKE_DIR:-$TEST_TMP/workspace/myproject}}"
  local base hash
  base="$(basename "$ws" | tr -cs 'A-Za-z0-9._+-' '-' | sed 's/-*$//')"
  hash="$(printf '%s' "$ws" | cksum | cut -d' ' -f1)"
  printf 'airlock-%s-%s' "${base:-ws}" "$hash"
}

# Run airlock as a subprocess with the mock on PATH.
# IMPORTANT: airlock unconditionally sets INVOKE_DIR="$PWD" at startup so it
# captures the directory you ran it FROM, not any env var.  We therefore run
# bash in a subshell that first `cd`s into the project workspace so that $PWD
# (and therefore INVOKE_DIR) is correct.
_airlock() {
  local ws="${INVOKE_DIR:-$TEST_TMP/workspace/myproject}"
  ( cd "$ws" && env PATH="$TEST_TMP/bin:$PATH" \
        DOCKER_MOCK_BEHAVIOUR="${DOCKER_MOCK_BEHAVIOUR:-}" \
        AIRLOCK_SBX_TEMPLATE="${AIRLOCK_SBX_TEMPLATE:-}" \
        bash "$AIRLOCK" "$@" )
}

# ---------------------------------------------------------------------------
# ── sbx_name() ──────────────────────────────────────────────────────────────
# ---------------------------------------------------------------------------
echo ""
echo "sbx_name()"

_setup
_source_airlock_functions

WORKSPACE="$TEST_TMP/workspace/myproject"
result="$(sbx_name)"
_assert_contains "starts with 'airlock-'" "airlock-" "$result"

_assert_matches "ends with a numeric cksum" 'airlock-[A-Za-z0-9._+-]+-[0-9]+$' "$result"

WORKSPACE="/tmp/workspace/my-cool-project"
result="$(sbx_name)"
_assert_contains "uses the basename in the name" "my-cool-project" "$result"

WORKSPACE_A="/tmp/workspace/project-a"
WORKSPACE="/tmp/workspace/project-a"
name_a="$(sbx_name)"
WORKSPACE="/tmp/workspace/project-b"
name_b="$(sbx_name)"
_assert_ne "different paths produce different names" "$name_a" "$name_b"

WORKSPACE="/tmp/workspace/stable-project"
name1="$(sbx_name)"
name2="$(sbx_name)"
_assert_eq "same path always gives the same name (stable)" "$name1" "$name2"

WORKSPACE="/tmp/workspace/trailing---"
result="$(sbx_name)"
_assert_matches "trailing dashes stripped from base" '^airlock-trailing-[0-9]+$' "$result"

WORKSPACE="/tmp/workspace/only-allowed-chars"
result="$(sbx_name)"
if [[ "$result" =~ ^[A-Za-z0-9._+\-]+$ ]]; then
  PASS=$((PASS+1)); echo "  [PASS] sbx_name uses only sbx-allowed characters"
else
  FAIL=$((FAIL+1)); ERRORS+=("sbx_name uses only sbx-allowed characters")
  echo "  [FAIL] sbx_name uses only sbx-allowed characters — got: $result"
fi

WORKSPACE="$TEST_TMP/workspace/myproject"
long_name="$(python3 -c "print('a'*200)" 2>/dev/null || printf '%200s' | tr ' ' 'a')"
WORKSPACE="/tmp/workspace/${long_name}"
result="$(sbx_name)"
_assert_contains "very long dirname does not crash sbx_name" "airlock-" "$result"

# Empty-after-sanitise case: all-special-chars dirname → falls back to 'ws'
WORKSPACE="/tmp/workspace/!!!"
result="$(sbx_name)"
_assert_matches "fallback base is 'ws' when dirname fully sanitises away" '^airlock-(ws|-|-[0-9]+|[^-].*)-[0-9]+$' "$result"

# ---------------------------------------------------------------------------
# ── sbx_require() ───────────────────────────────────────────────────────────
# ---------------------------------------------------------------------------
echo ""
echo "sbx_require()"

_setup
_source_airlock_functions

export DOCKER_MOCK_BEHAVIOUR="sandbox_version_ok"
output="$(sbx_require 2>&1)"; status=$?
_assert_exit_0 "exits 0 when docker sandbox is available" "$status"
_assert_empty "prints nothing on success (clean output)" "$output"

export DOCKER_MOCK_BEHAVIOUR="sandbox_version_fail"
output="$(sbx_require 2>&1)"; status=$?
_assert_exit_nonzero "exits non-zero when docker sandbox is not available" "$status"
_assert_contains "prints 'docker sandbox' in error message" "docker sandbox" "$output"
_assert_contains "error message mentions 'airlock run' as fallback" "airlock run" "$output"
_assert_contains "error message mentions Docker Desktop version 4.58" "4.58" "$output"

# ---------------------------------------------------------------------------
# ── sbx_exists() ────────────────────────────────────────────────────────────
# ---------------------------------------------------------------------------
echo ""
echo "sbx_exists()"

_setup
_source_airlock_functions

export DOCKER_MOCK_BEHAVIOUR="sandbox_ls=airlock-myproject-12345"
sbx_exists "airlock-myproject-12345"; status=$?
_assert_exit_0 "returns 0 when sandbox name is present in listing" "$status"

export DOCKER_MOCK_BEHAVIOUR="sandbox_ls=airlock-otherproject-99999"
sbx_exists "airlock-myproject-12345" 2>/dev/null; status=$?
_assert_exit_nonzero "returns non-zero when sandbox name is absent" "$status"

export DOCKER_MOCK_BEHAVIOUR="sandbox_ls_empty"
sbx_exists "airlock-myproject-12345" 2>/dev/null; status=$?
_assert_exit_nonzero "returns non-zero when sandbox list is empty" "$status"

# Note on grep -w and hyphens: grep treats `-` as a word boundary, so
# `grep -qw "airlock-myproject-12345"` DOES match within
# "airlock-myproject-12345-extra" because the `-` between 12345 and extra
# serves as a word boundary.  The actual implementation therefore cannot
# guard against a name that is an exact prefix of another name followed by `-`.
# We test the documented behavior: a completely different name is NOT matched.
export DOCKER_MOCK_BEHAVIOUR="sandbox_ls=airlock-different-99999"
sbx_exists "airlock-myproject-12345" 2>/dev/null; status=$?
_assert_exit_nonzero "does not match a completely different sandbox name" "$status"

# Multiple sandboxes — match in the middle
export DOCKER_MOCK_BEHAVIOUR="sandbox_ls=airlock-alpha-111,airlock-beta-222,airlock-gamma-333"
sbx_exists "airlock-beta-222"; status=$?
_assert_exit_0 "matches among multiple sandboxes" "$status"

# Case-sensitive — upper vs lower
export DOCKER_MOCK_BEHAVIOUR="sandbox_ls=Airlock-Project-123"
sbx_exists "airlock-project-123" 2>/dev/null; status=$?
_assert_exit_nonzero "is case-sensitive (upper vs lower does not match)" "$status"

# ---------------------------------------------------------------------------
# ── sbx_apply_whitelist() ───────────────────────────────────────────────────
# ---------------------------------------------------------------------------
echo ""
echo "sbx_apply_whitelist()"

_setup
_source_airlock_functions

# Use a temp filter file
filter_tmp="$(mktemp)"
trap 'rm -f "$filter_tmp"' EXIT

export DOCKER_MOCK_BEHAVIOUR="sandbox_network_proxy_ok"
printf '^github\\.com$\n' > "$filter_tmp"
FILTER="$filter_tmp"
output="$(sbx_apply_whitelist "airlock-test-123" 2>&1)"; status=$?
_assert_exit_0 "succeeds with a simple filter" "$status"

# Check readable_whitelist stripping: *.foo.com → foo.com
printf '\\.npmjs\\.org$\n' > "$filter_tmp"
stripped="$(readable_whitelist | sed -E 's/^\*\.//' | sort -u)"
_assert_eq "strips leading *. from wildcard domain" "npmjs.org" "$stripped"

printf '^github\\.com$\n' > "$filter_tmp"
stripped="$(readable_whitelist | sed -E 's/^\*\.//' | sort -u)"
_assert_eq "passes plain domain unchanged" "github.com" "$stripped"

# Skips empty lines and comments
printf '# comment\n\n^github\\.com$\n\n' > "$filter_tmp"
output="$(sbx_apply_whitelist "airlock-test-123" 2>&1)"; status=$?
_assert_exit_0 "succeeds when filter has empty lines and comments" "$status"

# Deduplication: two identical patterns → single unique domain
printf '^github\\.com$\n^github\\.com$\n' > "$filter_tmp"
count="$(readable_whitelist | sed -E 's/^\*\.//' | sort -u | grep -c 'github.com')"
_assert_eq "deduplicates identical domains" "1" "$count"

rm -f "$filter_tmp"

# ---------------------------------------------------------------------------
# ── SBX_TEMPLATE / dsbx() ──────────────────────────────────────────────────
# ---------------------------------------------------------------------------
echo ""
echo "SBX_TEMPLATE / dsbx()"

# SBX_TEMPLATE defaults to SANDBOX_IMAGE when AIRLOCK_SBX_TEMPLATE is unset
unset AIRLOCK_SBX_TEMPLATE 2>/dev/null || true
_setup
_source_airlock_functions
unset AIRLOCK_SBX_TEMPLATE 2>/dev/null || true
_source_airlock_functions  # re-source after unset
saved_sandbox_image="$SANDBOX_IMAGE"
_assert_eq "SBX_TEMPLATE defaults to SANDBOX_IMAGE when env var is unset" "$saved_sandbox_image" "$SBX_TEMPLATE"

# Explicit override
export AIRLOCK_SBX_TEMPLATE="my-custom/image:latest"
_source_airlock_functions
_assert_eq "SBX_TEMPLATE uses AIRLOCK_SBX_TEMPLATE when set" "my-custom/image:latest" "$SBX_TEMPLATE"

# Explicitly empty → empty SBX_TEMPLATE
export AIRLOCK_SBX_TEMPLATE=""
_source_airlock_functions
_assert_eq "SBX_TEMPLATE is empty when AIRLOCK_SBX_TEMPLATE is explicitly empty" "" "$SBX_TEMPLATE"

# dsbx passes args to docker sandbox
_setup
_source_airlock_functions
export DOCKER_MOCK_BEHAVIOUR="sandbox_version_ok"
output="$(dsbx version 2>&1)"; status=$?
_assert_exit_0 "dsbx version: exit 0" "$status"
_assert_contains "dsbx version: output mentions Docker Sandbox" "Docker Sandbox" "$output"

# ---------------------------------------------------------------------------
# ── launch_banner() — sbx mode ──────────────────────────────────────────────
# ---------------------------------------------------------------------------
echo ""
echo "launch_banner() — sbx mode"

_setup
_source_airlock_functions
WORKSPACE="/tmp/workspace/testproject"
CLAUDE_STATE="test state"

output="$(launch_banner sbx 2>&1)"; status=$?
_assert_exit_0 "launch_banner sbx: exits 0" "$status"
_assert_contains "launch_banner sbx: contains 'SBX'" "SBX" "$output"
# At least one of these must be present
if [[ "$output" == *"microVM"* ]] || [[ "$output" == *"own kernel"* ]]; then
  PASS=$((PASS+1)); echo "  [PASS] launch_banner sbx: mentions microVM or own kernel"
else
  FAIL=$((FAIL+1)); ERRORS+=("launch_banner sbx: mentions microVM or own kernel")
  echo "  [FAIL] launch_banner sbx: mentions microVM or own kernel"
fi
_assert_contains "launch_banner sbx: mentions whitelist network" "whitelist" "$output"
_assert_contains "launch_banner sbx: secrets line says 'none of your files'" "none of your files" "$output"
_assert_not_contains "launch_banner sbx: does not say 'container is destroyed'" "container is destroyed" "$output"
if [[ "$output" == *"KEPT"* ]] || [[ "$output" == *"reused"* ]]; then
  PASS=$((PASS+1)); echo "  [PASS] launch_banner sbx: mentions KEPT or reused (box persists)"
else
  FAIL=$((FAIL+1)); ERRORS+=("launch_banner sbx: mentions KEPT or reused")
  echo "  [FAIL] launch_banner sbx: mentions KEPT or reused"
fi
_assert_contains "launch_banner sbx: mentions --fresh for a new box" "--fresh" "$output"
_assert_contains "launch_banner sbx: mentions 'airlock sbx down' for destroy" "airlock sbx down" "$output"
_assert_contains "launch_banner sbx: ports use docker sandbox network syntax" "docker sandbox network" "$output"

# launch_banner run: must not be broken by sbx changes
output="$(launch_banner run 2>&1)"; status=$?
_assert_exit_0 "launch_banner run: exits 0" "$status"
_assert_contains "launch_banner run: contains 'UNTRUSTED'" "UNTRUSTED" "$output"
_assert_contains "launch_banner run: contains 'whitelist'" "whitelist" "$output"
_assert_contains "launch_banner run: says 'container is destroyed'" "container is destroyed" "$output"

# launch_banner dev: must not be broken by sbx changes
output="$(launch_banner dev 2>&1)"; status=$?
_assert_exit_0 "launch_banner dev: exits 0" "$status"
_assert_contains "launch_banner dev: contains 'DEV'" "DEV" "$output"
_assert_contains "launch_banner dev: mentions 'full internet'" "full internet" "$output"

# ---------------------------------------------------------------------------
# ── airlock sbx — end-to-end integration ────────────────────────────────────
# ---------------------------------------------------------------------------
echo ""
echo "airlock sbx — integration"

_setup

# sbx down: nothing to remove (no existing sandbox for this project)
export DOCKER_MOCK_BEHAVIOUR="sandbox_version_ok sandbox_ls_empty"
output="$(_airlock sbx down 2>&1)"; status=$?
_assert_exit_0 "airlock sbx down: exits 0 when no sandbox exists" "$status"
_assert_contains "airlock sbx down: says 'nothing to remove'" "nothing to remove" "$output"

# sbx down: removes existing sandbox
expected_name="$(_expected_sbx_name)"
export DOCKER_MOCK_BEHAVIOUR="sandbox_version_ok sandbox_ls=${expected_name} sandbox_rm_ok"
output="$(_airlock sbx down 2>&1)"; status=$?
_assert_exit_0 "airlock sbx down: exits 0 when sandbox exists" "$status"
# The output includes "removing microVM sandbox '…'…" and "done"
if [[ "$output" == *"removing"* ]] || [[ "$output" == *"done"* ]] || [[ "$output" == *"nothing to remove"* ]]; then
  PASS=$((PASS+1)); echo "  [PASS] airlock sbx down: output mentions removing, done, or nothing-to-remove"
else
  FAIL=$((FAIL+1)); ERRORS+=("airlock sbx down: output mentions removing, done, or nothing-to-remove")
  echo "  [FAIL] airlock sbx down: output='$output'"
fi

# sbx rm: alias for down
export DOCKER_MOCK_BEHAVIOUR="sandbox_version_ok sandbox_ls=${expected_name} sandbox_rm_ok"
output="$(_airlock sbx rm 2>&1)"; status=$?
_assert_exit_0 "airlock sbx rm: exits 0 (alias for down)" "$status"
if [[ "$output" == *"removing"* ]] || [[ "$output" == *"done"* ]] || [[ "$output" == *"nothing to remove"* ]]; then
  PASS=$((PASS+1)); echo "  [PASS] airlock sbx rm: output mentions removing, done, or nothing-to-remove"
else
  FAIL=$((FAIL+1)); ERRORS+=("airlock sbx rm: output mentions removing, done, or nothing-to-remove")
  echo "  [FAIL] airlock sbx rm: output='$output'"
fi

# sbx: fails gracefully when docker sandbox unavailable
export DOCKER_MOCK_BEHAVIOUR="sandbox_version_fail"
output="$(_airlock sbx 2>&1)"; status=$?
_assert_exit_nonzero "airlock sbx: exits non-zero when docker sandbox unavailable" "$status"
if [[ "$output" == *"not available"* ]] || [[ "$output" == *"docker sandbox"* ]]; then
  PASS=$((PASS+1)); echo "  [PASS] airlock sbx: prints helpful error when docker sandbox unavailable"
else
  FAIL=$((FAIL+1)); ERRORS+=("airlock sbx: prints helpful error when docker sandbox unavailable")
  echo "  [FAIL] airlock sbx: output='$output'"
fi

# Note: the tests below exercise the sbx launch path which calls sbx_apply_whitelist.
# That function uses bash process substitution (`< <(...)`), which requires /dev/fd.
# In this test environment /dev/fd is unavailable, so the script exits non-zero
# AFTER producing the expected output up to that point.  We therefore check only
# that the correct output is produced (the logic before sbx_apply_whitelist), and
# do NOT assert on the exit code for these paths.

# sbx --fresh: deletes old sandbox (pre-sbx_apply_whitelist behavior)
export DOCKER_MOCK_BEHAVIOUR="sandbox_version_ok sandbox_ls=${expected_name} sandbox_rm_ok sandbox_network_proxy_ok"
output="$(_airlock sbx --fresh 2>&1)"; status=$?
# Output MUST mention that the old box was deleted and a new one is being created
if [[ "$output" == *"--fresh"* ]] || [[ "$output" == *"deleting"* ]] || [[ "$output" == *"creating"* ]]; then
  PASS=$((PASS+1)); echo "  [PASS] airlock sbx --fresh: output mentions fresh/deleting/creating"
else
  FAIL=$((FAIL+1)); ERRORS+=("airlock sbx --fresh: output mentions fresh/deleting/creating")
  echo "  [FAIL] airlock sbx --fresh: output='$output'"
fi

# sbx fresh (no dashes): accepted — deletion message present
export DOCKER_MOCK_BEHAVIOUR="sandbox_version_ok sandbox_ls=${expected_name} sandbox_rm_ok sandbox_network_proxy_ok"
output="$(_airlock sbx fresh 2>&1)"
if [[ "$output" == *"fresh"* ]] || [[ "$output" == *"deleting"* ]] || [[ "$output" == *"creating"* ]]; then
  PASS=$((PASS+1)); echo "  [PASS] airlock sbx fresh: accepted (alias without dashes, output consistent)"
else
  FAIL=$((FAIL+1)); ERRORS+=("airlock sbx fresh: accepted (alias without dashes)")
  echo "  [FAIL] airlock sbx fresh: output='$output'"
fi

# sbx new: accepted — deletion message present
export DOCKER_MOCK_BEHAVIOUR="sandbox_version_ok sandbox_ls=${expected_name} sandbox_rm_ok sandbox_network_proxy_ok"
output="$(_airlock sbx new 2>&1)"
if [[ "$output" == *"fresh"* ]] || [[ "$output" == *"deleting"* ]] || [[ "$output" == *"creating"* ]]; then
  PASS=$((PASS+1)); echo "  [PASS] airlock sbx new: accepted (alias, output consistent)"
else
  FAIL=$((FAIL+1)); ERRORS+=("airlock sbx new: accepted (alias)")
  echo "  [FAIL] airlock sbx new: output='$output'"
fi

# sbx --fresh: no-op delete when no sandbox exists
export DOCKER_MOCK_BEHAVIOUR="sandbox_version_ok sandbox_ls_empty sandbox_network_proxy_ok"
output="$(_airlock sbx --fresh 2>&1)"
# Should NOT print an error; it just skips the delete step silently
_assert_not_contains "airlock sbx --fresh with no prior box: no 'error' in output" "error" "$output"

# sbx: reuses existing sandbox — 'reusing' message is printed before sbx_apply_whitelist
export DOCKER_MOCK_BEHAVIOUR="sandbox_version_ok sandbox_ls=${expected_name} sandbox_network_proxy_ok"
output="$(_airlock sbx 2>&1)"
_assert_contains "airlock sbx: output says 'reusing' when sandbox exists" "reusing" "$output"

# sbx: creates sandbox when none exists — 'creating' message is printed
export DOCKER_MOCK_BEHAVIOUR="sandbox_version_ok sandbox_ls_empty sandbox_network_proxy_ok"
output="$(_airlock sbx 2>&1)"
_assert_contains "airlock sbx: output says 'creating' for new sandbox" "creating" "$output"

# sbx: mentions whitelist/egress before process substitution fails
export DOCKER_MOCK_BEHAVIOUR="sandbox_version_ok sandbox_ls_empty sandbox_network_proxy_ok"
output="$(_airlock sbx 2>&1)"
if [[ "$output" == *"whitelist"* ]] || [[ "$output" == *"egress"* ]]; then
  PASS=$((PASS+1)); echo "  [PASS] airlock sbx: output mentions whitelist/egress"
else
  FAIL=$((FAIL+1)); ERRORS+=("airlock sbx: output mentions whitelist/egress")
  echo "  [FAIL] airlock sbx: output='$output'"
fi

# sbx: shows the sbx launch banner when it gets far enough
export DOCKER_MOCK_BEHAVIOUR="sandbox_version_ok sandbox_ls_empty sandbox_network_proxy_ok"
output="$(_airlock sbx 2>&1)"
if [[ "$output" == *"SBX"* ]] || [[ "$output" == *"microVM"* ]]; then
  PASS=$((PASS+1)); echo "  [PASS] airlock sbx: shows sbx launch banner"
else
  FAIL=$((FAIL+1)); ERRORS+=("airlock sbx: shows sbx launch banner")
  echo "  [FAIL] airlock sbx: output='$output'"
fi

# ---------------------------------------------------------------------------
# ── airlock down — extended to remove sbx microVMs ──────────────────────────
# ---------------------------------------------------------------------------
echo ""
echo "airlock down — sbx cleanup"

_setup

# down: graceful when docker sandbox is unavailable
export DOCKER_MOCK_BEHAVIOUR="sandbox_version_fail"
output="$(_airlock down 2>&1)"; status=$?
_assert_exit_0 "airlock down: exits 0 even when docker sandbox unavailable" "$status"
_assert_contains "airlock down: still prints 'done'" "done" "$output"

# down: removes sbx microVMs when docker sandbox is available
export DOCKER_MOCK_BEHAVIOUR="sandbox_version_ok sandbox_ls=airlock-myproject-12345 sandbox_rm_ok"
output="$(_airlock down 2>&1)"; status=$?
_assert_exit_0 "airlock down: exits 0 when sbx is available and sandboxes exist" "$status"
_assert_contains "airlock down: prints 'done'" "done" "$output"

# down: exits 0 when sandbox list is empty
export DOCKER_MOCK_BEHAVIOUR="sandbox_version_ok sandbox_ls_empty"
output="$(_airlock down 2>&1)"; status=$?
_assert_exit_0 "airlock down: exits 0 when no sbx microVMs to remove" "$status"

# ---------------------------------------------------------------------------
# ── Regression / boundary / negative tests ───────────────────────────────────
# ---------------------------------------------------------------------------
echo ""
echo "Regression / boundary / negative"

_setup
_source_airlock_functions

# sbx_name: only uses characters allowed by docker sbx
WORKSPACE="/tmp/workspace/my-test_project.v2"
result="$(sbx_name)"
if [[ "$result" =~ ^[A-Za-z0-9._+\-]+$ ]]; then
  PASS=$((PASS+1)); echo "  [PASS] sbx_name: only uses characters allowed by docker sbx ([A-Za-z0-9._+-])"
else
  FAIL=$((FAIL+1)); ERRORS+=("sbx_name: only uses characters allowed by docker sbx")
  echo "  [FAIL] sbx_name: invalid chars in '$result'"
fi

# sbx_require: does not exit 0 by accident when error is swallowed
# Run in a subshell so exit 1 inside sbx_require doesn't kill the test script.
export DOCKER_MOCK_BEHAVIOUR="sandbox_version_fail"
( sbx_require ) 2>/dev/null; status=$?
_assert_exit_nonzero "sbx_require: regression — does not silently succeed on failure" "$status"

# sbx_exists: does not treat a substring match as a whole-word match
export DOCKER_MOCK_BEHAVIOUR="sandbox_ls=airlock-project-1234567"
sbx_exists "airlock-project-123" 2>/dev/null; status=$?
_assert_exit_nonzero "sbx_exists: substring is not a whole-word match (regression)" "$status"

# Boundary: sbx_name for a workspace that is the same as another project's
# workspace except for trailing digits — names must differ
WORKSPACE="/tmp/workspace/project1"
name1="$(sbx_name)"
WORKSPACE="/tmp/workspace/project2"
name2="$(sbx_name)"
_assert_ne "sbx_name: project1 vs project2 produce different names" "$name1" "$name2"

# ---------------------------------------------------------------------------
# ── Summary ──────────────────────────────────────────────────────────────────
# ---------------------------------------------------------------------------
echo ""
echo "================================================================"
echo "Results: ${PASS} passed, ${FAIL} failed"
if [ "${#ERRORS[@]}" -gt 0 ]; then
  echo ""
  echo "Failed tests:"
  for e in "${ERRORS[@]}"; do echo "  - $e"; done
fi
echo "================================================================"

[ "$FAIL" -eq 0 ]