#!/usr/bin/env bash
# Interactive prompts: validated text input, passwords, arrow-key menu,
# buttons.
#
# The text fields and buttons are drawn here; the menu by gum
# (https://github.com/charmbracelet/gum), which the USB carries
# (tools/build-autoinstall-iso.sh), or a plain one should it not run there.

shopt -s extglob  # for the +([[:space:]]) trim patterns below

# gum copied from the build machine could, in principle, need a newer glibc
# than the ISO's, and a gum that fails to start would make every prompt
# loop; so it's only used once a test run succeeds.
have_gum() {
  [[ -t 0 ]] || return 1
  [[ -n ${GUM_OK:-} ]] || { gum --version &>/dev/null && GUM_OK=1 || return 1; }
}

# gum exits 1 on Esc and 130 on Ctrl+C: Esc asks again, Ctrl+C quits.
gum_cancelled() { (( $1 == 130 )) && die "Cancelled."; return 0; }

valid_hostname() { [[ $1 =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]; }
valid_username() { [[ $1 =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; }

# What to say when a validator rejects an answer.
invalid_hint() {
  case $1 in
    valid_hostname) echo "Use lowercase letters, numbers and dashes" ;;
    valid_username) echo "Start with a letter, then use lowercase letters, numbers, _ and -" ;;
    *)              echo "That doesn't look right, try again" ;;
  esac
}

# The box a field is typed into: its width, and what to say under the next
# one drawn (a problem with the last answer: FIELD_NOTE, then cleared).
FIELD_WIDTH=24
FIELD_NOTE=''

