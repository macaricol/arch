#!/usr/bin/env bash
# Terminal output: messages, section headers, and the run() spinner.

VERBOSE=${VERBOSE:-0}
LOG_FILE=${LOG_FILE:-$SETUP_DIR/setup.log}

C_RESET=$'\e[0m' C_BOLD=$'\e[1m' C_REVERSE=$'\e[7m'
C_CYAN=$'\e[96m' C_GREEN=$'\e[92m' C_YELLOW=$'\e[93m' C_RED=$'\e[91m'
C_MAGENTA=$'\e[35m' C_WHITE=$'\e[97m'
TAG="${C_CYAN}${C_BOLD}[ Ω ]${C_RESET}"

info()      { printf '%s %s%s%s\n\n' "$TAG" "$C_WHITE" "$*" "$C_RESET"; }
warn()      { printf '%s%s[ Ω ] %s%s\n' "$C_YELLOW" "$C_BOLD" "$*" "$C_RESET" >&2; }
die()       { printf '%s%s[ Ω ] %s%s\n' "$C_RED" "$C_BOLD" "$*" "$C_RESET" >&2; exit 1; }
ask()       { printf '%s %s%s%s ' "$TAG" "$C_WHITE" "$1" "$C_RESET"; }
step_done() { printf '%s%s[ ✓ ] DONE%s\n\n' "$C_GREEN" "$C_BOLD" "$C_RESET"; }

# repeat CHAR COUNT — multibyte-safe (tr is not)
repeat() { local s; printf -v s '%*s' "$2" ''; printf '%s' "${s// /$1}"; }

# box "title" [width] [char] — a centred title inside a horizontal rule
box() {
  local title=" $1 " width=${2:-70} ch=${3:-Ω}
  local left=$(( (width - 2 - ${#title}) / 2 ))
  local right=$(( width - 2 - ${#title} - left ))
  (( left < 0 )) && left=0
  (( right < 0 )) && right=0
  local rule; rule=$(repeat "$ch" "$width")
  printf '\n%s%s\n%s%s%s%s%s%s\n%s%s%s\n\n' \
    "$C_MAGENTA" "$rule" \
    "$(repeat "$ch" $((left + 1)))" "$C_CYAN" "$title" "$C_MAGENTA" "$(repeat "$ch" $((right + 1)))" "$C_RESET" \
    "$C_MAGENTA" "$rule" "$C_RESET"
}

# Numbered section header. Phases set STEP_TOTAL once; the counter does the
# rest, so inserting a step never means renumbering the others.
STEP=0
STEP_TOTAL=${STEP_TOTAL:-0}
step() { box "[$((++STEP))/$STEP_TOTAL] $1"; }

# Runs a command. Its output always goes to LOG_FILE; the terminal shows a
# spinner (or the live output with VERBOSE=1). On failure the output is also
# echoed to stderr so the failure is diagnosable, and the real exit code is
# returned so set -e still trips.
run() {
  printf '\n$ %s\n' "$*" >> "$LOG_FILE"
  if (( VERBOSE )); then
    "$@" 2>&1 | tee -a "$LOG_FILE"
    return "${PIPESTATUS[0]}"
  fi
  local out; out=$(mktemp)
  "$@" &>"$out" &
  local pid=$! spin='|/-\' i=0
  while kill -0 "$pid" 2>/dev/null; do
    printf '\r%s[%s]%s' "$C_CYAN" "${spin:i++%4:1}" "$C_RESET"
    sleep 0.1
  done
  printf '\r\e[K'
  local status=0
  wait "$pid" || status=$?
  cat "$out" >> "$LOG_FILE"
  (( status == 0 )) || { printf '%sFailed (%s): %s%s\n' "$C_RED" "$status" "$*" "$C_RESET" >&2; cat "$out" >&2; }
  rm -f "$out"
  return "$status"
}
