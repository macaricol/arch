#!/usr/bin/env bash
# Interactive prompts: validated text input, passwords, yes/no, arrow-key menu.
#
# gum (https://github.com/charmbracelet/gum) draws them when it's available:
# the install phase fetches it onto the live ISO and the post phase installs
# it on the new system. Without it, the plain prompts below take over.

shopt -s extglob  # for the +([[:space:]]) trim patterns below

# gum installed by a partial `pacman -Sy` could be built against a newer
# glibc than the ISO's, and a gum that fails to start would make every
# prompt loop; so it's only used once a test run succeeds. Not cached until
# then, as the install phase fetches it after this file is loaded.
have_gum() {
  [[ -t 0 ]] || return 1
  [[ -n ${GUM_OK:-} ]] || { gum --version &>/dev/null && GUM_OK=1 || return 1; }
}

# gum's arguments for the layout column. Colours are palette indexes, not
# hex, so on the console they follow CONSOLE_PALETTE.
gum_padding() { echo "0 0 0 ${#MARGIN}"; }

# gum exits 1 on Esc and 130 on Ctrl+C: Esc asks again, Ctrl+C quits.
gum_cancelled() { (( $1 == 130 )) && die "Cancelled."; return 0; }

valid_hostname() { [[ $1 =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]; }
valid_username() { [[ $1 =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; }

# input VAR "Prompt" [validator] [--secret]
# Asks on one line, "ᗧ Prompt > answer", followed by a blank line. Loops
# until a non-empty value passes the validator, then stores it in VAR.
input() {
  local __var=$1 __prompt="$2 >" __validator=${3:-} __secret=${4:-} __val __status
  while :; do
    if have_gum; then
      # gum strips colour codes from its prompt, so the tag can't be part of
      # it: gum is indented by the tag's columns instead, and the answer
      # line printed afterwards adds the tag without moving the text.
      local -a __args=(--prompt "$__prompt " --prompt.foreground 15
        --cursor.foreground 14 --placeholder '' --no-show-help
        --width $((LAYOUT_WIDTH - TAG_COLS - 2)) --padding "0 0 0 $(( ${#MARGIN} + TAG_COLS ))")
      [[ $__secret == --secret ]] && __args+=(--password)
      # gum hides the cursor while it runs and shows it again on exit.
      __val=$(gum input "${__args[@]}") || { __status=$?; cursor off; gum_cancelled "$__status"; continue; }
      cursor off
      # gum clears itself away; leave the answer on screen like read does.
      ask "$__prompt"
      if [[ $__secret == --secret ]]; then repeat "$(mask_char)" 6; echo; else echo "$__val"; fi
    else
      ask "$__prompt"
      # A failed read means stdin is gone (EOF); looping would spin forever.
      cursor on
      if [[ $__secret == --secret ]]; then read_secret __val; else read -r __val || die "Input closed"; fi
      cursor off
    fi
    echo
    __val=${__val##+([[:space:]])}; __val=${__val%%+([[:space:]])}
    [[ -n $__val ]] || { warn "Cannot be empty"; continue; }
    if [[ -n $__validator ]] && ! "$__validator" "$__val"; then warn "Invalid value"; continue; fi
    printf -v "$__var" '%s' "$__val"
    return 0
  done
}

# The character a typed secret is masked with: the round dot from the
# patched console fonts when one is loaded, else •.
mask_char() {
  if on_console && [[ ${PATCHED_FONT:-0} == 1 ]]; then printf '%s' "$DOT"; else printf '•'; fi
}

# read_secret VAR — reads a line without echoing it, but with a mask_char per
# key typed (Backspace takes one back), like gum's password field. For when
# gum isn't available.
read_secret() {
  local __var=$1 __s='' __k __rest __mask
  __mask=$(mask_char)
  while :; do
    IFS= read -rsn1 __k || die "Input closed"
    case $__k in
      '')            break ;;
      $'\x7f'|$'\b') [[ -n $__s ]] && { __s=${__s%?}; printf '\b \b'; } ;;
      $'\e')         read -rsn5 -t 0.01 __rest || true ;;   # arrow keys etc.
      *)             __s+=$__k; printf '%s' "$__mask" ;;
    esac
  done
  echo
  printf -v "$__var" '%s' "$__s"
}

# password VAR "Prompt" — asked twice; both entries must match.
password() {
  local __var=$1 __prompt=$2 __p1 __p2
  while :; do
    input __p1 "$__prompt" '' --secret
    input __p2 "Confirm password" '' --secret
    [[ $__p1 == "$__p2" ]] && break
    warn "Passwords do not match"
  done
  printf -v "$__var" '%s' "$__p1"
}

# confirm "Question?" [y|n default] — returns 0 for yes
confirm() {
  local default=${2:-y} hint reply status
  if have_gum; then
    [[ $default == y ]] && hint=true || hint=false
    gum confirm --default="$hint" --padding "$(gum_padding)" --prompt.foreground 15 \
      --selected.foreground 0 --selected.background 6 \
      --unselected.foreground 15 --unselected.background 4 "$1" && { cursor off; return 0; }
    status=$?; cursor off; gum_cancelled "$status"; return 1
  fi
  [[ $default == y ]] && hint='Y/n' || hint='y/N'
  ask "$1 [$hint]"
  cursor on
  read -r reply
  cursor off
  reply=${reply:-$default}
  [[ $reply =~ ^[Yy] ]]
}

