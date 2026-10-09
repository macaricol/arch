#!/usr/bin/env bash
# Interactive prompts: validated text input, passwords, arrow-key menu,
# buttons.
#
# All drawn here, in the installer's look, with nothing but the terminal.

shopt -s extglob  # for the +([[:space:]]) trim patterns below

# A round bullet, from the patched console fonts (assets/consolefonts): the
# mask for typed passwords (mask_char). And a cell's upper and lower quarter
# (the upper one in a private-use slot), field's box edges.
DOT=$'\ue010'
UPPER_QUARTER=$'\ue011' LOWER_QUARTER=$'\u2582'

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

# read_key [SECONDS] — waits for a key, into KEY: a name for the keys that
# do something (enter, esc, tab, backspace, ctrl-u, up, down, left, right,
# pgup, pgdn, home, end), else the character typed; empty for other keys
# (their codes read to the end and dropped, not left to be read as typing).
# With SECONDS, returns 2 if no key came in that time. A failed read means
# stdin is gone (EOF), and looping on it would spin forever: that dies.
read_key() {
  local k rest status=0
  KEY=''
  if [[ -n ${1:-} ]]; then
    IFS= read -rsn1 -t "$1" k || status=$?
    (( status <= 128 )) || return 2
    (( status == 0 )) || die "Input closed"
  else
    IFS= read -rsn1 k || die "Input closed"
  fi
  case $k in
    ''|$'\r')      KEY=enter ;;   # (a newline; \r from some terminals)
    $'\t')         KEY=tab ;;
    $'\x7f'|$'\b') KEY=backspace ;;
    $'\x15')       KEY=ctrl-u ;;
    $'\e')
      # Esc alone, or the start of a key's code (arrows: Esc [ A), read to
      # its end (a letter or ~).
      rest=''; IFS= read -rsn1 -t 0.05 rest || true
      [[ -n $rest ]] || { KEY=esc; return 0; }
      while [[ $rest != *[A-Za-z~] ]] && IFS= read -rsn1 -t 0.05 k; do rest+=$k; done
      case $rest in
        '[A'|OA) KEY=up ;;    '[B'|OB) KEY=down ;;
        '[C'|OC) KEY=right ;; '[D'|OD) KEY=left ;;
        '[5~')   KEY=pgup ;;  '[6~')   KEY=pgdn ;;
        '[H'|OH|'[1~') KEY=home ;;
        '[F'|OF|'[4~') KEY=end ;;
      esac ;;
    [[:cntrl:]])   ;;
    *)             KEY=$k ;;
  esac
  return 0
}

# The box a field is typed into: its width, and what to say under the next
# one drawn (a problem with the last answer: FIELD_NOTE, then cleared).
FIELD_WIDTH=24
FIELD_NOTE=''

