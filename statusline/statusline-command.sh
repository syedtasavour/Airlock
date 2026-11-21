#!/usr/bin/env bash
# Claude Code status line — two compact rows. ONE script for every place:
#   macOS (bash 3.2, BSD date, pmset, route/ipconfig)  ·  Linux/Arch (GNU date, /sys, ip)
#   airlock sandbox (baked at /opt/airlock; shows the sandbox badge instead of battery/IP)
#
#   Row 1: where (airlock run/dev, or Mac · no sandbox) │ model · effort │ repo + branch (* = uncommitted) │ ctx │ cost
#          │ time 12h · 24h │ battery (+ charging / plugged in) │ local IP (Wi-Fi / Ethernet / VPN)
#   Row 2: 5-hour limit │ weekly limit — 8-segment bar (┃ = goal), % used, goal (where you
#          should be now to use 100% by reset; week also shows the end-of-today goal),
#          reset "10:30 AM (10:30)" (weekday if not today), time left.
#          Colour = pace: green at/under goal, yellow up to 10 over, red beyond.
#          Under 130 columns the two limits go on separate rows.
# Colours are the terminal's 16 ANSI colours, so they follow its theme.
# Icons need a Nerd Font (e.g. JetBrainsMono Nerd Font); STATUSLINE_ICONS=0 uses plain symbols.
# Input: JSON on stdin (https://code.claude.com/docs/en/statusline)

input=$(cat)

