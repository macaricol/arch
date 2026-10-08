#!/usr/bin/env bash
# Terminal output: console look, messages, step headers, and the run() spinner.

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

# On a high-resolution screen the default 8x16 font is tiny. Try each font,
# read back the size the console actually ends up with, and keep the one
# nearest ~48 rows that still leaves 80 columns. All three ship with kbd; on
# an already low-resolution console this settles on the default. Each is
# loaded from assets/consolefonts, the same fonts with Pac-Man added, and
# from kbd if that copy is missing.
#
# Root only: the desktop phase, run as the user from the installer, keeps the
# font the install phase loaded.
scale_console_font() {
  on_console && (( EUID == 0 )) && command -v setfont &>/dev/null || return 0
  local target=48 best='' best_diff=99999 font diff dev errors i
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
    term_size
    (( COLS >= 80 )) || continue
    diff=$(( ROWS > target ? ROWS - target : target - ROWS ))
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
# PATCHED_FONT down through the chroot phase to the desktop phase).
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

# plural N WORD — "1 minute", "3 minutes".
plural() { (( $1 == 1 )) && echo "$1 $2" || echo "$1 ${2}s"; }

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

# Warnings and errors also go to the log: the next step header, or the USB's
# failure screen, clears the screen.
info() { message "$TAG" "$C_WHITE" "$*" $'\n\n'; }
warn() {
  message "$C_YELLOW${C_BOLD}ᗧ$C_RESET" "$C_YELLOW$C_BOLD" "$*" $'\n\n' >&2
  printf '[warn] %s\n' "$*" >> "$LOG_FILE" 2>/dev/null || true
}
die() {
  message "$C_RED${C_BOLD}ᗧ$C_RESET" "$C_RED$C_BOLD" "$*" $'\n' >&2
  printf '[error] %s\n' "$*" >> "$LOG_FILE" 2>/dev/null || true
  exit 1
}
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
# started from this one carries on the same bar.
progress_env() {
  local var
  for var in PROGRESS_DONE PROGRESS_STEP PROGRESS_TOTAL PROGRESS_PERMILLE PROGRESS_SHOWN \
             PROGRESS_FROM PROGRESS_TO PROGRESS_SINCE PROGRESS_TICK PROGRESS_CREEP \
             PROGRESS_TITLE PROGRESS_STARTED BAR_ROW; do
    printf '%s=%s\n' "$var" "${!var}"
  done
}

# step_weights FILE — the sum of the weights of FILE's step lines.
step_weights() {
  awk '/^  step "[^"]*" [0-9]+/ { sum += $NF } END { print sum + 0 }' "$1"
}

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
  center "${C_PINK}${TAGLINE}${C_RESET}" "${#TAGLINE}"
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
  (( part )) && edge=$'\e[44m'"${C_CYAN}${EIGHTHS[part]}${C_RESET}"
  printf -v PROGRESS_LINE '%s%*s%s%s%s%s%s%s%s' "$MARGIN" $(( (LAYOUT_WIDTH - PROGRESS_WIDTH) / 2 )) '' \
    "$C_CYAN" "${filled// /█}" "$C_RESET" "$edge" "$C_BLUE" "${empty// /█}" "$C_RESET"
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
# and title for the current step. menu() redraws it on every keypress.
header() {
  clear
  update_margin
  draw_logo
  # The bar's row: two blank lines, the logo, a blank, the tagline, a blank.
  BAR_ROW=$(( ${#LOGO_LINES[@]} ? ${#LOGO_LINES[@]} + 6 : 0 ))
  draw_progress
  echo
  center "${C_BOLD}${2:-$C_WHITE}$1${C_RESET}" "${#1}"
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
  header "$1"
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
  header "$1" "$C_GREEN"
}

# Runs a command. Its output always goes to LOG_FILE; the terminal shows a
# spinner. On failure the output is also echoed to stderr, so the failure
# can be diagnosed, and the real exit code is returned, so set -e trips.
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
  # Pac-Man chomping a row of pellets: closed with the pellets a step away,
  # then open with each moved one step closer, the first at its mouth.
  # Frames at 20 a second, for the bar's animation; Pac-Man chomps, and the
  # progress (which starts processes) is measured, every 4th.
  local pid=$! tick=0
  local -a frames=("${C_BOLD}${C_CYAN}⬤${C_RESET}${C_WHITE} · · ·${C_RESET}"
                   "${C_BOLD}${C_CYAN}ᗧ${C_RESET}${C_WHITE}· · · ${C_RESET}")
  printf '\e[?25l'   # no cursor blinking after the pellets
  while kill -0 "$pid" 2>/dev/null; do
    if (( tick % 4 == 0 )); then
      printf '\r%s%s' "$MARGIN" "${frames[tick / 4 % 2]}"
      update_progress "$out"
    fi
    animate_progress
    tick=$(( tick + 1 ))
    sleep 0.05
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