# field VAR "Label" [plain|secret|reveal] ["Hint"] [VALUE] — a line typed
# into a box: the label centred, the box centred under it (white on the
# empty bar's navy, as the unselected buttons; with a patched console font,
# a quarter row taller above and below the text, so half as tall again),
# FIELD_NOTE under that in amber, then the hint in grey. Starts with VALUE. secret shows a dot
# (mask_char) a character; reveal too, but shows the text while Tab is
# held. Typing past the box scrolls it. Backspace takes a character back,
# Ctrl+U all of them; other keys' codes (arrows...) are ignored. Enter
# stores the text in VAR and returns 0, Esc returns 1; either way the
# field is cleared away, the cursor back where it started, for the next.
# Its own, not gum's: gum's field has no box, and can't be shown while
# typing a password.
field() {
  local LC_ALL=C.UTF-8 __var=$1 __label=$2 __mode=${3:-plain} __hint=${4:-} __text=${5:-}   # ${#} in characters
  local __note=$FIELD_NOTE __shown=0 __wait=0 __status __key __rest __mask __view __inner __left
  FIELD_NOTE=''
  __mask=$(mask_char)
  __inner=$(( FIELD_WIDTH - 2 ))   # a space each side
  __left=$(( ${#MARGIN} + (LAYOUT_WIDTH - FIELD_WIDTH) / 2 ))
  # The box's edges, a row each: the quarters in its navy, or (without the
  # glyphs) blank, the same rows taken either way.
  local __above='' __below=''
  if on_console && [[ ${PATCHED_FONT:-0} == 1 ]]; then
    __above=$(repeat "$LOWER_QUARTER" "$FIELD_WIDTH") __below=$(repeat "$UPPER_QUARTER" "$FIELD_WIDTH")
  fi
  # The field's spot: the one cursor position saved (\e7), and never saved
  # over, as each frame is redrawn from it (\e8, then \e[J to clear below).
  printf '\e7'
  cursor on
  while :; do
    if [[ $__mode == plain ]] || (( __shown )); then __view=$__text; else __view=$(repeat "$__mask" "${#__text}"); fi
    (( ${#__view} < __inner )) || __view=${__view: -$(( __inner - 1 ))}   # the end, and room for the cursor
    printf '%s\e8\e[J' "$C_RESET"
    center "${C_WHITE}${__label}${C_RESET}" "${#__label}"
    echo
    printf '%*s%s%s%s\n' "$__left" '' "$C_BLUE" "$__above" "$C_RESET"   # lower quarters: the top edge
    printf '%*s\e[97;44m %s%*s%s\n' "$__left" '' "$__view" $(( __inner - ${#__view} + 1 )) '' "$C_RESET"
    printf '%*s%s%s%s\n\n' "$__left" '' "$C_BLUE" "$__below" "$C_RESET"   # upper quarters: the bottom
    [[ -z $__note ]] || centred_message "$C_YELLOW$C_BOLD" "$__note"
    [[ -z $__hint ]] || center "${C_GREY}${__hint}${C_RESET}" "${#__hint}"
    # The cursor in the box, after the text: three rows down from the label.
    printf '\e8\e[3B\e[%dG' $(( __left + 2 + ${#__view} ))
    # reveal: shown while Tab is held. A terminal never hears a key let go,
    # but a held key repeats: shown on the press, kept while its repeats
    # come in, hidden once they stop (none within __wait: longer for the
    # first, as a key starts repeating only after a moment). So a quick tap
    # shows it for that moment. Any other key hides it, and counts as usual.
    if (( __shown )); then
      __status=0; IFS= read -rsn1 -t "$__wait" __key || __status=$?
      if (( __status > 128 )); then __shown=0; continue; fi     # no repeat: let go
      (( __status == 0 )) || die "Input closed"
      if [[ $__key == $'\t' ]]; then __wait=0.25; continue; fi
      __shown=0
    else
      # A failed read means stdin is gone (EOF); looping would spin forever.
      IFS= read -rsn1 __key || die "Input closed"
    fi
    case $__key in
      ''|$'\r')      break ;;   # Enter (a newline; \r from some terminals)
      $'\t')         [[ $__mode != reveal ]] || __shown=1 __wait=0.6 ;;
      $'\x7f'|$'\b') __text=${__text%?} ;;
      $'\x15')       __text='' ;;                                     # Ctrl+U
      $'\e')
        # Esc alone, or the start of a key's code (arrows: Esc [ A...),
        # which is read to its end (a letter or ~) and ignored.
        __rest=''; read -rsn1 -t 0.05 __rest || true
        if [[ -z $__rest ]]; then printf '%s\e8\e[J' "$C_RESET"; cursor off; return 1; fi
        while [[ $__rest != [A-Za-z~] ]] && read -rsn1 -t 0.05 __rest; do :; done ;;
      [[:cntrl:]])   ;;
      *)             __text+=$__key ;;
    esac
  done
  printf '%s\e8\e[J' "$C_RESET"
  cursor off
  printf -v "$__var" '%s' "$__text"
}

# input VAR "Label" [validator] [--secret] — a field (see field) until a
# non-empty answer passes the validator, then it's in VAR. It starts with
# VAR's value, the answer given before (asked again after going back from
# the review), so Enter keeps it; a rejected answer comes back to fix. Esc
# asks again.
input() {
  local __var=$1 __label=$2 __validator=${3:-} __mode=plain __val=${!1:-}
  [[ ${4:-} == --secret ]] && __mode=secret
  while :; do
    field __val "$__label" "$__mode" '' "$__val" || continue
    __val=${__val##+([[:space:]])}; __val=${__val%%+([[:space:]])}
    [[ -n $__val ]] || { FIELD_NOTE="Cannot be empty"; continue; }
    if [[ -n $__validator ]] && ! "$__validator" "$__val"; then FIELD_NOTE=$(invalid_hint "$__validator"); continue; fi
    printf -v "$__var" '%s' "$__val"
    return 0
  done
}

# The character a typed secret is masked with: the round dot from the
# patched console fonts when one is loaded, else •.
mask_char() {
  if on_console && [[ ${PATCHED_FONT:-0} == 1 ]]; then printf '%s' "$DOT"; else printf '•'; fi
}

# password VAR "Label" — asked twice; both entries must match. Both start
# with VAR's password, the one given before, so Enter twice keeps it; after
# a mismatch, both empty.
password() {
  local __var=$1 __label=$2 __p1=${!1:-} __p2=${!1:-}
  while :; do
    input __p1 "$__label" '' --secret
    input __p2 "Confirm password" '' --secret
    [[ $__p1 == "$__p2" ]] && break
    FIELD_NOTE="Passwords do not match, type them again"
    __p1='' __p2=''
  done
  printf -v "$__var" '%s' "$__p1"
}

# menu "Title" item... — arrow-key picker. Enter stores the chosen item in
# MENU_CHOICE and returns 0; Esc or q returns 1. It starts on the first
# item, or on MENU_START's when that's set (cleared once used).
menu() {
  local title=$1; shift
  local -a items=("$@")
  local selected=0 total=${#items[@]} key seq i status start=${MENU_START:-}
  MENU_START=''
  for i in "${!items[@]}"; do [[ ${items[i]} != "$start" ]] || selected=$i; done
  # Centred under the title, as a block: the longest item with a space each
  # side, or gum's help line under them ("←↓↑→ navigate • enter submit")
  # when that's wider. The current item is a box across the block, in the
  # buttons' colours (black on the tag colour): every item padded to the
  # block's width, less the space gum's cursor puts before it, and the
  # padding taken off the answer.
  local LC_ALL=C.UTF-8 width=28 indent item
  for item in "${items[@]}"; do (( ${#item} + 2 > width )) && width=$(( ${#item} + 2 )); done
  indent=$(( ${#MARGIN} + (width < LAYOUT_WIDTH ? (LAYOUT_WIDTH - width) / 2 : 0) ))
  local -a padded=()
  for item in "${items[@]}"; do padded+=("$(printf '%-*s' $(( width - 1 )) "$item")"); done
  if have_gum; then
    header "$title"
    # Colours are palette indexes, not hex: on the console they follow
    # CONSOLE_PALETTE (backgrounds only 0-7 there, with the 512-glyph font).
    MENU_CHOICE=$(gum choose --header '' --height $(( total < 10 ? total : 10 )) --selected "${padded[selected]}" \
      --cursor ' ' --cursor.foreground 0 --cursor.background 6 \
      --padding "0 0 0 $indent" -- "${padded[@]}") \
      && { MENU_CHOICE=${MENU_CHOICE%%+( )}; cursor off; return 0; }
    status=$?; cursor off; gum_cancelled "$status"; return 1
  fi
  while :; do
    header "$title"
    for ((i = 0; i < total; i++)); do
      if (( i == selected )); then
        printf '%*s\e[30;46m %s%s\n' "$indent" '' "${padded[i]}" "$C_RESET"
      else
        printf '%*s %s\n' "$indent" '' "${items[i]}"
      fi
    done
    echo
    center "${C_GREY}↑↓ navigate · Enter select${C_RESET}" 26
    # A failed read means stdin is gone (EOF); looping would spin forever.
    IFS= read -rsn1 key || die "Input closed"
    case $key in
      '')   MENU_CHOICE=${items[selected]}; return 0 ;;
      q|Q)  return 1 ;;
      $'\e')
        # Arrow keys arrive as ESC [ A/B; a lone ESC (nothing within 0.1s) is cancel.
        read -rsn2 -t 0.1 seq || return 1
        case $seq in
          '[A') selected=$(( (selected - 1 + total) % total )) ;;
          '[B') selected=$(( (selected + 1) % total )) ;;
        esac ;;
    esac
  done
}

# buttons "Title" DEFAULT LABEL DESCRIPTION [LABEL DESCRIPTION...] — a row
# of buttons, like gum confirm's (the selected one in the tag colour, the
# others in the empty bar's), with the selected one's DESCRIPTION under
# them, redrawn as the selection moves; gum can't change text under its
# buttons. ←→ (or Tab, h, l) move, Enter picks. Starts on the DEFAULT'th
# (from 0); the picked one's index goes in PICKED. An empty "Title": under
# what's on screen, rather than on a screen of their own.
buttons() {
  local title=$1 selected=$2; shift 2
  local -a labels=() descriptions=()
  while (( $# )); do labels+=("$1"); descriptions+=("$2"); shift 2; done
  local total=${#labels[@]} key seq i row width line
  [[ -z $title ]] || header "$title"
  printf '\e7'   # everything below is redrawn from here
  while :; do
    printf '\e8\e[J'
    row='' width=0
    for i in "${!labels[@]}"; do
      (( i )) && { row+='  '; width=$(( width + 2 )); }
      if (( i == selected )); then row+=$'\e[30;46m'; else row+=$'\e[97;44m'; fi
      row+="   ${labels[i]}   $C_RESET"
      width=$(( width + ${#labels[i]} + 6 ))
    done
    center "$row" "$width"
    echo
    balanced_wrap "${descriptions[selected]}" $(( LAYOUT_WIDTH - 8 ))
    for line in "${WRAPPED[@]}"; do center "${C_WHITE}${line}${C_RESET}" "${#line}"; done
    echo
    center "${C_GREY}←→ choose · Enter select${C_RESET}" 24
    IFS= read -rsn1 key || die "Input closed"
    case $key in
      '')    PICKED=$selected; return 0 ;;
      $'\t') selected=$(( (selected + 1) % total )) ;;
      h)     selected=$(( (selected - 1 + total) % total )) ;;
      l)     selected=$(( (selected + 1) % total )) ;;
      $'\e')
        # Arrow keys arrive as ESC [ C/D; anything else is ignored.
        read -rsn2 -t 0.1 seq || seq=''
        case $seq in
          '[D') selected=$(( (selected - 1 + total) % total )) ;;
          '[C') selected=$(( (selected + 1) % total )) ;;
        esac ;;
    esac
  done
}

# choose_look — asks which look the desktop gets, into LOOK: plain (KDE as
# it comes) or archman (the installer's theming, the default).
choose_look() {
  buttons "Choose your desktop's look" 1 \
    Vanilla "KDE Plasma as it comes: KDE's own Breeze theme, login screen and wallpaper." \
    Archman "Dark theme, the ARCHMAN login screen, a cyberpunk wallpaper, Breeze Chameleon icons, a top panel and a clock widget."
  if (( PICKED == 0 )); then LOOK=plain; else LOOK=archman; fi
}

# A round bullet, from the patched console fonts (assets/consolefonts): the
# mask for typed passwords (mask_char). And a cell's upper and lower quarter
# (the upper one in a private-use slot), field's box edges.
DOT=$'\ue010'
UPPER_QUARTER=$'\ue011' LOWER_QUARTER=$'\u2582'
