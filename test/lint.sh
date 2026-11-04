#!/usr/bin/env bash
# Fast checks that need no disk or GPU. Runs as root in a throwaway Arch
# container, because it installs what it validates with:
#
#   docker run --rm --platform linux/amd64 -v "$PWD":/rig archlinux bash /rig/test/lint.sh
#
# Every config is checked by the program that reads it, so a Hyprland update
# that changes the config language fails here instead of at login.
set -Eeuo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
source lib/common.sh

pacman_options=(--noconfirm --needed)
sed -i 's/^#\?ParallelDownloads.*/ParallelDownloads = 8/' /etc/pacman.conf
pacman -Sy --noconfirm >/dev/null

step "Package names"
mapfile -t packages < <(read_pkgs packages/*.txt)
packages+=(snapper snap-pac nvidia-open-dkms nvidia-utils libva-nvidia-driver
  linux-headers vulkan-radeon vulkan-intel intel-media-driver amd-ucode intel-ucode)
# --print resolves every name and dependency without installing anything.
pacman -Sp --print-format '%n' "${packages[@]}" >/dev/null
info "${#packages[@]} packages resolve"

step "shellcheck"
pacman -S "${pacman_options[@]}" shellcheck >/dev/null
shellcheck -x -P SCRIPTDIR/.. install.sh install/*.sh test/*.sh bin/*
info "clean"

step "Claude settings"
pacman -S "${pacman_options[@]}" jq >/dev/null
jq empty claude/settings.json
info "valid JSON"

step "Desktop configs, checked by the programs that read them"
pacman -S "${pacman_options[@]}" hyprland ghostty fuzzel waybar >/dev/null

# Hyprland refuses to run as root, and the checks need a home with these
# configs in place, as the installer would leave it.
useradd -m rigtest 2>/dev/null || true
home=/home/rigtest
mkdir -p "$home/.config"
cp -r config/* "$home/.config/"
echo 'hl.config({ input = { kb_layout = "dk" } })' >"$home/.config/hypr/machine.lua"
chown -R rigtest "$home"

as_user() {
  runuser -u rigtest -- env HOME="$home" XDG_RUNTIME_DIR=/tmp "$@"
}

output=$(as_user Hyprland --verify-config 2>&1 || true)
printf '%s\n' "$output" | tail -5
# Hyprland reports errors in its output, and its exit code alone isn't enough.
grep -qi 'config ok' <<<"$output" || die "Hyprland rejected the config."
grep -qiE 'error|failed' <<<"$output" && die "Hyprland reported a problem."

as_user ghostty +validate-config || die "Ghostty rejected its config."
info "ghostty ok"

as_user fuzzel --check-config || die "fuzzel rejected its config."
info "fuzzel ok"

step "All good"
