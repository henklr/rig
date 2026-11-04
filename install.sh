#!/usr/bin/env bash
# rig: one command from a clean Arch to Hyprland with Claude Code as copilot.
#
#   curl -fsSL https://github.com/henklr/rig/raw/main/install.sh | bash
#
# Run it from the Arch ISO to install Arch on a disk first, or from an already
# installed Arch system to set up the desktop on top of it.
#
# All the work happens inside main(), and every path ends in exec, so a
# truncated download can't run half a script.

set -Eeuo pipefail

RIG_REPO="${RIG_REPO:-henklr/rig}"
RIG_BRANCH="${RIG_BRANCH:-main}"
export RIG_REPO RIG_BRANCH

fail() {
  printf '\033[1;31merror:\033[0m %s\n' "$*" >&2
  exit 1
}

# Downloads a tarball instead of cloning because the Arch ISO has no git.
# setup.sh attaches the git history once git is installed.
fetch_source() {
  local dir url
  dir=$(mktemp -d /tmp/rig.XXXXXX)
  url="https://github.com/$RIG_REPO/archive/refs/heads/$RIG_BRANCH.tar.gz"
  curl -fsSL --retry 3 "$url" | tar -xz -C "$dir" --strip-components=1 ||
    fail "could not download $url. Is the network up?"
  printf '%s\n' "$dir"
}

main() {
  [[ -f /etc/arch-release ]] || fail "rig only runs on Arch Linux."
  [[ $(uname -m) == x86_64 ]] || fail "rig only supports x86_64."

  local here="" src
  if [[ -n ${BASH_SOURCE[0]:-} && -f ${BASH_SOURCE[0]} ]]; then
    here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  fi
  if [[ -n $here && -f $here/lib/common.sh ]]; then
    src=$here
  else
    src=$(fetch_source)
  fi

  # With curl | bash, stdin is the script itself. Point it at the keyboard so
  # the prompts work. No terminal at all (CI) is fine: settings come from env.
  if [[ ! -t 0 ]] && { : </dev/tty; } 2>/dev/null; then
    exec </dev/tty
  fi

  if [[ -d /run/archiso ]]; then
    exec bash "$src/install/iso.sh"
  fi
  exec bash "$src/install/setup.sh"
}

main "$@"
