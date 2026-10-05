#!/usr/bin/env bash
# Terminal output: console look, messages, step headers, and the run() spinner.

VERBOSE=${VERBOSE:-0}
LOG_FILE=${LOG_FILE:-$SETUP_DIR/setup.log}
LOGO_FILE=$SETUP_DIR/logo.txt

C_RESET=$'\e[0m' C_BOLD=$'\e[1m' C_REVERSE=$'\e[7m'
C_CYAN=$'\e[96m' C_GREEN=$'\e[92m' C_YELLOW=$'\e[93m' C_RED=$'\e[91m'
C_MAGENTA=$'\e[35m' C_WHITE=$'\e[97m' C_GREY=$'\e[90m'
C_BLUE=$'\e[34m' C_PINK=$'\e[95m'
# ᗧ and ⬤ are Pac-Man, open and closed. On the console they come from the
# fonts in assets/consolefonts (tools/make-console-fonts.py); in a terminal
# emulator, from its own font.
TAG="${C_CYAN}${C_BOLD}ᗧ${C_RESET}"
TAG_COLS=2   # the tag and the space after it

# ── Console look ───────────────────────────────────────────────────────
# Everything is laid out in one centred column, LAYOUT_WIDTH wide (the width
# of the logo); MARGIN is the indent that centres it on the current terminal.
LAYOUT_WIDTH=72

