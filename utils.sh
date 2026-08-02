#!/usr/bin/env bash
# utils.sh - Helper functions for Arch installer

# Default configuration (can be overridden before sourcing, e.g. VERBOSE=1 ./main.sh)
VERBOSE=${VERBOSE:-0}

# Run a command; with VERBOSE=1 show its output directly, otherwise run it in
# the background and show a spinner until it exits, then return its real exit
# code (so `set -e` / callers still see failures correctly).
run() {
  if ((VERBOSE)); then "$@"; return; fi
  "$@" &>/dev/null &
  local pid=$! spin='|/-\' i=0
  while kill -0 "$pid" 2>/dev/null; do
    printf '\r\e[96m[%s]\e[0m' "${spin:i++%4:1}"
    sleep 0.1
  done
  printf '\r\e[K'  # clear the spinner line
  wait "$pid"
}
die() { printf '\e[91;1m[ Ω ] %b\e[0m\n' "$*" >&2; exit 1; }
info() { printf '\e[96;1m[ Ω ]\e[0m \e[97m%s\e[0m\n\n' "$*"; }

# Draws a centered title inside a horizontal rule, e.g.:
# ── title ──
box() {
  local t=" $1 " w=${2:-70} c=${3:-Ω}
  local line=$(printf '%*s' "$w" '' | tr ' ' "$c")     # full-width rule
  local pad=$(( (w - 2 - ${#t}) / 2 ))                 # left padding to center the title
  local side=$(printf '%*s' "$pad" '' | tr ' ' "$c")
  local rest=$(printf '%*s' "$((w - 2 - ${#t} - pad))" '' | tr ' ' "$c")

  printf '\n\e[35m%s\n%s\e[36m%s\e[35m%s\e[0m\n\e[35m%s\e[0m\n\n' \
    "$line" "$c$side" "$t" "$rest$c" "$line"
}

# ── INPUT & VALIDATION ────────────────────────────────────────────────
ask() { printf '\e[96;1m[ Ω ]\e[0m \e[97m%s\e[0m ' "$1"; }
valid_hostname() { [[ $1 =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] && (( ${#1} <= 63 )); }
valid_username() { [[ $1 =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; }
valid_password() { (( ${#1} >= 6 )); }

# Prompt in a loop until a non-empty, validator-passing value is entered, then
# store it in $var (named via printf -v, so the caller's variable is set
# directly — this is why validators are passed as function names, not calls).
input() {
  local prompt=$1 var=$2 secure=${3:-no} validator=${4:-}
  while :; do
    ask "$prompt"
    if [[ $secure == yes ]]; then read -rs val; echo; else read -r val; fi
    val="${val##+([[:space:]])}"; val="${val%%+([[:space:]])}"  # trim whitespace
    [[ -n $validator && -z $val ]] && { echo -e '\e[93m[ Ω ] Cannot be empty\e[0m'; continue; }
    [[ -n $validator ]] && ! "$validator" "$val" && { echo -e '\e[93m[ Ω ] Invalid\e[0m'; continue; }
    printf -v "$var" '%s' "$val"
    return 0
  done
}

# Like input(), but asks twice and requires both entries to match — protects
# against a typo locking you out of the installed system.
password() {
  local prompt=$1 var=$2 p1 p2
  while :; do
    input "$prompt" p1 yes valid_password
    input "Confirm password: " p2 yes
    [[ $p1 == "$p2" ]] && break
    echo -e '\e[93m[ Ω ] Passwords do not match\e[0m'
  done
  printf -v "$var" '%s' "$p1"
}

# ── DRIVE SELECTION (TUI) ─────────────────────────────────────────────
# Arrow-key menu over every block device on the system, sets $DRIVE on exit.
select_drive() {
  # /dev/sdummy is a harmless placeholder at the top of the list, so the
  # cursor never starts on a real drive.
  mapfile -t options < <(printf '/dev/sdummy\n'; lsblk -dplno PATH,TYPE | awk '$2=="disk"{print $1}')
  (( ${#options[@]} )) || die "No block devices found"
  local selected=0 total=${#options[@]}
  draw_menu() {
    clear
    box "[2/5] Select installation drive"
    for ((i=0; i<${#options[@]}; i++)); do
      if (( i == selected )); then
        printf ' \e[7m>\e[0m %s\n' "${options[i]}"
      else
        printf '   %s\n' "${options[i]}"
      fi
    done
    box "↑↓ navigate – Enter select – ESC cancel"
  }  
  # Reads one keypress. Arrow keys arrive as a 3-byte escape sequence
  # (ESC [ A/B); a lone ESC (no follow-up bytes within 0.1s) means the user
  # hit Escape to cancel. Returns 0 (breaks the menu loop) only on Enter.
  read_key() {
    local key seq
    read -rsn1 key
    if [[ $key == $'\x1b' ]]; then
      if read -rsn2 -t 0.1 seq; then
        [[ $seq == '[A' ]] && selected=$((selected - 1))
        [[ $seq == '[B' ]] && selected=$((selected + 1))
        (( selected < 0 )) && selected=$((total-1))   # wrap top -> bottom
        (( selected >= total )) && selected=0          # wrap bottom -> top
      else
        clear; info "Operation cancelled."; exit 0
      fi
      return 1
    fi
    [[ -z $key ]] && return 0   # Enter reads as an empty string
    return 1
  }
  while :; do
    draw_menu
    read_key && break
  done
  DRIVE=${options[selected]}
  [[ -b $DRIVE ]] || die "Invalid drive."
  # Quick sanity check right after picking, on top of the full "type YES"
  # confirmation the caller shows later before anything is actually wiped.
  info "Use $DRIVE? ALL DATA WILL BE ERASED!"
  ask "Press Enter to confirm, any other key to cancel... "
  read -rsn1 confirm; echo
  [[ -z $confirm ]] || exit 0
  info "Selected: $DRIVE"
}