# field VAR "Label" [plain|secret|reveal] ["Hint"] [VALUE] — a line typed
# into a box: the label centred, the box centred under it (white on the
# empty bar's navy, as the unselected buttons; with a patched console font,
# a quarter row taller above and below the text, so half as tall again),
# FIELD_NOTE under that in amber, then the hint in grey. Starts with
# VALUE. secret shows a dot (mask_char) a character; reveal too, but shows
# the text while Tab is held. Typing past the box scrolls it. Backspace takes a character back,
# Ctrl+U all of them; other keys' codes (arrows...) are ignored. Enter
# stores the text in VAR and returns 0; Esc returns 1 when FIELD_BACK=1 (the
# caller goes back; its hint should say so), and is ignored otherwise.
# Either way the field is cleared away, the cursor back where it started,
# for the next.
field() {
  local LC_ALL=C.UTF-8 __var=$1 __label=$2 __mode=${3:-plain} __hint=${4:-} __text=${5:-}   # ${#} in characters
  local __back=${FIELD_BACK:-0} __note=$FIELD_NOTE __shown=0 __wait=0 __mask __view __inner __left
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
    center "${C_TEXT}${__label}${C_RESET}" "${#__label}"
    echo
    printf '%*s%s%s%s\n' "$__left" '' "$C_EMPTY" "$__above" "$C_RESET"   # lower quarters: the top edge
    printf '%*s%s %s%*s%s\n' "$__left" '' "$C_UNSELECTED" "$__view" $(( __inner - ${#__view} + 1 )) '' "$C_RESET"
    printf '%*s%s%s%s\n\n' "$__left" '' "$C_EMPTY" "$__below" "$C_RESET"   # upper quarters: the bottom
    [[ -z $__note ]] || centred_message "$C_WARN$C_BOLD" "$__note"
    [[ -z $__hint ]] || center "${C_HINT}${__hint}${C_RESET}" "${#__hint}"
    # The cursor in the box, after the text: three rows down from the label.
    printf '\e8\e[3B\e[%dG' $(( __left + 2 + ${#__view} ))
    # reveal: shown while Tab is held. A terminal never hears a key let go,
    # but a held key repeats: shown on the press, kept while its repeats
    # come in, hidden once they stop (none within __wait: longer for the
    # first, as a key starts repeating only after a moment). So a quick tap
    # shows it for that moment. Any other key hides it, and counts as usual.
    if (( __shown )); then
      read_key "$__wait" || { __shown=0; continue; }      # no repeat: let go
      if [[ $KEY == tab ]]; then __wait=0.25; continue; fi
      __shown=0
    else
      read_key
    fi
    case $KEY in
      enter)     break ;;
      tab)       [[ $__mode != reveal ]] || __shown=1 __wait=0.6 ;;
      backspace) __text=${__text%?} ;;
      ctrl-u)    __text='' ;;
      esc)
        (( __back )) || continue
        printf '%s\e8\e[J' "$C_RESET"; cursor off; return 1 ;;
      ?)         __text+=$KEY ;;   # a character typed (one: names are longer)
    esac
  done
  printf '%s\e8\e[J' "$C_RESET"
  cursor off
  printf -v "$__var" '%s' "$__text"
}