# menu "Title" item... — arrow-key picker. Enter stores the chosen item in
# MENU_CHOICE and returns 0; Esc or q returns 1.
menu() {
  local title=$1; shift
  local -a items=("$@")
  local selected=0 total=${#items[@]} key seq i status
  if have_gum; then
    header "$title"
    MENU_CHOICE=$(gum choose --header '' --height $(( total < 10 ? total : 10 )) \
      --cursor '> ' --cursor.foreground 14 --selected.foreground 14 \
      --padding "$(gum_padding)" -- "${items[@]}") && { cursor off; return 0; }
    status=$?; cursor off; gum_cancelled "$status"; return 1
  fi
  while :; do
    header "$title"
    for ((i = 0; i < total; i++)); do
      if (( i == selected )); then
        printf '%s %s>%s %s\n' "$MARGIN" "$C_REVERSE" "$C_RESET" "${items[i]}"
      else
        printf '%s   %s\n' "$MARGIN" "${items[i]}"
      fi
    done
    echo
    center "${C_GREY}↑↓ navigate · Enter select · Esc cancel${C_RESET}" 39
    read -rsn1 key
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

# unlock_screen VAR "Hint" ["Error"] — a full-screen password prompt in the
# style of Omarchy's: logo and tagline in the middle of the screen, a
# padlock beside a password box under them, the hint (or the error, in red)
# below. Reads the password itself, a dot per character, as gum can't draw
# inside a box; Backspace and Ctrl+U edit. Stores the password in VAR.
# Omarchy's padlock, 5 columns by 3 rows of tiles from assets/consolefonts
# (U+E000-U+E00E, see tools/make-console-fonts.py), one row per box row.
LOCK=($'\ue000\ue001\ue002\ue003\ue004' $'\ue005\ue006\ue007\ue008\ue009'
      $'\ue00a\ue00b\ue00c\ue00d\ue00e')
DOT=$'\ue010'   # a round bullet, from the same fonts
unlock_screen() {
  local __var=$1 __hint=$2 __error=${3:-} LC_ALL=C.UTF-8
  local -a __logo
  mapfile -t __logo < "$(logo_file)"
  local __box=36 __pw='' __key __rest __line __shown
  # logo, blank, tagline, 2 blanks, box (3 rows), blank, message
  local __top=$(( ($(term_rows) - ${#__logo[@]} - 9) / 2 + 1 ))
  (( __top < 1 )) && __top=1
  clear
  update_margin
  printf '\e[%d;1H' "$__top"
  for __line in "${__logo[@]}"; do center "${C_CYAN}${__line}${C_RESET}" "${#__logo[0]}"; done
  echo
  center "${C_PINK}${TAGLINE}${C_RESET}" "${#TAGLINE}"
  printf '\n\n'
  # the padlock and a space, then the box and its 2 borders
  local __pad=$(( ${#MARGIN} + (LAYOUT_WIDTH - 5 - 1 - __box - 2) / 2 ))
  printf '%*s%s%s%s %s┌%s┐%s\n' "$__pad" '' "$C_CYAN" "${LOCK[0]}" "$C_RESET" "$C_GREY" "$(repeat ─ "$__box")" "$C_RESET"
  printf '%*s%s%s%s %s│%*s│%s\n' "$__pad" '' "$C_CYAN" "${LOCK[1]}" "$C_RESET" "$C_GREY" "$__box" '' "$C_RESET"
  printf '%*s%s%s%s %s└%s┘%s\n' "$__pad" '' "$C_CYAN" "${LOCK[2]}" "$C_RESET" "$C_GREY" "$(repeat ─ "$__box")" "$C_RESET"
  echo
  if [[ -n $__error ]]; then
    center "${C_RED}${__error}${C_RESET}" "${#__error}"
  else
    center "${C_GREY}${__hint}${C_RESET}" "${#__hint}"
  fi

  # The field: the box's middle row, one space in from its left border.
  local __row=$(( __top + ${#__logo[@]} + 5 )) __col=$(( __pad + 5 + 1 + 1 + 2 ))
  cursor on
  while :; do
    __shown=$(( ${#__pw} < __box - 2 ? ${#__pw} : __box - 2 ))
    printf '\e[%d;%dH%s%s%*s\e[%d;%dH' "$__row" "$__col" "$C_WHITE" "$(repeat "$DOT" "$__shown")$C_RESET" \
      $(( __box - 2 - __shown )) '' "$__row" $(( __col + __shown ))
    IFS= read -rsn1 __key || die "Input closed"
    case $__key in
      '')            break ;;                             # Enter
      $'\x7f'|$'\b') __pw=${__pw%?} ;;                     # Backspace
      $'\x15')       __pw='' ;;                           # Ctrl+U
      $'\e')         read -rsn5 -t 0.01 __rest || true ;; # swallow arrow keys etc.
      *)             __pw+=$__key ;;
    esac
  done
  cursor off
  printf -v "$__var" '%s' "$__pw"
}
