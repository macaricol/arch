#!/usr/bin/env bash
# Terminal output: console look, messages, step headers, and the run() spinner.

LOG_FILE=${LOG_FILE:-$SETUP_DIR/setup.log}
LOGO_FILE=$SETUP_DIR/assets/logo/logo.txt

# Colours by what they're for. On the console they're CONSOLE_PALETTE's
# slots (config.sh, where the roles are listed too); elsewhere a terminal
# emulator's own colours of the same number.
C_RESET=$'\e[0m' C_BOLD=$'\e[1m'
C_TEXT=$'\e[97m'        # 15 text
C_SOFT=$'\e[37m'        # 7  the facts, the review's labels
C_HINT=$'\e[90m'        # 8  hints under lists and buttons
C_ACCENT=$'\e[96m'      # 14 the progress bar
C_EMPTY=$'\e[34m'       # 4  the bar's empty part, the text box's edges
C_TAGLINE=$'\e[95m'     # 13 the tagline under the logo
C_DONE=$'\e[92m'        # 10 the last screen's title
C_WARN=$'\e[93m'        # 11 warnings
C_ERROR=$'\e[91m'       # 9  errors
# Highlighted things: black on the accent (the selected button, the list's
# current item), white on the empty bar's navy (the other buttons, the box).
C_SELECTED=$'\e[30;46m' C_UNSELECTED=$'\e[97;44m'
# ᗧ and ⬤ are Pac-Man, open and closed, chomping in run's spinner. On the
# console they come from the fonts in assets/consolefonts
# (tools/make-console-fonts.py); in a terminal emulator, from its own font.
# In his yellow: palette slot 3 on the console (not bold, which there turns
# it into slot 11), elsewhere as RGB, since a terminal emulator doesn't use
# CONSOLE_PALETTE.
if [[ $TERM == linux ]]; then C_PAC=$'\e[33m'
else C_PAC=$'\e[38;2;255;196;0m'; fi

# ── Console look ───────────────────────────────────────────────────────
# Everything is laid out in one centred column, LAYOUT_WIDTH wide (the width
# of the logo); MARGIN is the indent that centres it on the current terminal.
LAYOUT_WIDTH=79

