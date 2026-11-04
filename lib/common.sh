# shellcheck shell=bash
# Helpers shared by the install stages. Sourced, never run on its own.

step() { printf '\n\033[1;38;5;173m==>\033[0m \033[1m%s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die() {
  printf '\033[1;31merror:\033[0m %s\n' "$*" >&2
  exit 1
}

# ask VAR "Question" [default] [regex]
# A VAR already set in the environment wins, which is how unattended runs work.
ask() {
  local var=$1 prompt=$2 default=${3:-} regex=${4:-.} reply
  if [[ -n ${!var:-} ]]; then
    [[ ${!var} =~ $regex ]] || die "$var='${!var}' is not valid."
    return 0
  fi
  [[ -n $default ]] && prompt+=" [$default]"
  while :; do
    read -rp "$prompt: " reply || die "no terminal to ask on; set $var instead."
    reply=${reply:-$default}
    [[ -n $reply && $reply =~ $regex ]] && break
    warn "that doesn't look right, try again."
  done
  printf -v "$var" '%s' "$reply"
}

# ask_secret VAR "Question": reads twice, never echoes, never logs.
ask_secret() {
  local var=$1 prompt=$2 first second
  [[ -n ${!var:-} ]] && return 0
  while :; do
    read -rsp "$prompt: " first || die "no terminal to ask on; set $var instead."
    echo
    read -rsp "Again: " second || die "no terminal to ask on; set $var instead."
    echo
    [[ -n $first && $first == "$second" ]] && break
    warn "empty or not the same, try again."
  done
  printf -v "$var" '%s' "$first"
}

# Package lists are one name per line, # starts a comment.
read_pkgs() {
  local file
  for file in "$@"; do
    sed -e 's/#.*//' -e 's/[[:space:]]*$//' -e '/^$/d' "$file"
  done
}

# run_as_user USER DIR COMMAND...: root hands over to a normal user, because
# makepkg and Claude Code's installer refuse to run as root. The sudo rule only
# exists for the duration of the hand-over.
run_as_user() {
  local user=$1 dir=$2 rc=0 rule=/etc/sudoers.d/99-rig-install
  shift 2
  install -m 440 /dev/null "$rule"
  printf '%s ALL=(ALL:ALL) NOPASSWD: ALL\n' "$user" >"$rule"
  (
    cd "$dir"
    runuser -u "$user" -- env \
      HOME="/home/$user" USER="$user" LOGNAME="$user" \
      RIG_REPO="${RIG_REPO:-henklr/rig}" RIG_BRANCH="${RIG_BRANCH:-main}" \
      RIG_KEYMAP="${RIG_KEYMAP:-}" RIG_HANDOFF=1 \
      "$@"
  ) || rc=$?
  rm -f "$rule"
  return "$rc"
}
