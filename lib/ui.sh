#!/usr/bin/env bash
# Terminal output: console look, messages, step headers, and the run() spinner.

VERBOSE=${VERBOSE:-0}
LOG_FILE=${LOG_FILE:-$SETUP_DIR/setup.log}
LOGO_FILE=$SETUP_DIR/assets/logo/logo.txt

C_RESET=$'\e[0m' C_BOLD=$'\e[1m' C_REVERSE=$'\e[7m'
C_CYAN=$'\e[96m' C_GREEN=$'\e[92m' C_YELLOW=$'\e[93m' C_RED=$'\e[91m'
C_WHITE=$'\e[97m' C_GREY=$'\e[90m'
C_BLUE=$'\e[34m' C_PINK=$'\e[95m'
# ᗧ and ⬤ are Pac-Man, open and closed. On the console they come from the
# fonts in assets/consolefonts (tools/make-console-fonts.py); in a terminal
# emulator, from its own font.
TAG="${C_CYAN}${C_BOLD}ᗧ${C_RESET}"
TAG_COLS=2   # the tag and the space after it

# ── Console look ───────────────────────────────────────────────────────
# Everything is laid out in one centred column, LAYOUT_WIDTH wide (the width
# of the logo); MARGIN is the indent that centres it on the current terminal.
LAYOUT_WIDTH=79

