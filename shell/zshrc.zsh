# airlock shared zsh config — the SAME file on your Mac and in the sandbox.
#   Mac:      sourced from ~/.zshrc
#   sandbox:  baked into the image as /etc/zsh/airlock.zsh (loaded by /etc/zsh/zshrc)
# No frameworks, no network: just zsh options + two plugins if present.

# ---- history (with metadata) ---------------------------------------------------
# Every command is saved with its start time and how long it ran
# (EXTENDED_HISTORY); see it with:  history -iD   (date + duration)
#
# Mac: one history, ~/.zsh_history; each new terminal starts with everything
# saved so far (`fc -RI` pulls in other terminals' new commands on demand).
# Sandbox: one history PER PROJECT, kept in the client's home volume, so the
# predictions you get inside a project are that project's commands, and one
# client's commands never show up in another's sandbox.
if [[ -n "$AIRLOCK_SANDBOX" ]]; then
  mkdir -p "$HOME/.zsh_history.d"
  HISTFILE="$HOME/.zsh_history.d/${PWD//[^a-zA-Z0-9]/-}"
else
  # Always ~/.zsh_history. macOS Terminal otherwise gives every window its own
  # file (~/.zsh_sessions/*.history, the "Restored session" line), which is
  # why history and predictions seemed to go missing between windows.
  # SHELL_SESSIONS_DISABLE=1 in ~/.zshenv turns that feature off entirely.
  HISTFILE="$HOME/.zsh_history"
fi
HISTSIZE=200000
SAVEHIST=200000
setopt EXTENDED_HISTORY        # timestamp + duration per entry
setopt INC_APPEND_HISTORY_TIME # write each command when it finishes (with its duration)
unsetopt SHARE_HISTORY         # would zero the durations (see zshoptions)
setopt HIST_IGNORE_SPACE       # " cmd" (leading space) is never saved — for secrets
setopt HIST_IGNORE_DUPS        # no consecutive duplicates
setopt HIST_FIND_NO_DUPS       # searching skips repeats
setopt HIST_REDUCE_BLANKS
setopt HIST_VERIFY             # !! / !$ expand for review instead of running
unsetopt INC_APPEND_HISTORY 2>/dev/null   # superseded by the _TIME variant

# ---- general -------------------------------------------------------------------
setopt AUTO_CD                 # type a folder name to cd into it
setopt AUTO_PUSHD PUSHD_IGNORE_DUPS PUSHD_SILENT   # cd -<Tab> = recent dirs
setopt INTERACTIVE_COMMENTS    # allow # comments at the prompt
setopt NO_BEEP

# ---- completion ----------------------------------------------------------------
autoload -Uz compinit
_zcomp="${XDG_CACHE_HOME:-$HOME/.cache}/zsh/zcompdump-${ZSH_VERSION}"
mkdir -p "${_zcomp:h}"
compinit -i -d "$_zcomp"; unset _zcomp
zstyle ':completion:*' menu select                                  # arrow through matches
zstyle ':completion:*' matcher-list 'm:{a-zA-Z}={A-Za-z}' 'r:|=*' 'l:|=* r:|=*'  # case-insensitive, fuzzy-ish
zstyle ':completion:*' list-colors "${(s.:.)LS_COLORS}"
zstyle ':completion:*' group-name ''
zstyle ':completion:*:descriptions' format '%F{yellow}-- %d --%f'
zstyle ':completion:*' use-cache on
zstyle ':completion:*' cache-path "${XDG_CACHE_HOME:-$HOME/.cache}/zsh/compcache"

# ---- keys ------------------------------------------------------------------------
bindkey -e                                   # emacs-style (Ctrl-A/E/W/U …)
autoload -Uz up-line-or-beginning-search down-line-or-beginning-search
zle -N up-line-or-beginning-search
zle -N down-line-or-beginning-search
# ↑/↓ search history for commands starting with what you've typed so far
bindkey '^[[A' up-line-or-beginning-search   '^[OA' up-line-or-beginning-search
bindkey '^[[B' down-line-or-beginning-search '^[OB' down-line-or-beginning-search
bindkey '^[[H' beginning-of-line '^[[F' end-of-line          # Home / End
bindkey '^[[3~' delete-char                                  # Delete
bindkey '^[[1;3D' backward-word '^[[1;3C' forward-word       # Option-← / Option-→
bindkey '^[b' backward-word '^[f' forward-word

# ---- plugins (prediction + highlighting) ---------------------------------------
# Looked up wherever they're installed: your home (Mac), Homebrew, or Debian.
_airlock_source_first() {
  local f; for f in "$@"; do [[ -r "$f" ]] && { source "$f"; return 0; }; done; return 1
}
# Prediction: grey suggestion from your history as you type, falling back to
# completion. → or End accepts it, Option-→ accepts one word.
ZSH_AUTOSUGGEST_STRATEGY=(history completion)
ZSH_AUTOSUGGEST_BUFFER_MAX_SIZE=40
ZSH_AUTOSUGGEST_USE_ASYNC=1
_airlock_source_first \
  "$HOME/.local/share/zsh/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh" \
  /opt/homebrew/share/zsh-autosuggestions/zsh-autosuggestions.zsh \
  /usr/local/share/zsh-autosuggestions/zsh-autosuggestions.zsh \
  /usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh

# Ctrl-R: fuzzy history search, Ctrl-T: fuzzy file picker (when fzf exists)
if (( $+commands[fzf] )); then
  if fzf --zsh >/dev/null 2>&1; then source <(fzf --zsh)
  else _airlock_source_first /usr/share/doc/fzf/examples/key-bindings.zsh \
         /opt/homebrew/opt/fzf/shell/key-bindings.zsh; fi
fi

# ---- prompt ----------------------------------------------------------------------
#   user@host dir (branch) %            on the Mac — same shape as the default
#   [airlock:run] dir (branch) %        in the sandbox, impossible to mistake
# Red ✘<code> after a failed command. Branch via vcs_info (no external tools).
autoload -Uz vcs_info
zstyle ':vcs_info:*' enable git
zstyle ':vcs_info:git:*' formats ' %F{magenta}(%b)%f'
zstyle ':vcs_info:git:*' actionformats ' %F{magenta}(%b|%a)%f'
autoload -Uz add-zsh-hook
add-zsh-hook precmd vcs_info
setopt PROMPT_SUBST
if [[ -n "$AIRLOCK_SANDBOX" ]]; then
  case "$AIRLOCK_SANDBOX" in
    dev) _airlock_badge='%F{yellow}%B[airlock:dev]%b%f' ;;
    *)   _airlock_badge='%F{green}%B[airlock:run]%b%f' ;;
  esac
  PROMPT='${_airlock_badge} %F{cyan}%3~%f${vcs_info_msg_0_}%(?.. %F{red}✘%?%f) %# '
else
  PROMPT='%n@%m %F{cyan}%3~%f${vcs_info_msg_0_}%(?.. %F{red}✘%?%f) %# '
fi

# ---- sandbox extras ------------------------------------------------------------
if [[ -n "$AIRLOCK_SANDBOX" ]]; then
  export NVM_DIR="$HOME/.nvm"; mkdir -p "$NVM_DIR"
  [[ -s /usr/local/nvm/nvm.sh ]] && source /usr/local/nvm/nvm.sh
fi

# Syntax highlighting must be loaded LAST (it wraps every widget defined above).
_airlock_source_first \
  "$HOME/.local/share/zsh/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh" \
  /opt/homebrew/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh \
  /usr/local/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh \
  /usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh
unfunction _airlock_source_first
