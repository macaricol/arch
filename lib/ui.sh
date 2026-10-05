#!/usr/bin/env bash
# Terminal output: console look, messages, step headers, and the run() spinner.

VERBOSE=${VERBOSE:-0}
LOG_FILE=${LOG_FILE:-$SETUP_DIR/setup.log}
LOGO_FILE=$SETUP_DIR/logo.txt

C_RESET=$'\e[0m' C_BOLD=$'\e[1m' C_REVERSE=$'\e[7m'
C_CYAN=$'\e[96m' C_GREEN=$'\e[92m' C_YELLOW=$'\e[93m' C_RED=$'\e[91m'
C_MAGENTA=$'\e[35m' C_WHITE=$'\e[97m' C_GREY=$'\e[90m'
C_BLUE=$'\e[34m' C_PINK=$'\e[95m'
TAG="${C_CYAN}${C_BOLD}[ Ω ]${C_RESET}"

# ── Console look ───────────────────────────────────────────────────────
# Everything is laid out in one centred column, LAYOUT_WIDTH wide (the width
# of the logo); MARGIN is the indent that centres it on the current terminal.
LAYOUT_WIDTH=72

# stty reads the size from /dev/tty, as stdin may be the curl pipe.
term_cols() {
  local size
  size=$(stty size 2>/dev/null < /dev/tty) && echo "${size#* }" || echo "${COLUMNS:-80}"
}
term_rows() {
  local size
  size=$(stty size 2>/dev/null < /dev/tty) && echo "${size% *}" || echo "${LINES:-24}"
}
update_margin() {
  local pad=$(( ($(term_cols) - LAYOUT_WIDTH) / 2 ))
  (( pad < 0 )) && pad=0
  printf -v MARGIN '%*s' "$pad" ''
}
update_margin

# True on a real Linux virtual console (the ISO, the first-login tty), not in
# a terminal emulator, which has its own font and colours.
on_console() { [[ $TERM == linux ]]; }

# The kernel's default console colours are harsh VGA ones; swap all 16 for
# CONSOLE_PALETTE (config.sh). Only cells drawn afterwards pick up the new
# background, hence the clear.
set_console_palette() {
  on_console || return 0
  local i
  for i in "${!CONSOLE_PALETTE[@]}"; do
    printf '\e]P%X%s' "$i" "${CONSOLE_PALETTE[i]#\#}"
  done
  printf '%s' "$C_RESET"
  clear
}

# On a high-resolution screen the default 8x16 font is tiny. Try each font,
# read back the size the console actually ends up with, and keep the one
# nearest ~48 rows that still leaves 80 columns. All three ship with kbd; on
# an already low-resolution console this settles on the default.
scale_console_font() {
  on_console && command -v setfont &>/dev/null || return 0
  local target=48 best='' best_diff=99999 font rows cols diff
  for font in default8x16 sun12x22 latarcyrheb-sun32; do
    setfont "$font" 2>/dev/null || continue
    rows=$(term_rows) cols=$(term_cols)
    (( cols >= 80 )) || continue
    diff=$(( rows > target ? rows - target : target - rows ))
    (( diff < best_diff )) && { best=$font; best_diff=$diff; }
  done
  setfont "${best:-default8x16}" 2>/dev/null || true
  update_margin
}

# Called first thing by each interactive phase.
setup_console() {
  scale_console_font
  set_console_palette
}