# One jq call; unit-separator delimited so empty fields don't shift
IFS=$'\x1f' read -r model effort cwd repo ctx cost h5_pct h5_reset wk_pct wk_reset < <(
  jq -r '[
    (.model.display_name // "Claude"),
    (.effort.level // ""),
    (.workspace.current_dir // .cwd // ""),
    (.workspace.repo.name // ""),
    (.context_window.used_percentage // ""),
    (.cost.total_cost_usd // ""),
    (.rate_limits.five_hour.used_percentage // ""),
    (.rate_limits.five_hour.resets_at // ""),
    (.rate_limits.seven_day.used_percentage // ""),
    (.rate_limits.seven_day.resets_at // "")
  ] | map(tostring) | join("\u001f")' <<<"$input"
)

R=$'\e[0m'; B=$'\e[1m'; D=$'\e[2m'
RED=$'\e[31m'; GRN=$'\e[32m'; YEL=$'\e[33m'; BLU=$'\e[34m'; MAG=$'\e[35m'; CYN=$'\e[36m'
SEP=" ${D}│${R} "

# Icons as raw UTF-8 bytes: macOS ships bash 3.2, which can't expand $''.
if [ "${STATUSLINE_ICONS:-1}" = 1 ]; then
  I_REPO=$'\xef\x81\xbb'        # nf-fa-folder
  I_GIT=$'\xee\x82\xa0'         # nf-pl-branch
  I_MODEL=$'\xf3\xb0\x9a\xa9'   # nf-md-robot
  I_CLOCK=$'\xf3\xb0\xa5\x94'   # nf-md-clock
  I_BAT100=$'\xf3\xb0\x81\xb9'; I_BAT80=$'\xf3\xb0\x82\x80'; I_BAT60=$'\xf3\xb0\x81\xbe'
  I_BAT40=$'\xf3\xb0\x81\xbc';  I_BAT20=$'\xf3\xb0\x81\xba'; I_BATLOW=$'\xf3\xb0\x82\x8e'
  I_BATCHG=$'\xf3\xb0\x82\x84'
  I_WIFI=$'\xf3\xb0\x96\xa9'; I_ETH=$'\xf3\xb0\x88\x80'; I_OFFLINE=$'\xf3\xb0\x96\xaa'
  I_VPN=$'\xef\x84\xb2'         # nf-fa-shield
  I_LOCK=$'\xef\x80\xa3'; I_UNLOCK=$'\xef\x82\x9c'
  I_HOURGLASS=$'\xef\x89\x92'; I_CAL=$'\xef\x81\xb3'
  I_APPLE=$'\xef\x85\xb9'; I_LINUX=$'\xef\x85\xbc'; I_ALERT=$'\xef\x81\xb1'
  I_SHIELD_OK=$'\xf3\xb0\x95\xa5'   # nf-md-shield_check
else
  I_REPO='▸'; I_GIT='⎇'; I_MODEL='◆'; I_CLOCK='◷'
  I_BAT100='▮'; I_BAT80='▮'; I_BAT60='▮'; I_BAT40='▮'; I_BAT20='▯'; I_BATLOW='▯'; I_BATCHG='↯'
  I_WIFI='wifi'; I_ETH='eth'; I_OFFLINE='✕'; I_VPN='vpn'; I_LOCK='■'; I_UNLOCK='□'
  I_HOURGLASS='⧗'; I_CAL='▦'; I_APPLE='◉'; I_LINUX='◉'; I_ALERT='!'; I_SHIELD_OK='■'
fi

now=$(date +%s)

# ---- portable time helpers (BSD date first, GNU fallback) ------------------------
# BSD: date -r EPOCH   ·   GNU: date -d @EPOCH   (GNU's -r means "file", so it fails over)
fmt() { date -r "$1" "+$2" 2>/dev/null || date -d "@$1" "+$2" 2>/dev/null; }
midnight_tonight() {
  date -v+1d -v0H -v0M -v0S +%s 2>/dev/null || date -d 'tomorrow 00:00' +%s 2>/dev/null
}
# resets_at may arrive as epoch seconds, epoch millis or ISO-8601 — normalise to seconds.
to_epoch() {
  case "$1" in
    "") ;;
    *[!0-9]*) local s="${1%%.*}"; s="${s%Z}"
              date -j -u -f '%Y-%m-%dT%H:%M:%S' "$s" +%s 2>/dev/null || date -u -d "$1" +%s 2>/dev/null ;;
    *) if [ "${#1}" -ge 12 ]; then echo $(( $1 / 1000 )); else echo "$1"; fi ;;
  esac
}
h5_reset=$(to_epoch "$h5_reset"); wk_reset=$(to_epoch "$wk_reset")

# <50 green, <80 yellow, else red
level_color() { local p=${1%.*}; ((p >= 80)) && echo "$RED" || { ((p >= 50)) && echo "$YEL" || echo "$GRN"; }; }

# Pace colour (used vs goal): at/under goal = green (room to use more), up to 10 over = yellow, more = red
pace_color() { local u=${1%.*} g=$2; ((u <= g)) && echo "$GRN" || { ((u <= g + 10)) && echo "$YEL" || echo "$RED"; }; }

# 8-segment bar coloured by pace, with ┃ marking where the goal is
bar() { # used goal
  local p=${1%.*} g=$2 n gi i out="" c; c=$(pace_color "$p" "$g")
  ((p < 0)) && p=0; ((p > 100)) && p=100
  n=$(( (p * 8 + 50) / 100 )); ((p > 0 && n == 0)) && n=1
  gi=$(( (g * 8 + 50) / 100 )); ((gi > 7)) && gi=7
  for ((i = 0; i < 8; i++)); do
    if ((i == gi && g > 0)); then
      if ((i < n)); then out+="${B}${c}┃${R}"; else out+="${R}${B}┃${R}"; fi
    elif ((i < n)); then out+="${c}━"
    else out+="${D}━${R}"; fi
  done
  printf '%s%s' "$out" "$R"
}

# % of the window elapsed at time $3 (= the goal if you want to use 100% by reset)
goal_at() { # reset window time
  local g=$(( 100 - ( ($1 - $3) * 100 / $2 ) ))
  ((g < 0)) && g=0; ((g > 100)) && g=100; echo "$g"
}

# "4h12m" / "2d3h" / "35m"
left() {
  local s=$(($1 - now)); ((s < 0)) && s=0
  local d=$((s / 86400)) h=$((s % 86400 / 3600)) m=$((s % 3600 / 60))
  if ((d > 0)); then printf '%dd%dh' "$d" "$h"
  elif ((h > 0)); then printf '%dh%dm' "$h" "$m"
  else printf '%dm' "$m"; fi
}

# "10:30 AM (10:30)", with weekday if not today
reset_at() {
  local t=$1 day=""
  [[ $(fmt "$t" %F) != $(date +%F) ]] && day="$(fmt "$t" %a) "
  printf '%s%s %s(%s)%s' "$day" "$(fmt "$t" '%-I:%M %p')" "$D" "$(fmt "$t" %H:%M)" "$R"
}

limit() { # icon label pct reset window [show_today]
  local icon=$1 label=$2 pct=$3 reset=$4 window=$5 today=$6
  local head="${CYN}${icon} ${label}${R}"
  [[ -z $pct ]] && { printf '%s %s—%s' "$head" "$D" "$R"; return; }
  if [[ -z $reset ]]; then
    printf '%s %s%.0f%%%s' "$head" "$B" "$pct" "$R"; return
  fi
  local goal c; goal=$(goal_at "$reset" "$window" "$now"); c=$(pace_color "$pct" "$goal")
  printf '%s %s %s%s%.0f%%%s %sgoal%s %s%%' "$head" "$(bar "$pct" "$goal")" "$B" "$c" "$pct" "$R" "$D" "$R" "$goal"
  if [[ -n $today ]]; then
    # where you should be by midnight tonight (or at reset, if that's sooner)
    local eod; eod=$(midnight_tonight); [[ -z $eod ]] && eod=$reset; ((eod > reset)) && eod=$reset
    printf ' %s· today%s %s%%' "$D" "$R" "$(goal_at "$reset" "$window" "$eod")"
  fi
  printf ' %s↻%s %s %s%s%s' "$MAG" "$R" "$(reset_at "$reset")" "$D" "$(left "$reset")" "$R"
}

# Every refresh runs git in whatever repo Claude is in — possibly an untrusted one. A repo's
# own .git/config can name commands git would run (core.fsmonitor); switch those off.
g() { git -c core.fsmonitor=false -c core.hooksPath=/dev/null -C "$cwd" --no-optional-locks "$@" 2>/dev/null; }

# ---- row 1 ----
# Built as segments with a priority, so a narrow window drops the least useful
# ones (IP, then battery, …) instead of wrapping into a mess.
SEGS=(); PRIO=()
seg() { SEGS+=("$1"); PRIO+=("$2"); }   # text, priority (higher = kept longer)

# Where am I? Always shown, first. Inside airlock: the sandbox mode. Outside:
# a clear "no sandbox" so running untrusted code on the bare machine is obvious.
case "${AIRLOCK_SANDBOX:-}" in
  "")
    if [[ $(uname) == Darwin ]]; then host_icon=$I_APPLE; host_name=Mac; else host_icon=$I_LINUX; host_name=host; fi
    seg "${B}${YEL}${host_icon} ${host_name}${R} ${YEL}${I_ALERT} no sandbox${R}" 100 ;;
  dev) seg "${B}${YEL}${I_UNLOCK} airlock dev${R} ${D}full net${R}" 100 ;;
  *)   seg "${B}${GRN}${I_SHIELD_OK} airlock run${R} ${D}whitelist${R}" 100 ;;
esac

m="${B}${BLU}${I_MODEL} ${model}${R}"; [[ -n $effort ]] && m+=" ${D}${effort}${R}"
seg "$m" 90

if [[ -n $cwd ]]; then
  top=$(g rev-parse --show-toplevel)
  if [[ -n $top ]]; then
    [[ -z $repo ]] && repo=${top##*/}
    branch=$(g branch --show-current)
    [[ -z $branch ]] && branch=$(g rev-parse --short HEAD)
    dirty=""; [[ -n $(g status --porcelain | head -1) ]] && dirty="${YEL}*${R}"
    seg "${BLU}${I_REPO} ${R}${B}${repo}${R} ${MAG}${I_GIT} ${branch}${R}${dirty}" 80
  else
    T="~"; seg "${BLU}${I_REPO} ${R}${cwd/#$HOME/$T}" 80
  fi
fi

[[ -n $ctx ]] && seg "${D}ctx${R} $(level_color "$ctx")${ctx%.*}%${R}" 70
[[ -n $cost ]] && seg "${GRN}\$$(printf '%.2f' "$cost")${R}" 40
seg "${CYN}${I_CLOCK}${R} ${B}$(date '+%-I:%M %p')${R} ${D}·${R} ${B}$(date '+%H:%M')${R}" 30

# Battery + network describe the machine you're sitting at, so skip them in the sandbox.
if [[ -z ${AIRLOCK_SANDBOX:-} ]]; then
  # ---- battery: macOS pmset, else Linux /sys (omitted on desktops) ----
  cap=""; st=""
  if command -v pmset >/dev/null 2>&1; then
    batt=$(pmset -g batt 2>/dev/null)
    cap=$(printf '%s\n' "$batt" | grep -Eo '[0-9]+%' | head -1 | tr -d %)
    case "$batt" in
      *"; charging"*|*"finishing charge"*) st=Charging ;;
      *"charged"*|*"AC attached"*|*"not charging"*) st=Full ;;
      *"'AC Power'"*) st=Full ;;
      *) st=Discharging ;;
    esac
  else
    bat=$(ls -d /sys/class/power_supply/BAT* 2>/dev/null | head -1)
    [[ -n $bat ]] && { cap=$(<"$bat/capacity"); st=$(<"$bat/status"); }
  fi
  if [[ -n $cap ]]; then
    if   ((cap >= 90)); then bi="${I_BAT100}"; elif ((cap >= 70)); then bi="${I_BAT80}"; elif ((cap >= 50)); then bi="${I_BAT60}"
    elif ((cap >= 30)); then bi="${I_BAT40}"; elif ((cap >= 15)); then bi="${I_BAT20}"; else bi="${I_BATLOW}"; fi
    if ((cap <= 15)); then bc=$RED; elif ((cap <= 30)); then bc=$YEL; else bc=$GRN; fi
    case $st in
      Charging)                bi="${I_BATCHG}"; bs=" ${D}charging${R}" ;;
      Full|"Not charging")     bs=" ${D}plugged in${R}" ;;
      *)                       bs="" ;;
    esac
    seg "${bc}${bi} ${B}${cap}%${R}${bs}" 20
  fi

  # ---- local IP of the connection in use (route lookup only — nothing is sent) ----
  ip_dev=""; ip_addr=""; kind=""
  if [[ $(uname) == Darwin ]]; then
    ip_dev=$(route -n get 1.1.1.1 2>/dev/null | awk '/interface:/ {print $2}')
    [[ -n $ip_dev ]] && ip_addr=$(ipconfig getifaddr "$ip_dev" 2>/dev/null)
    if [[ $ip_dev == utun* ]]; then
      # utun = VPN (getifaddr has no IPv4 for it): take its address from ifconfig
      kind=vpn; [[ -z $ip_addr ]] && ip_addr=$(ifconfig "$ip_dev" 2>/dev/null | awk '/inet / {print $2; exit}')
    else
      # Which device is Wi-Fi, from networksetup — cached for a day (it's slowish).
      cache="${TMPDIR:-/tmp}/claude-statusline-wifi-dev"
      if [[ ! -s $cache || -n $(find "$cache" -mmin +1440 2>/dev/null) ]]; then
        networksetup -listallhardwareports 2>/dev/null \
          | awk '/Hardware Port: (Wi-Fi|AirPort)/ {getline; print $2}' > "$cache" 2>/dev/null
      fi
      grep -qx "$ip_dev" "$cache" 2>/dev/null && kind=wifi || kind=eth
    fi
  elif command -v ip >/dev/null 2>&1; then
    read -r ip_dev ip_addr < <(ip -4 -o route get 1.1.1.1 2>/dev/null |
      awk '{for (i = 1; i < NF; i++) { if ($i == "dev") d = $(i+1); if ($i == "src") s = $(i+1) } print d, s}')
    case $ip_dev in wl*) kind=wifi ;; tun*|wg*|tailscale*) kind=vpn ;; *) kind=eth ;; esac
  fi
  if [[ -n $ip_addr ]]; then
    case $kind in wifi) ni="${I_WIFI}" ;; vpn) ni="${I_VPN}" ;; *) ni="${I_ETH}" ;; esac
    seg "${BLU}${ni}${R} ${ip_addr}" 10
  else
    seg "${RED}${I_OFFLINE}${R} ${D}offline${R}" 10
  fi