# stty reads the size from /dev/tty, as stdin may be the curl pipe.
# The terminal to act on: standard input when it's a virtual console
# (/dev/ttyN), which is how the installer runs,
# else the controlling terminal. Named explicitly because setfont, left to
# find a console itself, can settle on another one (or none) in a service.
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
# Root only: the post phase, run as the user from the installer, keeps the
# font the install phase loaded.
scale_console_font() {
  on_console && (( EUID == 0 )) && command -v setfont &>/dev/null || return 0
  local target=48 best='' best_diff=99999 font rows cols diff dev errors i
  dev=$(console_dev) errors=$(mktemp)
  # With a quiet boot, the console may have no font support yet: the kernel
  # defers the framebuffer console's takeover until something is printed
  # (fbcon deferred takeover, for flicker-free boots), and until then every
  # font is refused, which kbd reports as "Unable to load such font with
  # such kernel version". So print something, then wait (up to 10 s) for
  # the takeover, which happens asynchronously. It has to be a visible
  # character: the placeholder console ignores escape sequences and spaces
  # ("Ignore erases" in the kernel's dummycon_putc). A dot, erased at once.
  printf '\e[H.\r\e[K' > "$dev" 2>/dev/null || true
  for i in {1..20}; do
    setfont -C "$dev" default8x16 2>/dev/null && break
    sleep 0.5
  done
  for font in default8x16 sun12x22 latarcyrheb-sun32; do
    [[ -f $SETUP_DIR/assets/consolefonts/$font.psfu.gz ]] && font=$SETUP_DIR/assets/consolefonts/$font.psfu.gz
    setfont -C "$dev" "$font" 2>>"$errors" || continue
    rows=$(term_rows) cols=$(term_cols)
    (( cols >= 80 )) || continue
    diff=$(( rows > target ? rows - target : target - rows ))
    (( diff < best_diff )) && { best=$font; best_diff=$diff; }
  done
  if setfont -C "$dev" "${best:-default8x16}" 2>>"$errors" && [[ $best == "$SETUP_DIR"/* ]]; then
    PATCHED_FONT=1
  fi
  # setfont's complaints, if any, for the journal: journalctl -t arch-setup
  [[ -s $errors ]] && logger -t arch-setup "setfont on $dev: $(sort -u "$errors" | tr '\n' ' ')" 2>/dev/null
  rm -f "$errors"
  update_margin
}

# The double-resolution logo is drawn with glyphs only the patched fonts
# have, so it's used only once one of them is loaded: by scale_console_font,
# in this process or in the install phase that started it (which passes
# PATCHED_FONT down through the chroot phase to the post phase).
logo_file() {
  if on_console && [[ ${PATCHED_FONT:-0} == 1 && -f $SETUP_DIR/assets/logo/logo-hd.txt ]]; then
    echo "$SETUP_DIR/assets/logo/logo-hd.txt"
  else
    echo "$LOGO_FILE"
  fi
}

# cursor on|off — on the console, the cursor is hidden except while
# something is being typed (lib/prompt.sh turns it on for that), so it never
# blinks at the left edge between steps. Left alone in a terminal emulator,
# where it would stay hidden after the script ends.
cursor() {
  on_console || return 0
  if [[ $1 == on ]]; then printf '\e[?25h'; else printf '\e[?25l'; fi
}

# Called first thing by each interactive phase.
setup_console() {
  scale_console_font
  set_console_palette
  cursor off
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
# Both may come from the environment: the post phase, run from the
# installer, carries on the install phase's progress bar.
STEP=${STEP:-0}
STEP_TOTAL=${STEP_TOTAL:-0}
PROGRESS_WIDTH=40

# The logo, then TAGLINE (config.sh) underneath.
# logo_lines — the logo (logo_file) as printable lines in LOGO_LINES, its
# width in columns in LOGO_WIDTH. Its .colors file gives each cell a digit,
# fg * 3 + bg, of the colours 0 background, 1 letters, 2 extrusion: on the
# console the palette's slots 0, 6 and 2 (slots 0-7, as 512-glyph fonts have
# no others), elsewhere the same colours as 24-bit RGB, since a terminal
# emulator doesn't use CONSOLE_PALETTE.
logo_lines() {
  local file colours LC_ALL=C.UTF-8   # ${#} and ${:i:1} count characters, not bytes
  file=$(logo_file) colours=${file%.txt}.colors
  LOGO_LINES=() LOGO_WIDTH=0
  [[ -r $file && -r $colours ]] || return 0
  local -a lines attrs fg bg
  mapfile -t lines < "$file"
  mapfile -t attrs < "$colours"
  LOGO_WIDTH=${#lines[0]}
  local i hex
  local -a slots=(0 6 2)
  for i in 0 1 2; do
    if on_console; then
      fg[i]=$(( 30 + slots[i] )) bg[i]=$(( 40 + slots[i] ))
    else
      hex=${CONSOLE_PALETTE[slots[i]]}
      fg[i]="38;2;$((16#${hex:0:2}));$((16#${hex:2:2}));$((16#${hex:4:2}))"
      bg[i]="48;2;$((16#${hex:0:2}));$((16#${hex:2:2}));$((16#${hex:4:2}))"
    fi
  done
  bg[0]=49   # the dark: whatever the background is (slot 0 on the console)
  local row col char attr sgr prev out
  for row in "${!lines[@]}"; do
    out='' prev=''
    for (( col = 0; col < ${#lines[row]}; col++ )); do
      char=${lines[row]:col:1} attr=${attrs[row]:col:1}
      if [[ $char == ' ' ]]; then sgr=0; else sgr="0;${fg[attr / 3]};${bg[attr % 3]}"; fi
      [[ $sgr != "$prev" ]] && out+=$'\e['"${sgr}m" prev=$sgr
      out+=$char
    done
    LOGO_LINES+=("$out$C_RESET")
  done
}

draw_logo() {
  logo_lines
  (( LOGO_WIDTH )) || return 0
  printf '\n\n'
  local line
  for line in "${LOGO_LINES[@]}"; do
    center "$line" "$LOGO_WIDTH"
  done
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
  printf '\r\e[K'
  on_console || printf '\e[?25h'   # see cursor()
  local status=0
  wait "$pid" || status=$?
  cat "$out" >> "$LOG_FILE"
  (( status == 0 )) || { printf '%sFailed (%s): %s%s\n' "$C_RED" "$status" "$*" "$C_RESET" >&2; cat "$out" >&2; }
  rm -f "$out"
  return "$status"
}