# ── Messages ───────────────────────────────────────────────────────────
# wrap TEXT WIDTH — word-wraps TEXT into the WRAPPED array, lines at most
# WIDTH characters (a single longer word gets a line of its own).
wrap() {
  # ${#} counts bytes, not characters, unless the locale is UTF-8.
  local LC_ALL=C.UTF-8 width=$2 word line=''
  local -a words
  read -ra words <<< "$1"
  WRAPPED=()
  for word in "${words[@]}"; do
    if [[ -z $line ]]; then
      line=$word
    elif (( ${#line} + 1 + ${#word} <= width )); then
      line+=" $word"
    else
      WRAPPED+=("$line")
      line=$word
    fi
  done
  WRAPPED+=("$line")
}

# message TAG COLOUR TEXT END — "[ Ω ] TEXT" kept inside the layout column:
# wrapped lines are indented to start under the text, not the tag (which is
# 5 columns plus a space).
message() {
  local tag=$1 colour=$2 end=$4 i
  wrap "$3" $((LAYOUT_WIDTH - 6))
  for i in "${!WRAPPED[@]}"; do
    if (( i )); then printf '\n%s      ' "$MARGIN"; else printf '%s%s ' "$MARGIN" "$tag"; fi
    printf '%s%s%s' "$colour" "${WRAPPED[i]}" "$C_RESET"
  done
  printf '%s' "$end"
}

# Warnings also go to the log: the next step header clears the screen.
info() { message "$TAG" "$C_WHITE" "$*" $'\n\n'; }
warn() {
  message "$C_YELLOW$C_BOLD[ Ω ]$C_RESET" "$C_YELLOW$C_BOLD" "$*" $'\n\n' >&2
  printf '[warn] %s\n' "$*" >> "$LOG_FILE" 2>/dev/null || true
}
die()  { message "$C_RED$C_BOLD[ Ω ]$C_RESET" "$C_RED$C_BOLD" "$*" $'\n' >&2; exit 1; }
ask()  { message "$TAG" "$C_WHITE" "$1" ' '; }

# repeat CHAR COUNT — multibyte-safe (tr is not)
repeat() { local s; printf -v s '%*s' "$2" ''; printf '%s' "${s// /$1}"; }

# center TEXT [VISIBLE_LENGTH] — prints TEXT centred in the layout column.
# Pass the length when TEXT contains colour codes.
center() {
  local len=${2:-${#1}}
  local pad=$(( (LAYOUT_WIDTH - len) / 2 ))
  (( pad < 0 )) && pad=0
  printf '%s%*s%s\n' "$MARGIN" "$pad" '' "$1"
}

# ── Step header ────────────────────────────────────────────────────────
# Numbered steps. Phases set STEP_TOTAL once; the counter does the rest, so
# inserting a step never means renumbering the others.
STEP=0
STEP_TOTAL=${STEP_TOTAL:-0}
PROGRESS_WIDTH=40

# The logo, then TAGLINE (config.sh) underneath.
draw_logo() {
  [[ -r $LOGO_FILE ]] || return 0
  # All lines are padded to one width, so measuring the first is enough.
  # ${#line} counts bytes, not █s, unless the locale is UTF-8.
  local LC_ALL=C.UTF-8 line width
  IFS= read -r line < "$LOGO_FILE"
  width=${#line}
  printf '\n\n'
  while IFS= read -r line; do
    center "${C_CYAN}${line}${C_RESET}" "$width"
  done < "$LOGO_FILE"
  echo
  center "${C_PINK}${TAGLINE}${C_RESET}" "${#TAGLINE}"
  echo
}

# The bar's filled and empty parts are the same █ in two colours, as not
# every console font has the shade characters (░▒▓).
draw_progress() {
  (( STEP_TOTAL > 0 )) || return 0
  local filled=$(( PROGRESS_WIDTH * STEP / STEP_TOTAL ))
  local count="$STEP/$STEP_TOTAL"
  center "${C_CYAN}$(repeat █ "$filled")${C_BLUE}$(repeat █ $((PROGRESS_WIDTH - filled)))${C_RESET}  $count" \
    $((PROGRESS_WIDTH + 2 + ${#count}))
}

# header "Title" [colour] — clears the screen and draws logo, progress bar
# and title for the current step. menu() redraws it on every keypress.
header() {
  clear
  update_margin
  draw_logo
  draw_progress
  echo
  center "${C_BOLD}${2:-$C_WHITE}$1${C_RESET}" "${#1}"
  echo
}

step() { (( ++STEP )); header "$1"; }

# finish "Title" — the closing screen of a phase: full bar, title in green.
finish() { STEP=$STEP_TOTAL; header "$1" "$C_GREEN"; }

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
    printf '\r%s%s[%s]%s' "$MARGIN" "$C_CYAN" "${spin:i++%4:1}" "$C_RESET"
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