fi

# ---- fit to the terminal width ----
# Claude Code may not pass COLUMNS; ask the terminal itself, else assume wide.
cols=${COLUMNS:-}
[[ -z $cols ]] && cols=$( { stty size < /dev/tty; } 2>/dev/null | awk '{print $2}')
[[ $cols =~ ^[0-9]+$ ]] && ((cols > 0)) || cols=200
ESC=$'\e'
# A UTF-8 locale for counting characters: macOS has en_US.UTF-8, Debian images C.UTF-8.
if [[ $(uname) == Darwin ]]; then U8=en_US.UTF-8; else U8=C.UTF-8; fi
vis_len() {  # printable width: drop colour codes, count characters (not bytes)
  local s; s=$(printf '%s' "$1" | LC_ALL=C sed "s/${ESC}\[[0-9;]*m//g")
  local LC_ALL=$U8; echo "${#s}"
}
join_segs() {
  local out="" i
  for ((i = 0; i < ${#SEGS[@]}; i++)); do
    [[ -z ${SEGS[i]} ]] && continue
    [[ -n $out ]] && out+="$SEP"; out+="${SEGS[i]}"
  done
  printf '%s' "$out"
}
l1=$(join_segs)
while (( $(vis_len "$l1") > cols - 2 )); do
  lo=-1; lp=1000
  for ((i = 0; i < ${#SEGS[@]}; i++)); do
    [[ -n ${SEGS[i]} ]] && ((PRIO[i] < lp && PRIO[i] < 80)) && { lp=${PRIO[i]}; lo=$i; }
  done
  ((lo < 0)) && break            # only must-keep segments left
  SEGS[lo]=""; l1=$(join_segs)
done

# ---- row 2 ----
h5=$(limit "$I_HOURGLASS" '5h' "$h5_pct" "$h5_reset" 18000)
wk=$(limit "$I_CAL" 'Week' "$wk_pct" "$wk_reset" 604800 today)

printf '%s\n' "$l1"
# One row when the terminal is wide enough, otherwise one row per limit
if (( cols >= 130 )); then
  printf '%s%s%s\n' "$h5" "$SEP" "$wk"
else
  printf '%s\n%s\n' "$h5" "$wk"
fi
