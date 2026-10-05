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
valid_password() { (( ${#1} >= 6 )); }

# input VAR "Prompt:" [validator] [--secret]
# Loops until a non-empty value passes the validator, then stores it in VAR.
input() {
  local __var=$1 __prompt=$2 __validator=${3:-} __secret=${4:-} __val __status
  while :; do
    if have_gum; then
      local -a __args=(--header "$__prompt" --header.foreground 15 --prompt '> '
        --prompt.foreground 14 --cursor.foreground 14 --placeholder ''
        --width $((LAYOUT_WIDTH - 4)) --padding "$(gum_padding)")
      [[ $__secret == --secret ]] && __args+=(--password)
      __val=$(gum input "${__args[@]}") || { __status=$?; gum_cancelled "$__status"; continue; }
      # gum clears itself away; leave the answer on screen like read does.
      ask "$__prompt"
      if [[ $__secret == --secret ]]; then echo '******'; else echo "$__val"; fi
    else
      ask "$__prompt"
      # A failed read means stdin is gone (EOF); looping would spin forever.
      if [[ $__secret == --secret ]]; then read -rs __val || die "Input closed"; echo; else read -r __val || die "Input closed"; fi
    fi
    __val=${__val##+([[:space:]])}; __val=${__val%%+([[:space:]])}
    [[ -n $__val ]] || { warn "Cannot be empty"; continue; }
    if [[ -n $__validator ]] && ! "$__validator" "$__val"; then warn "Invalid value"; continue; fi
    printf -v "$__var" '%s' "$__val"
    return 0
  done
}

# password VAR "Prompt:" — asked twice; both entries must match.
password() {
  local __var=$1 __prompt=$2 __p1 __p2
  while :; do
    input __p1 "$__prompt" valid_password --secret
    input __p2 "Confirm password:" '' --secret
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
      --unselected.foreground 7 --unselected.background 8 "$1" && return 0
    status=$?; gum_cancelled "$status"; return 1
  fi
  [[ $default == y ]] && hint='Y/n' || hint='y/N'
  ask "$1 [$hint]"
  read -r reply
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
      --padding "$(gum_padding)" -- "${items[@]}") && return 0
    status=$?; gum_cancelled "$status"; return 1
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
