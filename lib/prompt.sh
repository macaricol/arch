#!/usr/bin/env bash
# Interactive prompts: validated text input, passwords, yes/no, arrow-key menu.

shopt -s extglob  # for the +([[:space:]]) trim patterns below

valid_hostname() { [[ $1 =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]; }
valid_username() { [[ $1 =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; }
valid_password() { (( ${#1} >= 6 )); }

# input VAR "Prompt:" [validator] [--secret]
# Loops until a non-empty value passes the validator, then stores it in VAR.
input() {
  local __var=$1 __prompt=$2 __validator=${3:-} __secret=${4:-} __val
  while :; do
    ask "$__prompt"
    # A failed read means stdin is gone (EOF); looping would spin forever.
    if [[ $__secret == --secret ]]; then read -rs __val || die "Input closed"; echo; else read -r __val || die "Input closed"; fi
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
  local default=${2:-y} hint reply
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
  local selected=0 total=${#items[@]} key seq i
  while :; do
    clear
    box "$title"
    for ((i = 0; i < total; i++)); do
      if (( i == selected )); then
        printf ' %s>%s %s\n' "$C_REVERSE" "$C_RESET" "${items[i]}"
      else
        printf '   %s\n' "${items[i]}"
      fi
    done
    box "↑↓ navigate – Enter select – Esc cancel"
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