# input VAR "Label" [validator] [--secret] — a field (see field) until a
# non-empty answer passes the validator, then it's in VAR. It starts with
# VAR's value, the answer given before (asked again after going back from
# the review), so Enter keeps it; a rejected answer comes back to fix.
# Spaces round the answer are dropped, but not round a secret: they're part
# of a password.
input() {
  local __var=$1 __label=$2 __validator=${3:-} __mode=plain __val=${!1:-}
  [[ ${4:-} == --secret ]] && __mode=secret
  while :; do
    field __val "$__label" "$__mode" '' "$__val"
    [[ $__mode == secret ]] || { __val=${__val##+([[:space:]])}; __val=${__val%%+([[:space:]])}; }
    [[ -n $__val ]] || { FIELD_NOTE="Can't be empty"; continue; }
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
    FIELD_NOTE="Passwords don't match, type them again"
    __p1='' __p2=''
  done
  printf -v "$__var" '%s' "$__p1"
}

# menu "Title" item... — a list to pick from, under the title: centred as
# a block, the current item a box across it (black on the tag colour, as
# the selected button), at most MENU_ROWS items at a time, a page of them,
# with a dot a page under them. ↑↓ move, PgUp PgDn a page, Home End to the
# ends, a letter to the next item starting with it; Enter stores the chosen
# item in MENU_CHOICE and returns 0. Esc returns 1 when MENU_BACK=1 (the
# caller goes back; the hint says so), and is ignored otherwise. It starts
# on the first item, or on MENU_START's when that's set (cleared once used).
# Only the list is redrawn as the selection moves.
MENU_ROWS=10
menu() {
  local title=$1; shift
  local -a items=("$@")
  local LC_ALL=C.UTF-8 selected=0 total=$# start=${MENU_START:-} back=${MENU_BACK:-0} i letter   # ${#} in characters
  local hint="↑↓ choose · Enter select"
  (( back )) && hint+=" · Esc goes back"
  MENU_START='' MENU_BACK=0
  for i in "${!items[@]}"; do [[ ${items[i]} != "$start" ]] || selected=$i; done
  # The block: the longest item with a space each side.
  local width=0 item rows pages page first indent line dots
  for item in "${items[@]}"; do (( ${#item} + 2 > width )) && width=$(( ${#item} + 2 )); done
  indent=$(( ${#MARGIN} + (width < LAYOUT_WIDTH ? (LAYOUT_WIDTH - width) / 2 : 0) ))
  rows=$(( total < MENU_ROWS ? total : MENU_ROWS ))
  pages=$(( (total + rows - 1) / rows ))
  header "$title"
  printf '\e7'   # the list is redrawn from here
  cursor off
  while :; do
    page=$(( selected / rows )) first=$(( selected / rows * rows ))
    printf '%s\e8\e[J' "$C_RESET"
    for (( i = first; i < first + rows; i++ )); do
      if (( i >= total )); then echo                                   # a short last page: the same height
      elif (( i == selected )); then printf '%*s%s %-*s%s\n' "$indent" '' "$C_SELECTED" $(( width - 1 )) "${items[i]}" "$C_RESET"
      else printf '%*s %s\n' "$indent" '' "${items[i]}"
      fi
    done
    echo
    if (( pages > 1 )); then
      dots=''
      for (( i = 0; i < pages; i++ )); do
        if (( i == page )); then dots+="$C_TEXT•"; else dots+="$C_HINT•"; fi
      done
      center "$dots$C_RESET" "$pages"
      echo
    fi
    center "${C_HINT}${hint}${C_RESET}" "${#hint}"
    read_key
    case $KEY in
      enter) MENU_CHOICE=${items[selected]}; return 0 ;;
      esc)   (( back )) && return 1 ;;
      up)    (( selected > 0 )) && selected=$(( selected - 1 )) ;;
      down)  (( selected < total - 1 )) && selected=$(( selected + 1 )) ;;
      pgup)  selected=$(( selected > rows ? selected - rows : 0 )) ;;
      pgdn)  selected=$(( selected + rows < total ? selected + rows : total - 1 )) ;;
      home)  selected=0 ;;
      end)   selected=$(( total - 1 )) ;;
      [[:alnum:]])
        # The next item starting with that letter (any case), after this one.
        letter=${KEY,,}
        for (( i = 1; i <= total; i++ )); do
          item=${items[(selected + i) % total]}
          if [[ ${item,,} == "$letter"* ]]; then
            selected=$(( (selected + i) % total )); break
          fi
        done ;;
    esac
  done
}

# buttons "Title" DEFAULT LABEL DESCRIPTION [LABEL DESCRIPTION...] — a row
# of buttons (the selected one in the tag colour, the others in the empty
# bar's), with the selected one's DESCRIPTION under them, redrawn as the
# selection moves. ←→ (or Tab, h, l) move, Enter picks. Starts on the DEFAULT'th
# (from 0); the picked one's index goes in PICKED. An empty "Title": under
# what's on screen, rather than on a screen of their own.
buttons() {
  local title=$1 selected=$2; shift 2
  local -a labels=() descriptions=()
  while (( $# )); do labels+=("$1"); descriptions+=("$2"); shift 2; done
  local total=${#labels[@]} i row width line
  [[ -z $title ]] || header "$title"
  printf '\e7'   # everything below is redrawn from here
  while :; do
    printf '\e8\e[J'
    row='' width=0
    for i in "${!labels[@]}"; do
      (( i )) && { row+='  '; width=$(( width + 2 )); }
      if (( i == selected )); then row+=$C_SELECTED; else row+=$C_UNSELECTED; fi
      row+="   ${labels[i]}   $C_RESET"
      width=$(( width + ${#labels[i]} + 6 ))
    done
    center "$row" "$width"
    echo
    balanced_wrap "${descriptions[selected]}" $(( LAYOUT_WIDTH - 8 ))
    for line in "${WRAPPED[@]}"; do center "${C_TEXT}${line}${C_RESET}" "${#line}"; done
    echo
    center "${C_HINT}←→ choose · Enter select${C_RESET}" 24
    read_key
    case $KEY in
      enter)       PICKED=$selected; return 0 ;;
      left|h)      selected=$(( (selected - 1 + total) % total )) ;;
      right|l|tab) selected=$(( (selected + 1) % total )) ;;
    esac
  done
}