# The terminal to act on: standard input when it's a virtual console
# (/dev/ttyN), which is how the installer runs, else the controlling
# terminal (/dev/tty, as stdin may be the curl pipe). Named explicitly
# because setfont, left to find a console itself, can settle on another one
# (or none) in a service.
console_dev() {
  local dev
  dev=$(tty 2>/dev/null) || dev=
  if [[ $dev == /dev/tty[0-9]* ]]; then echo "$dev"; else echo /dev/tty; fi
}
# term_size — the terminal's size, in ROWS and COLS.
term_size() {
  local size
  size=$(stty -F "$(console_dev)" size 2>/dev/null) || size="${LINES:-24} ${COLUMNS:-80}"
  ROWS=${size% *} COLS=${size#* }
}
update_margin() {
  term_size
  local pad=$(( (COLS - LAYOUT_WIDTH) / 2 ))
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

# The console font: the one the USB's start-up picked and loaded
# (tools/archauto.sh: the patched copy nearest ~48 rows, at least 80
# columns), passed down as CONSOLE_FONT. Not chosen again here: each font
# tried redraws the whole screen, the splash's logo wiped and its text
# re-laid in that font's grid, a flash with the text out of place. Only
# what it means for what's drawn: a patched font (PATCHED_FONT), with the
# glyphs the sharper logo, the bar's edge and the text box need; the later
# phases are passed it in turn.
scale_console_font() {
  [[ -n ${CONSOLE_FONT:-} && -f $CONSOLE_FONT ]] && PATCHED_FONT=1
  update_margin
}

# The double-resolution logo is drawn with glyphs only the patched fonts
# have, so it's used only once one of them is loaded (PATCHED_FONT: see
# scale_console_font).
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

# balanced_wrap TEXT WIDTH — wrap's lines, but as even as they can be: as
# few lines as at WIDTH, at the narrowest width that still needs no more, so
# centred they start and end at roughly the same columns, rather than a full
# line over a short one.
balanced_wrap() {
  local lines width=$2
  wrap "$1" "$width"
  lines=${#WRAPPED[@]}
  (( lines > 1 )) || return 0
  while (( width > 1 )); do
    wrap "$1" $(( width - 1 ))
    (( ${#WRAPPED[@]} == lines )) || break
    width=$(( width - 1 ))
  done
  wrap "$1" "$width"
}

# plural N WORD — "1 minute", "3 minutes".
plural() { (( $1 == 1 )) && echo "$1 $2" || echo "$1 ${2}s"; }

# centred_message COLOUR TEXT — TEXT centred in the layout column, in
# COLOUR, wrapped into even lines.
centred_message() {
  local LC_ALL=C.UTF-8 line
  balanced_wrap "$2" $(( LAYOUT_WIDTH - 10 ))
  for line in "${WRAPPED[@]}"; do center "$1$line$C_RESET" "${#line}"; done
}

# centred_details LABEL VALUE [LABEL VALUE...] — a summary: each label, in
# the facts' grey, and its value, in white, the values in a column; the
# block centred.
centred_details() {
  local LC_ALL=C.UTF-8 i label=0 width=0 line
  for (( i = 1; i <= $#; i += 2 )); do
    line=${!i}; (( ${#line} > label )) && label=${#line}
  done
  label=$(( label + 2 ))   # two spaces before the values
  for (( i = 2; i <= $#; i += 2 )); do
    line=${!i}; (( label + ${#line} > width )) && width=$(( label + ${#line} ))
  done
  while (( $# )); do
    printf '%s%*s%s%-*s%s%s%s\n' "$MARGIN" $(( (LAYOUT_WIDTH - width) / 2 )) '' "$C_SOFT" "$label" "$1" "$C_TEXT" "$2" "$C_RESET"
    shift 2
  done
}

# info, for the screens outside the steps (on a step's, the screen shows a
# fact instead, and info only goes to the log, as note does). Warnings and
# errors also go to the log: the next step header, or the USB's failure
# screen, clears the screen.
info() {
  if (( FACTS_ON )); then printf '[info] %s\n' "$*" >> "$LOG_FILE" 2>/dev/null || true; return 0; fi
  centred_message "$C_TEXT" "$*"
  echo
}
# note "Text" — only in the log: something the installer worked around by
# itself, which tells whoever is installing nothing they can act on.
note() { printf '[note] %s\n' "$*" >> "$LOG_FILE" 2>/dev/null || true; }

# Centred, as info is, without a tag, their lines as even as they can be.
# The words to say: what happened, plainly, and what to check when there's
# something; a die's is followed by the USB's "The installation stopped".
warn() {
  centred_message "$C_WARN$C_BOLD" "$*" >&2
  echo >&2
  printf '[warn] %s\n' "$*" >> "$LOG_FILE" 2>/dev/null || true
}
die() {
  centred_message "$C_ERROR$C_BOLD" "$*" >&2
  printf '[error] %s\n' "$*" >> "$LOG_FILE" 2>/dev/null || true
  exit 1
}

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

# ── Step header and progress ───────────────────────────────────────────
# Each step has a weight, roughly the seconds it takes (step "Title" 53), so
# a long step moves the bar further than a quick one. PROGRESS_DONE is the
# weight of the steps finished, PROGRESS_STEP the current one's, and
# PROGRESS_TOTAL them all (step_weights). A step with several long commands
# splits into shares, one per command (see share). Within a step the bar
# keeps moving, and glides rather than jumps: see update_progress and
# animate_progress. All of this state comes from the environment when set:
# the chroot and desktop phases carry on the install phase's bar where it is
# (progress_env), on screen and in time.
PROGRESS_DONE=${PROGRESS_DONE:-0}
PROGRESS_STEP=${PROGRESS_STEP:-0}
PROGRESS_TOTAL=${PROGRESS_TOTAL:-0}
PROGRESS_PERMILLE=${PROGRESS_PERMILLE:-0}   # of the current step
PROGRESS_SHOWN=${PROGRESS_SHOWN:--1}        # eighths drawn (see animate_progress); -1: none yet
PROGRESS_FROM=${PROGRESS_FROM:-0}           # the current share of the step, in permille
PROGRESS_TO=${PROGRESS_TO:-1000}
PROGRESS_SINCE=${PROGRESS_SINCE:-0}         # µs, when the share started (for the log)
PROGRESS_TICK=${PROGRESS_TICK:-0}           # µs, update_progress's last time
PROGRESS_CREEP=${PROGRESS_CREEP:-0}         # its leftover, in thousandths of a permille
PROGRESS_TITLE=${PROGRESS_TITLE:-}          # the current step's, and when it started (µs),
PROGRESS_STARTED=${PROGRESS_STARTED:-0}     # for the log
BAR_ROW=${BAR_ROW:-0}                       # the bar's screen row, once a header has drawn it
PROGRESS_TARGET=0
PROGRESS_WIDTH=40

# progress_env — the bar's state as NAME=value lines, for env: a phase
# started from this one carries on the same bar, and the same Linux fact.
progress_env() {
  local var
  for var in PROGRESS_DONE PROGRESS_STEP PROGRESS_TOTAL PROGRESS_PERMILLE PROGRESS_SHOWN \
             PROGRESS_FROM PROGRESS_TO PROGRESS_SINCE PROGRESS_TICK PROGRESS_CREEP \
             PROGRESS_TITLE PROGRESS_STARTED BAR_ROW FACTS_ON FACT_INDEX FACT_STRIDE FACT_SINCE; do
    printf '%s=%s\n' "$var" "${!var}"
  done
}

# step_weights FILE — the sum of the weights of FILE's step lines.
step_weights() {
  awk '/^  step "[^"]*" [0-9]+/ { sum += $NF } END { print sum + 0 }' "$1"
}

# logo_lines — the logo (logo_file) as printable lines in LOGO_LINES, its
# width in columns in LOGO_WIDTH. Its .colors file gives each cell a hex
# digit, fg * 4 + bg, of the colours 0 background, 1 letters, 2 extrusion,
# 3 Pac-Man: on the console the palette's slots 0, 6, 2 and 3 (slots 0-7,
# as 512-glyph fonts have no others), elsewhere the same colours as 24-bit
# RGB, since a terminal emulator doesn't use CONSOLE_PALETTE.
# Built once, and kept while the logo file is the same (LOGO_BUILT): every
# screen draws it.
LOGO_BUILT=''
logo_lines() {
  local file colours LC_ALL=C.UTF-8   # ${#} and ${:i:1} count characters, not bytes
  file=$(logo_file) colours=${file%.txt}.colors
  [[ $file != "$LOGO_BUILT" ]] || return 0
  LOGO_BUILT=$file LOGO_LINES=() LOGO_WIDTH=0
  [[ -r $file && -r $colours ]] || return 0
  local -a lines attrs fg bg
  mapfile -t lines < "$file"
  mapfile -t attrs < "$colours"
  LOGO_WIDTH=${#lines[0]}
  local i hex
  local -a slots=(0 6 2 3)
  for i in 0 1 2 3; do
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
      attr=$(( 16#$attr ))
      if [[ $char == ' ' ]]; then sgr=0; else sgr="0;${fg[attr / 4]};${bg[attr % 4]}"; fi
      [[ $sgr != "$prev" ]] && out+=$'\e['"${sgr}m" prev=$sgr
      out+=$char
    done
    LOGO_LINES+=("$out$C_RESET")
  done
}

# The logo, then TAGLINE (config.sh) underneath.
draw_logo() {
  logo_lines
  (( LOGO_WIDTH )) || return 0
  printf '\n\n'
  local line
  for line in "${LOGO_LINES[@]}"; do
    center "$line" "$LOGO_WIDTH"
  done
  echo
  center "${C_TAGLINE}${TAGLINE}${C_RESET}" "${#TAGLINE}"
  echo
}

# The bar's filled and empty parts are the same █ in two colours, as not
# every console font has the shade characters (░▒▓). It moves an eighth of a
# cell at a time: the cell at its edge is one of ▏▎▍▌▋▊▉, filled colour on
# the empty colour, a pixel column each in the 8-wide console font. The
# stock console fonts lack those, so without a patched one (PATCHED_FONT)
# it moves a whole cell at a time.
EIGHTHS=('' ▏ ▎ ▍ ▌ ▋ ▊ ▉)
draw_progress() {
  # Before the first step (the questions), a blank line in its place, so
  # the title doesn't move when the bar appears.
  (( PROGRESS_TOTAL > 0 && PROGRESS_DONE + PROGRESS_STEP > 0 )) || { echo; return 0; }
  # Drawn where the animation has got to; a process that hasn't drawn it
  # yet (the desktop phase, carrying on the installer's bar) starts where it
  # should be.
  progress_eighths
  (( PROGRESS_SHOWN >= 0 && PROGRESS_SHOWN <= PROGRESS_TARGET )) || PROGRESS_SHOWN=$PROGRESS_TARGET
  progress_line
  printf '%s\n' "$PROGRESS_LINE"
}

# progress_line — the bar at PROGRESS_SHOWN as a whole line, margin and all,
# in PROGRESS_LINE. Built without a fork ($(...)), so a frame of the
# animation is quick to make, and it's written in one go over the last.
progress_line() {
  local full=$(( PROGRESS_SHOWN / 8 )) part=$(( PROGRESS_SHOWN % 8 )) filled empty edge=''
  if on_console && [[ ${PATCHED_FONT:-0} != 1 ]]; then part=0; fi
  printf -v filled '%*s' "$full" ''
  printf -v empty '%*s' $(( PROGRESS_WIDTH - full - (part > 0) )) ''
  (( part )) && edge=$'\e[44m'"${C_ACCENT}${EIGHTHS[part]}${C_RESET}"   # (on the empty part's navy)
  printf -v PROGRESS_LINE '%s%*s%s%s%s%s%s%s%s' "$MARGIN" $(( (LAYOUT_WIDTH - PROGRESS_WIDTH) / 2 )) '' \
    "$C_ACCENT" "${filled// /█}" "$C_RESET" "$edge" "$C_EMPTY" "${empty// /█}" "$C_RESET"
}

# Where the bar should be, in PROGRESS_TARGET, in eighths of a cell: the
# steps done, plus the current one's permille. (A variable, not output: the
# animation asks 20 times a second, and $(...) would fork each time.)
progress_eighths() {
  local max=$(( PROGRESS_WIDTH * 8 ))
  PROGRESS_TARGET=$(( max * (PROGRESS_DONE * 1000 + PROGRESS_STEP * PROGRESS_PERMILLE) / (PROGRESS_TOTAL * 1000) ))
  (( PROGRESS_TARGET <= max )) || PROGRESS_TARGET=$max
}

# update_progress [OUTPUT] — how far into the current step we are, in
# PROGRESS_PERMILLE; run()'s spinner asks 5 times a second. It never stands
# still: each time it creeps on towards 95% of the current share (the rest
# is the next share's or step's to give), by a part of the distance left
# that shrinks as that distance does, so it slows down but keeps moving, at
# a pace set by the share's expected seconds (its part of the step's
# weight). Creeping from wherever the bar is, not along a fixed curve, it
# carries on after a measured jump too, where a curve would have fallen
# behind and left the bar standing. And when the running command reports
# its real progress (measured_progress), the bar goes at least that far.
# animate_progress moves the bar there.
update_progress() {
  (( BAR_ROW > 0 && PROGRESS_STEP > 0 )) || return 0
  local now=${EPOCHREALTIME//[!0-9]/}
  local dt=$(( (now - PROGRESS_TICK) / 1000 ))   # ms since the last time; at most 1 s,
  PROGRESS_TICK=$now                             # as nothing creeps between commands
  (( dt >= 0 && dt <= 1000 )) || dt=200
  local span=$(( PROGRESS_TO - PROGRESS_FROM ))
  local ceiling=$(( PROGRESS_FROM + span * 950 / 1000 ))
  local gap=$(( ceiling - PROGRESS_PERMILLE ))
  if (( gap > 0 && span > 0 )); then
    # The distance left shrinks as 1 / (1 + t / tau), tau a third of the
    # expected time (PROGRESS_STEP s * span / 1000, in ms): three quarters
    # of the way when the share should be done, still moving well after.
    # In thousandths of a permille, kept between calls.
    local tau=$(( PROGRESS_STEP * span / 3 + 1 ))
    PROGRESS_CREEP=$(( PROGRESS_CREEP + gap * gap * dt * 1000 / (span * 950 / 1000 * tau) ))
    PROGRESS_PERMILLE=$(( PROGRESS_PERMILLE + PROGRESS_CREEP / 1000 ))
    PROGRESS_CREEP=$(( PROGRESS_CREEP % 1000 ))
    (( PROGRESS_PERMILLE <= ceiling )) || PROGRESS_PERMILLE=$ceiling
  fi
  if [[ -n ${1:-} && -n $RUN_KIND ]]; then
    measured_progress "$1"
    local permille=$(( PROGRESS_FROM + span * MEASURED / 1000 ))
    (( permille > PROGRESS_PERMILLE )) && PROGRESS_PERMILLE=$permille
  fi
  return 0
}

# animate_progress — one frame of the bar easing towards where it should
# be: a tenth of the way each frame, at least an eighth of a cell, so a
# jump in the estimate (a step ending early, a big package landing) plays
# out over a second or two instead of at once. run()'s spinner calls it 20
# times a second. Only the bar is redrawn, and only when it moves.
animate_progress() {
  (( BAR_ROW > 0 && PROGRESS_TOTAL > 0 && PROGRESS_SHOWN >= 0 )) || return 0
  progress_eighths
  (( PROGRESS_SHOWN < PROGRESS_TARGET )) || return 0
  local gap=$(( PROGRESS_TARGET - PROGRESS_SHOWN ))
  PROGRESS_SHOWN=$(( PROGRESS_SHOWN + (gap > 10 ? gap / 10 : 1) ))
  # One write, over the bar as it was: no erasing first (it's always the
  # same width), so there's never a moment with the line blank — which,
  # 20 times a second, was a flicker.
  progress_line
  printf '\e7\e[%d;1H%s\e8' "$BAR_ROW" "$PROGRESS_LINE"
}

# Where pacman saves what it downloads. The install phase's pacstrap fills
# the new system's cache instead, and sets this for its run.
PACMAN_CACHE=/var/cache/pacman/pkg
cache_bytes() {
  local size; size=$(du -sb "$PACMAN_CACHE" 2>/dev/null) || true   # partial when not root
  size=${size%%[[:space:]]*}
  echo "${size:-0}"
}
RUN_KIND='' RUN_CACHE_START=0 MEASURED=0

# measured_progress OUTPUT — the running command's own progress, from its
# OUTPUT, in MEASURED, in permille of its share, up to 950 (as the creep);
# run() sets RUN_KIND for the commands that report any:
#   pacman (and pacstrap): first the download, up to 550, as the cache's
#     growth since the run started (RUN_CACHE_START) against the "Total
#     Download Size" it announced, so the bar keeps the network's real pace;
#     then its checks (keyring, integrity, file conflicts, disk space), each
#     a milestone up to 700; then installing, up to 950, as the "installing
#     <name>..." lines so far against the "Packages (N)" it announced.
#     (Writing to a file, not a terminal, pacman prints no "(n/N)" counts.)
#   git (git clone --progress): its "Receiving objects: n%".
# Not makepkg: its pacman output is only the dependencies, before the build.
measured_progress() {
  local received total packages installed stage downloaded
  if [[ $RUN_KIND == git ]]; then
    received=$(tail -c 2000 "$1" 2>/dev/null | grep -aoE 'Receiving objects: +[0-9]+%' | tail -1) || true
    [[ $received =~ ([0-9]+)% ]] && MEASURED=$(( 950 * BASH_REMATCH[1] / 100 )) || MEASURED=0
    return 0
  fi
  read -r total packages installed stage < <(awk '
    /^Total Download Size:/ && !total {
      m = $5 == "KiB" ? 1024 : $5 == "MiB" ? 1048576 : $5 == "GiB" ? 1073741824 : 1
      total = $4 * m }
    /^Packages \([0-9]+\)/ && !packages { packages = substr($2, 2) + 0 }
    /^(installing|upgrading|reinstalling|downgrading) / { installed++ }
    /^checking keyring/               { stage = 1 }
    /^checking package integrity/     { stage = 2 }
    /^loading package files/          { stage = 3 }
    /^checking for file conflicts/    { stage = 4 }
    /^checking available disk space/  { stage = 5 }
    /^:: Processing package changes/  { stage = 6 }
    END { printf "%d %d %d %d\n", total, packages, installed, stage }' "$1" 2>/dev/null) || true
  if (( ${installed:-0} > 0 && ${packages:-0} > 0 )); then
    MEASURED=$(( 700 + 250 * (installed < packages ? installed : packages) / packages ))
  elif (( ${stage:-0} > 0 )); then
    MEASURED=$(( 550 + 25 * stage ))
  elif (( ${total:-0} > 0 )); then
    downloaded=$(( 1000 * ($(cache_bytes) - RUN_CACHE_START) / total ))
    (( downloaded <= 1000 )) || downloaded=1000
    MEASURED=$(( 550 * downloaded / 1000 ))
  else
    MEASURED=0
  fi
}

# header "Title" [colour] — clears the screen and draws logo, progress bar
# and title: a new screen. The facts are a step's (step turns them back
# on), the centred spinner a wait's (SPIN_CENTRED): any other screen shows
# its info lines, and run's spinner where the cursor is.
header() {
  FACTS_ON=0 SPIN_CENTRED=0
  clear
  update_margin
  draw_logo
  # The bar's row: two blank lines, the logo, a blank, the tagline, a blank.
  BAR_ROW=$(( ${#LOGO_LINES[@]} ? ${#LOGO_LINES[@]} + 6 : 0 ))
  draw_progress
  echo
  center "${C_BOLD}${2:-$C_TEXT}$1${C_RESET}" "${#1}"
  echo; echo
}

# step "Title" WEIGHT — the previous step is done; this one starts, worth
# WEIGHT (roughly its seconds) of the bar.
step() {
  log_step_time
  PROGRESS_TITLE=''
  PROGRESS_DONE=$(( PROGRESS_DONE + PROGRESS_STEP ))
  PROGRESS_STEP=${2:-1} PROGRESS_PERMILLE=0
  PROGRESS_TITLE=$1 PROGRESS_STARTED=${EPOCHREALTIME//[!0-9]/}
  share 0 1000
  # From one step's screen to the next, only what changes: the title, and
  # the last step's warnings gone. Redrawing it all (header) blanks the
  # screen for a frame or two. Unless the terminal has changed size since
  # (another margin), when it's all drawn again.
  local margin=${#MARGIN}
  update_margin
  if (( FACTS_ON && ${#MARGIN} == margin )); then
    retitle "$1"
  else
    header "$1"
    facts_start
  fi
}

# retitle "Title" — on a step's screen, the title replaced and everything
# under the fact cleared (the last step's warnings), the cursor there for
# this one's.
retitle() {
  local LC_ALL=C.UTF-8
  printf '\e[%d;1H\e[2K' $(( BAR_ROW + TITLE_ROW_OFFSET ))
  center "${C_BOLD}${C_TEXT}$1${C_RESET}" "${#1}"
  printf '\e[%d;1H\e[J' $(( BAR_ROW + WARN_ROW_OFFSET ))
}

# share FROM TO — the commands that follow make up this share of the
# current step, in permille, the ones before it being done. For a step with
# several long commands: each one's progress, timed or measured, then moves
# the bar through its own share instead of the whole step, where the first
# to finish would fill it and leave it standing through the rest.
share() {
  # Splitting the current share (from its start, as aur_install does) ends
  # nothing: only the parts get logged.
  (( $1 == PROGRESS_FROM && $2 <= PROGRESS_TO )) || log_share_time
  PROGRESS_FROM=$1 PROGRESS_TO=$2 PROGRESS_SINCE=${EPOCHREALTIME//[!0-9]/} PROGRESS_CREEP=0
  if (( PROGRESS_PERMILLE < $1 )); then PROGRESS_PERMILLE=$1; fi
}

# Logs how long the step that just ended took against its weight, for
# tuning the weights: grep '\[time\]' setup.log. A step split into shares
# logs each share's time first, for tuning those (the share's own end: the
# next share, or the step's).
log_step_time() {
  [[ -n $PROGRESS_TITLE ]] || return 0
  log_share_time
  printf '[time] %s: %ds (weight %d)\n' "$PROGRESS_TITLE" \
    $(( (${EPOCHREALTIME//[!0-9]/} - PROGRESS_STARTED) / 1000000 )) "$PROGRESS_STEP" >> "$LOG_FILE" 2>/dev/null || true
}
log_share_time() {
  [[ -n $PROGRESS_TITLE ]] && (( PROGRESS_FROM > 0 || PROGRESS_TO < 1000 )) || return 0
  printf '[time]   share %d-%d: %ds\n' "$PROGRESS_FROM" "$PROGRESS_TO" \
    $(( (${EPOCHREALTIME//[!0-9]/} - PROGRESS_SINCE) / 1000000 )) >> "$LOG_FILE" 2>/dev/null || true
  PROGRESS_FROM=0 PROGRESS_TO=1000   # logged once
}

# finish "Title" — the closing screen of a phase: full bar, title in green.
finish() {
  log_step_time
  # Full at once: nothing runs after it to animate the bar there.
  PROGRESS_DONE=$PROGRESS_TOTAL PROGRESS_STEP=0 PROGRESS_SHOWN=-1 PROGRESS_TITLE=
  header "$1" "$C_DONE"
}

# ── Linux facts ────────────────────────────────────────────────────────
# While the steps run, the screen under the title shows Pac-Man chomping
# (run's spinner, on the line right under it) and, under that, a Linux fact
# (assets/linux-facts.txt), not the steps' info lines; their warnings and
# errors still show, below the fact, and go with their step's screen. The
# facts keep their own time: each stays up for as long as it takes to read
# (4 s, and about 15 characters a second), whatever the steps do, carrying
# on across their screens and into the later phases (progress_env). The
# file's first, Linux's birth, always comes first; then the others in a
# random order, without repeats until all have been shown: from a random
# one, every FACT_STRIDE'th, a stride with no factor in common with how
# many there are.
FACTS_ON=${FACTS_ON:-0}         # the current screen is a step's, with the facts
FACT_INDEX=${FACT_INDEX:--1}    # the one shown; -1: none yet
FACT_STRIDE=${FACT_STRIDE:-1}
FACT_SINCE=${FACT_SINCE:-0}     # µs, when it went up
FACT_LINES=4                    # the most a fact takes, wrapped
FACTS=()
# The rows under the bar (BAR_ROW): a blank, the title, the spinner, a
# blank, the fact, a blank, then the warnings.
TITLE_ROW_OFFSET=2 SPIN_ROW_OFFSET=3 FACT_ROW_OFFSET=5
WARN_ROW_OFFSET=$(( FACT_ROW_OFFSET + FACT_LINES + 1 ))

# facts_start — a step's screen has been drawn: the fact on it (the same one
# as before, unless its time is up), and the cursor under it, for the
# step's warnings. Not on a screen too short for it all, nor without the
# logo's layout (BAR_ROW), nor without the facts file.
facts_start() {
  (( BAR_ROW > 0 && BAR_ROW + WARN_ROW_OFFSET + 3 <= ROWS )) || return 0
  load_facts
  (( ${#FACTS[@]} )) || return 0
  FACTS_ON=1
  facts_tick draw
  printf '\e[%d;1H' $(( BAR_ROW + WARN_ROW_OFFSET ))
}

load_facts() {
  (( ${#FACTS[@]} )) || mapfile -t FACTS < <(grep -v '^[[:space:]]*\(#\|$\)' "$SETUP_DIR/assets/linux-facts.txt" 2>/dev/null)
}

# facts_tick [draw] — the next fact, once the one shown has had its time
# (run's spinner asks 5 times a second), or the same one again with draw.
facts_tick() {
  (( FACTS_ON )) || return 0
  load_facts   # in a later phase, carrying on the facts of the one that started it
  local LC_ALL=C.UTF-8 n=${#FACTS[@]} now=${EPOCHREALTIME//[!0-9]/} draw=${1:-}
  (( n )) || return 0
  # The others: m of them, from 1.
  local m=$(( n - 1 ))
  if (( FACT_INDEX < 0 || FACT_INDEX >= n )); then
    FACT_INDEX=0 FACT_STRIDE=1 FACT_SINCE=$now draw=1
    local -a strides=() ; local s a b t
    for (( s = 1; s < m; s++ )); do
      a=$s b=$m; while (( b )); do t=$(( a % b )) a=$b b=$t; done
      (( a == 1 )) && strides+=("$s")
    done
    (( ${#strides[@]} )) && FACT_STRIDE=${strides[RANDOM % ${#strides[@]}]}
  elif (( m > 0 && now - FACT_SINCE >= 4000000 + 1000000 * ${#FACTS[FACT_INDEX]} / 15 )); then
    if (( FACT_INDEX == 0 )); then
      FACT_INDEX=$(( 1 + RANDOM % m ))
    else
      FACT_INDEX=$(( 1 + (FACT_INDEX - 1 + FACT_STRIDE) % m ))
    fi
    FACT_SINCE=$now draw=1
  fi
  [[ -n $draw ]] || return 0
  balanced_wrap "${FACTS[FACT_INDEX]}" $(( LAYOUT_WIDTH - 10 ))
  local out=$'\e7' row=$(( BAR_ROW + FACT_ROW_OFFSET )) i line
  for (( i = 0; i < FACT_LINES; i++ )); do
    out+=$'\e['"$(( row + i ))"$';1H\e[2K'
    (( i < ${#WRAPPED[@]} )) || continue
    line=${WRAPPED[i]}
    printf -v line '%s%*s%s%s%s' "$MARGIN" $(( (LAYOUT_WIDTH - ${#line}) / 2 )) '' "$C_SOFT" "$line" "$C_RESET"
    out+=$line
  done
  printf '%s\e8' "$out"
}

# The spinner: Pac-Man chomping a row of pellets, closed with the pellets
# a step away, then open with each moved one step closer, the first at his
# mouth; 7 columns wide.
SPIN_FRAMES=("${C_PAC}⬤${C_RESET}${C_TEXT} · · ·${C_RESET}"
             "${C_PAC}ᗧ${C_RESET}${C_TEXT}· · · ${C_RESET}")
# spin_spot — the cursor to where the spinner goes on a step's screen, or
# a title and a wait's: the line under the title, centred.
spin_spot() { printf '\e[%d;%dH' $(( BAR_ROW + SPIN_ROW_OFFSET )) $(( ${#MARGIN} + (LAYOUT_WIDTH - 7) / 2 + 1 )); }

# SPIN_CENTRED=1 — a screen that's only a title and a wait (set after its
# header, which clears it): run's spinner where a step's goes, centred
# under the title. clear_spinner takes it away, the wait over.
SPIN_CENTRED=0
clear_spinner() { printf '\e7\e[%d;1H\e[2K\e8' $(( BAR_ROW + SPIN_ROW_OFFSET )); }

# with_spinner COMMAND... — COMMAND run in this shell, unlike run's (so the
# variables it sets stay set), with the pellets chomping centred under the
# title meanwhile, from a process of their own. For a command that draws
# nothing; its status is returned.
with_spinner() {
  local spot pid status=0
  spot=$(spin_spot)
  (
    local tick=0
    while :; do
      printf '\e7%s%s\e8' "$spot" "${SPIN_FRAMES[tick % 2]}"
      tick=$(( tick + 1 ))
      sleep 0.2
    done
  ) &
  pid=$!
  "$@" || status=$?
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  return "$status"
}

# Runs a command. Its output always goes to LOG_FILE; the terminal shows a
# spinner. On failure the log marks it ([failed N]), the output is also
# echoed to stderr except on a step's screen (see below), and the real exit
# code is returned, so set -e trips.
run() {
  printf '\n$ %s\n' "$*" >> "$LOG_FILE"
  local out; out=$(mktemp)
  # What kind of progress it reports, if any (measured_progress).
  case " $* " in
    *" pacman "*|*" pacstrap "*) RUN_KIND=pacman RUN_CACHE_START=$(cache_bytes) ;;
    *" git clone "*)             RUN_KIND=git ;;
    *)                           RUN_KIND='' ;;
  esac
  "$@" &>"$out" &
  # Frames at 20 a second, for the bar's animation; Pac-Man chomps (the
  # spinner, SPIN_FRAMES), and the progress (which starts processes) is
  # measured, every 4th.
  local pid=$! tick=0
  # On a step's screen (FACTS_ON), or one that asks for it (SPIN_CENTRED),
  # centred on the line under the title, and left there between commands;
  # elsewhere, where the cursor is.
  local spin=$'\r'"$MARGIN" centred=$(( FACTS_ON || SPIN_CENTRED ))
  (( centred )) && spin=$'\e7'"$(spin_spot)"
  # Without a terminal (the first-login tweaks, in the background), none:
  # its frames would only fill a log.
  local animate=0
  [[ -t 1 ]] && animate=1
  (( animate )) && printf '\e[?25l'   # no cursor blinking after the pellets
  while kill -0 "$pid" 2>/dev/null; do
    if (( animate && tick % 4 == 0 )); then
      printf '%s%s' "$spin" "${SPIN_FRAMES[tick / 4 % 2]}"
      (( centred )) && printf '\e8'
      update_progress "$out"
      facts_tick
    fi
    (( animate )) && animate_progress
    tick=$(( tick + 1 ))
    sleep 0.05
  done
  if (( animate )); then
    (( centred )) || printf '\r\e[K'
    on_console || printf '\e[?25h'   # see cursor()
  fi
  local status=0
  wait "$pid" || status=$?
  cat "$out" >> "$LOG_FILE"
  # On the installer's own screens (a step's, or a title and a wait),
  # nothing of it: a command's own words mean nothing to whoever is
  # installing. The caller says what happened plainly (retry's "trying
  # again", a screen of its own, or the error it stops with), and the log
  # has it all. Elsewhere it's shown.
  if (( status != 0 )); then
    printf '[failed %s] %s\n' "$status" "$*" >> "$LOG_FILE"
    if (( ! centred )); then
      printf '%sFailed (%s): %s%s\n' "$C_ERROR" "$status" "$*" "$C_RESET" >&2
      cat "$out" >&2
    fi
  fi
  rm -f "$out"
  return "$status"
}
