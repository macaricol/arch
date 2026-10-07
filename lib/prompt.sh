#!/usr/bin/env bash
# Interactive prompts: validated text input, passwords, arrow-key menu,
# buttons.
#
# gum (https://github.com/charmbracelet/gum) draws them: the USB carries it
# (tools/build-autoinstall-iso.sh). Should it not run there, the plain
# prompts below take over.

shopt -s extglob  # for the +([[:space:]]) trim patterns below

# gum copied from the build machine could, in principle, need a newer glibc
# than the ISO's, and a gum that fails to start would make every prompt
# loop; so it's only used once a test run succeeds.
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

# What to say when a validator rejects an answer.
invalid_hint() {
  case $1 in
    valid_hostname) echo "Use lowercase letters, numbers and dashes" ;;
    valid_username) echo "Start with a letter, then use lowercase letters, numbers, _ and -" ;;
    *)              echo "That doesn't look right, try again" ;;
  esac
}

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
    if [[ -n $__validator ]] && ! "$__validator" "$__val"; then warn "$(invalid_hint "$__validator")"; continue; fi
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

# buttons "Title" DEFAULT LABEL DESCRIPTION [LABEL DESCRIPTION...] — a row
# of buttons, like gum confirm's (the selected one in the tag colour, the
# others in the empty bar's), with the selected one's DESCRIPTION under
# them, redrawn as the selection moves; gum can't change text under its
# buttons. ←→ (or Tab, h, l) move, Enter picks. Starts on the DEFAULT'th
# (from 0); the picked one's index goes in PICKED.
buttons() {
  local title=$1 selected=$2; shift 2
  local -a labels=() descriptions=()
  while (( $# )); do labels+=("$1"); descriptions+=("$2"); shift 2; done
  local total=${#labels[@]} key seq i row width line
  header "$title"
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
    wrap "${descriptions[selected]}" $(( LAYOUT_WIDTH - 8 ))
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
# mask for typed passwords (mask_char).
DOT=$'\ue010'