# stty reads the size from /dev/tty, as stdin may be the curl pipe.
# The terminal to act on: standard input when it's a virtual console
# (/dev/ttyN), which is how the install phase and the first-boot service run,
# else the controlling terminal. Named explicitly because setfont, left to
# find a console itself, can settle on another one (or none) in a service.
# (setfont also gets -f, to load the font's Unicode table unconditionally:
# without it, the added characters show as boxes.)
console_dev() {
  local dev
  dev=$(tty 2>/dev/null) || dev=
  if [[ $dev == /dev/tty[0-9]* ]]; then echo "$dev"; else echo /dev/tty; fi
}
term_cols() {
  local size
  size=$(stty -F "$(console_dev)" size 2>/dev/null) && echo "${size#* }" || echo "${COLUMNS:-80}"
}
term_rows() {
  local size
  size=$(stty -F "$(console_dev)" size 2>/dev/null) && echo "${size% *}" || echo "${LINES:-24}"
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
# an already low-resolution console this settles on the default. Each is
# loaded from assets/consolefonts, the same fonts with Pac-Man added, and
# from kbd if that copy is missing.
#
# Root only: as a regular user, setfont can't install the font's Unicode
# table, so the added glyphs would show as boxes. The first-boot service
# runs `setup.sh console` as root before the post phase for this reason.
scale_console_font() {
  on_console && (( EUID == 0 )) && command -v setfont &>/dev/null || return 0
  local target=48 best='' best_diff=99999 font rows cols diff dev errors i
  dev=$(console_dev) errors=$(mktemp)
  # A console still in graphics mode refuses any font, with kbd's misleading
  # "Unable to load such font with such kernel version": at the first boot,
  # Plymouth can still be handing tty1 back. Wait (up to 10 s) until it takes one.
  for i in {1..20}; do
    setfont -f -C "$dev" default8x16 2>/dev/null && break
    sleep 0.5
  done
  for font in default8x16 sun12x22 latarcyrheb-sun32; do
    [[ -f $SETUP_DIR/assets/consolefonts/$font.psfu.gz ]] && font=$SETUP_DIR/assets/consolefonts/$font.psfu.gz
    setfont -f -C "$dev" "$font" 2>>"$errors" || continue
    rows=$(term_rows) cols=$(term_cols)
    (( cols >= 80 )) || continue
    diff=$(( rows > target ? rows - target : target - rows ))
    (( diff < best_diff )) && { best=$font; best_diff=$diff; }
  done
  best_font=${best:-default8x16}
  if setfont -f -C "$dev" "${best:-default8x16}" 2>>"$errors" && [[ $best == "$SETUP_DIR"/* ]]; then
    PATCHED_FONT=1
    : > "$PATCHED_FONT_MARK" 2>/dev/null || true
  fi
  # setfont's complaints, if any, for the journal (see log_console_font)
  [[ -s $errors ]] && logger -t arch-setup "setfont on $dev: $(sort -u "$errors" | tr '\n' ' ')" 2>/dev/null
  rm -f "$errors"
  update_margin
}

# log_console_font WHERE — notes in the journal (tag arch-setup) how many of
# the patched fonts' private-use characters the console currently maps, and
# which font scale_console_font picked. 0 means boxes on screen.
log_console_font() {
  local mapped
  mapped=$(getunimap -C "$(console_dev)" 2>/dev/null | grep -ci '^0x[0-9a-f]*[[:space:]]*U+E[01]') || true
  logger -t arch-setup "$1: uid $EUID, console $(console_dev), font ${best_font:-none}, patched ${PATCHED_FONT:-0}, private-use chars mapped: ${mapped:-?}" 2>/dev/null || true
}

# The double-resolution logo is drawn with glyphs only the patched fonts
# have, so it's used only once one of them is loaded: by scale_console_font
# in this process, or, at the first boot, by the service's root step before
# this process started, which leaves PATCHED_FONT_MARK behind.
PATCHED_FONT_MARK=/run/arch-setup-patched-font
logo_file() {
  if on_console && [[ ${PATCHED_FONT:-0} == 1 || -e $PATCHED_FONT_MARK ]] && [[ -f $SETUP_DIR/logo-hd.txt ]]; then
    echo "$SETUP_DIR/logo-hd.txt"
  else
    echo "$LOGO_FILE"
  fi
}

# Called first thing by each interactive phase.
# The ISO's quiet boot (vt.global_cursor_default=0) hides the cursor; the
# typed prompts need it back. Waits for udev first: when the graphics driver
# takes over the console, udev re-runs systemd-vconsole-setup, which loads
# the stock font over ours, and that can land seconds into boot.
setup_console() {
  (( EUID == 0 )) && on_console && udevadm settle --timeout=15 2>/dev/null
  scale_console_font
  set_console_palette
  on_console && printf '\e[?25h'
  return 0
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

# message TAG COLOUR TEXT END — "ᗧ TEXT" kept inside the layout column:
# wrapped lines are indented to start under the text, not the tag.
message() {
  local tag=$1 colour=$2 end=$4 i
  wrap "$3" $((LAYOUT_WIDTH - TAG_COLS))
  for i in "${!WRAPPED[@]}"; do
    if (( i )); then printf '\n%s%*s' "$MARGIN" "$TAG_COLS" ''; else printf '%s%s ' "$MARGIN" "$tag"; fi
    printf '%s%s%s' "$colour" "${WRAPPED[i]}" "$C_RESET"
  done
  printf '%s' "$end"
}

# Warnings also go to the log: the next step header clears the screen.
info() { message "$TAG" "$C_WHITE" "$*" $'\n\n'; }
warn() {
  message "$C_YELLOW${C_BOLD}ᗧ$C_RESET" "$C_YELLOW$C_BOLD" "$*" $'\n\n' >&2
  printf '[warn] %s\n' "$*" >> "$LOG_FILE" 2>/dev/null || true
}
die()  { message "$C_RED${C_BOLD}ᗧ$C_RESET" "$C_RED$C_BOLD" "$*" $'\n' >&2; exit 1; }
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
  local file; file=$(logo_file)
  [[ -r $file ]] || return 0
  # All lines are padded to one width, so measuring the first is enough.
  # ${#line} counts bytes, not █s, unless the locale is UTF-8.
  local LC_ALL=C.UTF-8 line width
  IFS= read -r line < "$file"
  width=${#line}
  printf '\n\n'
  while IFS= read -r line; do
    center "${C_CYAN}${line}${C_RESET}" "$width"
  done < "$file"
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
  # Pac-Man chomping a row of pellets: closed with the pellets a step away,
  # then open with each moved one step closer, the first at its mouth.
  local pid=$! i=0
  local -a frames=("${C_BOLD}${C_CYAN}⬤${C_RESET}${C_WHITE} · · ·${C_RESET}"
                   "${C_BOLD}${C_CYAN}ᗧ${C_RESET}${C_WHITE}· · · ${C_RESET}")
  printf '\e[?25l'   # no cursor blinking after the pellets
  while kill -0 "$pid" 2>/dev/null; do
    printf '\r%s%s' "$MARGIN" "${frames[i++ % 2]}"
    sleep 0.2
  done
  printf '\r\e[K\e[?25h'
  local status=0
  wait "$pid" || status=$?
  cat "$out" >> "$LOG_FILE"
  (( status == 0 )) || { printf '%sFailed (%s): %s%s\n' "$C_RED" "$status" "$*" "$C_RESET" >&2; cat "$out" >&2; }
  rm -f "$out"
  return "$status"
}
