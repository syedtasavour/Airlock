# airlock guard — loaded by ~/.zshrc / ~/.bashrc (added by `airlock guard on`).
#
# Why: one `npm i` on the Mac in a repo someone handed you is enough — a
# postinstall script runs as YOU, with your keys. airlock only helps if you
# actually use it, so this catches the habit: typing a package-manager command
# inside a project on your Mac asks to run it in airlock instead (Enter = yes).
#
# Only commands YOU type are affected. Shell functions don't reach scripts,
# editors, git hooks or anything else that runs npm. To bypass once:
#     command npm …        or        AIRLOCK_GUARD=0 npm …
# Outside a project (no package.json between here and $HOME) nothing changes.

case $- in *i*) ;; *) return 0 ;; esac

: "${AIRLOCK_BIN:=airlock}"
_AIRLOCK_CFG="${XDG_CONFIG_HOME:-$HOME/.config}/airlock"

# The folder airlock should mount: the git repo root when the nearest
# package.json is inside one, else the folder holding that package.json.
_airlock_project_root() {
  local d="$PWD" top
  while [ "$d" != "/" ] && [ "$d" != "$HOME" ]; do
    if [ -f "$d/package.json" ]; then
      top="$(git -C "$d" rev-parse --show-toplevel 2>/dev/null)"
      case "$top" in
        ""|"$HOME"|/) printf '%s\n' "$d" ;;
        *) case "$d/" in "$top"/*) printf '%s\n' "$top" ;; *) printf '%s\n' "$d" ;; esac ;;
      esac
      return 0
    fi
    d="$(dirname "$d")"
  done
  return 1
}

_airlock_trusted() {
  local t
  [ -f "$_AIRLOCK_CFG/trusted" ] || return 1
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    case "$1" in "$t"|"$t"/*) return 0 ;; esac
  done < "$_AIRLOCK_CFG/trusted"
  return 1
}

# Remembered choice per project (run|dev), so Enter does what you did last time.
_airlock_mode_get() {
  [ -f "$_AIRLOCK_CFG/modes" ] || return 0
  awk -F'\t' -v p="$1" '$1 == p { m = $2 } END { print m }' "$_AIRLOCK_CFG/modes"
}
_airlock_mode_set() {
  mkdir -p "$_AIRLOCK_CFG"
  { [ -f "$_AIRLOCK_CFG/modes" ] && awk -F'\t' -v p="$1" '$1 != p' "$_AIRLOCK_CFG/modes"
    printf '%s\t%s\n' "$1" "$2"; } > "$_AIRLOCK_CFG/modes.tmp" \
    && mv "$_AIRLOCK_CFG/modes.tmp" "$_AIRLOCK_CFG/modes"
}

_airlock_guard() {
  local tool="$1"; shift
  local root mode rel reply shown where
  # Not a person at a terminal, or explicitly bypassed -> behave like the real tool.
  if [ "${AIRLOCK_GUARD:-1}" = 0 ] || [ ! -t 0 ] || [ ! -t 1 ]; then command "$tool" "$@"; return; fi
  case "${1:-}" in -v|--version|-h|--help|help|version) command "$tool" "$@"; return ;; esac
  if [ "$tool" = node ] && [ "$#" -eq 0 ]; then command node; return; fi   # bare REPL
  root="$(_airlock_project_root)" || { command "$tool" "$@"; return; }
  if _airlock_trusted "$root"; then command "$tool" "$@"; return; fi

  mode="$(_airlock_mode_get "$root")"; [ -n "$mode" ] || mode=run
  rel="${PWD#"$root"}"; rel="${rel#/}"; [ -n "$rel" ] || rel=.
  shown="$tool"; [ "$#" -gt 0 ] && shown="$tool $*"
  case "$root" in "$HOME"/*) where="~${root#"$HOME"}" ;; *) where="$root" ;; esac

  {
    printf '\n  \033[1;33m⚠  airlock guard\033[0m — `%s` would run on your Mac, as you.\n' "$shown"
    printf '     \033[2mproject %s\033[0m\n' "$where"
    printf '     \033[1mEnter\033[0m = airlock %s   r = run (untrusted)   d = dev (your own code)\n' "$mode"
    printf '     h = on the Mac, just once   t = always allow on the Mac here   n = cancel\n'
    printf '  > '
  } >&2
  read -r reply < "${_AIRLOCK_GUARD_TTY:-/dev/tty}" || reply=n
  case "$reply" in
    "") ;;
    r|R) mode=run ;;
    d|D) mode=dev ;;
    h|H) command "$tool" "$@"; return ;;
    t|T)
      mkdir -p "$_AIRLOCK_CFG"; printf '%s\n' "$root" >> "$_AIRLOCK_CFG/trusted"
      printf '  trusted on the Mac — undo by removing the line from %s\n' "$_AIRLOCK_CFG/trusted" >&2
      command "$tool" "$@"; return ;;
    *) printf '  cancelled\n' >&2; return 130 ;;
  esac
  _airlock_mode_set "$root" "$mode"
  # Mount the project root, then run the command in the same subfolder you're in.
  ( cd "$root" && "$AIRLOCK_BIN" "$mode" \
      bash -c 'cd -- "$1" && shift && exec "$@"' airlock-guard "$rel" "$tool" "$@" )
}

# `function name { }` (not `name() { }`) so an existing alias such as
# alias npm=pnpm can't hijack the definition in zsh.
for _airlock_t in npm npx pnpm pnpx yarn bun bunx node corepack; do
  eval "function $_airlock_t { _airlock_guard $_airlock_t \"\$@\"; }"
done
unset _airlock_t
