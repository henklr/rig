#!/usr/bin/env bash
# Stage 3: turns a booting Arch into the desktop. Runs as a normal user with
# sudo, both during the ISO install and directly on an installed Arch.
#
# Safe to run again: ~/rig/install.sh is also how you repair or update.
#
# Nothing here starts a service, it only enables them. That keeps it working
# inside a chroot and avoids pulling the network out from under a running
# install. Everything takes effect at the next boot.
set -Eeuo pipefail

RIG_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=lib/common.sh
source "$RIG_DIR/lib/common.sh"

export PATH="$HOME/.local/bin:$PATH"

# Root on an installed Arch with no user yet: make one and start over as it.
adopt_user() {
  step "Creating your user"
  ask RIG_USER "Your username" "" '^[a-z_][a-z0-9_-]*$'
  if ! id "$RIG_USER" &>/dev/null; then
    pacman -S --needed --noconfirm sudo
    useradd -m -G wheel,video -s /bin/bash "$RIG_USER"
    passwd "$RIG_USER"
  fi
  install -m 440 /dev/null /etc/sudoers.d/10-wheel
  echo '%wheel ALL=(ALL:ALL) ALL' >/etc/sudoers.d/10-wheel
  visudo -cq

  local home=/home/$RIG_USER
  [[ -e $home/rig ]] || cp -a "$RIG_DIR" "$home/rig"
  chown -R "$RIG_USER:$RIG_USER" "$home/rig"
  run_as_user "$RIG_USER" "$home" bash "$home/rig/install/setup.sh"
}

# Everything is symlinked out of ~/rig, so the code has to live there even when
# it came from a temporary download.
# Runs the newest ~/rig, also when this script already is ~/rig/install/setup.sh.
settle_in_home() {
  [[ -n ${RIG_SETTLED:-} ]] && return 0
  export RIG_SETTLED=1
  if [[ -d $HOME/rig/.git ]]; then
    git -C "$HOME/rig" pull --ff-only || warn "could not update ~/rig, using it as it is."
  elif [[ $RIG_DIR == "$HOME/rig" ]]; then
    return 0 # the first install: setup.sh attaches the git history later
  elif [[ -e $HOME/rig ]]; then
    die "$HOME/rig already exists and is not a git checkout. Move it away first."
  else
    cp -a "$RIG_DIR" "$HOME/rig"
  fi
  exec bash "$HOME/rig/install/setup.sh"
}

start_logging() {
  local dir=$HOME/.local/state/rig
  mkdir -p "$dir"
  LOG=$dir/install.log
  exec > >(tee -a "$LOG") 2>&1
  trap 'on_failure $LINENO' ERR
}

on_failure() {
  warn "stopped at line $1 of setup.sh."
  if command -v claude >/dev/null; then
    info "Claude is already installed, so let it take a look:"
    info "  claude \"The rig install failed, see $LOG\""
  fi
}

keep_sudo_alive() {
  # During a hand-over sudo needs no password, and a leftover background loop
  # would keep /mnt busy when the ISO tries to unmount it.
  [[ -n ${RIG_HANDOFF:-} ]] && return 0
  sudo -v
  while kill -0 "$$" 2>/dev/null; do
    sudo -n true
    sleep 60
  done &
}

# First on purpose: if anything after this breaks, the copilot is there to help.
install_claude() {
  step "Installing Claude Code"
  if command -v claude >/dev/null; then
    info "already here: $(claude --version)"
    return 0
  fi
  curl -fsSL https://claude.ai/install.sh | bash
  info "installed: $(claude --version)"
}

update_system() {
  step "Updating the system"
  sudo sed -i -e 's/^#Color/Color/' \
    -e 's/^#\?ParallelDownloads.*/ParallelDownloads = 8/' /etc/pacman.conf
  sudo pacman -Syu --needed --noconfirm git pciutils
}

attach_git_history() {
  [[ -d $RIG_DIR/.git ]] && return 0
  step "Connecting ~/rig to GitHub"
  local url="https://github.com/${RIG_REPO:-henklr/rig}.git"
  local branch=${RIG_BRANCH:-main}
  git -C "$RIG_DIR" init -q -b "$branch"
  git -C "$RIG_DIR" remote add origin "$url"
  if git -C "$RIG_DIR" fetch -q origin "$branch"; then
    git -C "$RIG_DIR" reset -q "origin/$branch"
    git -C "$RIG_DIR" branch -q --set-upstream-to="origin/$branch"
  else
    warn "could not reach $url. ~/rig works, it just has no history yet."
  fi
}

gpu_packages() {
  local gpus
  gpus=$(lspci -mm | grep -E '"(VGA|3D|Display)' || true)
  if grep -qi nvidia <<<"$gpus"; then
    printf '%s\n' nvidia-open-dkms nvidia-utils linux-headers libva-nvidia-driver
  fi
  if grep -qiE 'amd|ati technologies' <<<"$gpus"; then
    printf '%s\n' vulkan-radeon
  fi
  if grep -qi intel <<<"$gpus"; then
    printf '%s\n' vulkan-intel intel-media-driver
  fi
}

install_packages() {
  step "Installing the desktop"
  local -a packages
  mapfile -t packages < <(
    read_pkgs "$RIG_DIR"/packages/{copilot,cli,desktop,apps}.txt
    gpu_packages
  )
  sudo pacman -S --needed --noconfirm "${packages[@]}"
}

# Not worth stopping for: the AUR being down shouldn't cost you the desktop.
install_aur_helper() {
  command -v yay >/dev/null && return 0
  step "Installing yay for the AUR"
  local dir
  dir=$(mktemp -d)
  if ! git clone -q --depth 1 https://aur.archlinux.org/yay-bin.git "$dir" ||
    ! (cd "$dir" && makepkg -si --noconfirm --needed); then
    warn "could not install yay. The rest is fine; Claude can try again later."
  fi
  rm -rf "$dir"
}

# This can fail without stopping the install: Firefox is the fallback browser.
install_aur_packages() {
  command -v yay >/dev/null || return 0
  step "Installing from the AUR"
  local -a packages
  mapfile -t packages < <(read_pkgs "$RIG_DIR/packages/aur.txt")
  yay -S --needed --noconfirm "${packages[@]}" ||
    warn "could not install ${packages[*]}. Claude can try again later."
}

# link SOURCE_IN_REPO TARGET_IN_HOME: the config stays in ~/rig under git, so
# whatever you and Claude change is versioned. Anything in the way is kept.
link() {
  local source=$RIG_DIR/$1 target=$HOME/$2
  mkdir -p "$(dirname "$target")"
  if [[ -e $target && ! -L $target ]]; then
    mv "$target" "$target.rig-bak"
    info "kept the old $2 as $2.rig-bak"
  fi
  ln -sfn "$source" "$target"
}

link_dotfiles() {
  step "Linking the configuration"
  local path
  for path in "$RIG_DIR"/config/*; do
    path=$(basename "$path")
    link "config/$path" ".config/$path"
  done
  for path in "$RIG_DIR"/bin/*; do
    path=$(basename "$path")
    link "bin/$path" ".local/bin/$path"
  done
  link shell/bashrc .bashrc
  link shell/bash_profile .bash_profile
}

# Keyboard and GPU belong to this machine, not to the repo. Git ignores this.
write_machine_config() {
  local file=$RIG_DIR/config/hypr/machine.lua
  [[ -e $file ]] && return 0

  local keymap=${RIG_KEYMAP:-}
  if [[ -z $keymap && -r /etc/vconsole.conf ]]; then
    keymap=$(sed -n 's/^KEYMAP=//p' /etc/vconsole.conf)
  fi
  keymap=${keymap%%-*}

  {
    echo '-- This machine only: written by the installer, ignored by git.'
    printf 'hl.config({ input = { kb_layout = "%s" } })\n' "${keymap:-us}"
    if gpu_packages | grep -q nvidia; then
      echo 'hl.env("LIBVA_DRIVER_NAME", "nvidia")'
      echo 'hl.env("__GLX_VENDOR_LIBRARY_NAME", "nvidia")'
    fi
  } >"$file"
}

configure_claude() {
  step "Introducing Claude to the system"
  link claude/CLAUDE.md .claude/CLAUDE.md
  [[ -e $HOME/.claude/settings.json ]] && return 0
  # Copied, not linked: Claude Code writes to this file itself.
  cp "$RIG_DIR/claude/settings.json" "$HOME/.claude/settings.json"
  # Hyprland reads this flag once and opens Claude on the first login.
  touch "$HOME/.local/state/rig/first-boot"
}

# An AI with a shell deserves an undo button. snap-pac snapshots / around every
# pacman run, and the baseline taken here is the state right after install.
configure_snapshots() {
  [[ $(findmnt -no FSTYPE /) == btrfs ]] || return 0
  if [[ -e /.snapshots ]]; then
    info "/.snapshots already exists, leaving snapshots as they are."
    return 0
  fi
  step "Setting up snapshots"
  sudo pacman -S --needed --noconfirm snapper snap-pac
  sudo snapper --no-dbus -c root create-config /
  sudo snapper --no-dbus -c root set-config \
    TIMELINE_CREATE=no NUMBER_LIMIT=20 NUMBER_LIMIT_IMPORTANT=5 "ALLOW_USERS=$USER"
  sudo systemctl enable snapper-cleanup.timer
  sudo snapper --no-dbus -c root create -d "rig: fresh install"
}

# The disk password is typed once, on a screen that looks like the lock screen,
# and there's no menu before it and no login after it. Without encryption that
# would mean no password at all, so all of this needs an encrypted root disk.
configure_boot() {
  step "Setting up the boot"
  if sudo test -f /boot/loader/loader.conf; then
    sudo sed -i 's/^timeout .*/timeout 0/' /boot/loader/loader.conf
  fi

  [[ $(lsblk -dno TYPE "$(findmnt -no SOURCE --nofsroot /)") == crypt ]] || return 0
  sudo mkdir -p /etc/systemd/system/getty@tty1.service.d
  sudo tee /etc/systemd/system/getty@tty1.service.d/autologin.conf >/dev/null <<EOF
[Service]
ExecStart=
ExecStart=-/usr/bin/agetty --noreset --noclear --autologin $USER - \${TERM}
EOF
  install_boot_screen
}

install_boot_screen() {
  local hooks=/etc/mkinitcpio.conf.d/rig.conf entry=/boot/loader/entries/arch.conf
  local theme=/usr/share/plymouth/themes/rig
  if [[ ! -f $hooks ]] || ! sudo test -f "$entry"; then
    info "this Arch wasn't installed by rig, keeping its boot as it is."
    return 0
  fi
  sudo mkdir -p "$theme"
  sudo cp "$RIG_DIR"/plymouth/* "$theme/"
  sudo sed -i "s/@USER@/$USER/" "$theme/rig.script"
  sudo plymouth-set-default-theme rig
  sudo sed -i '/^HOOKS=/{/plymouth/!s/ systemd / systemd plymouth /}' "$hooks"
  sudo sed -i '/^options/{/ splash/!s/$/ splash/}' "$entry"
  sudo mkinitcpio -P
}

enable_services() {
  step "Enabling services"
  sudo systemctl enable bluetooth.service fstrim.timer systemd-timesyncd.service

  # Two network managers fight, so respect one that's already configured.
  local other
  for other in systemd-networkd dhcpcd netctl; do
    if systemctl is-enabled -q "$other" 2>/dev/null; then
      info "keeping $other for the network."
      return 0
    fi
  done
  sudo systemctl enable NetworkManager.service
}

finish() {
  step "Done"
  info "Claude Code: $(claude --version)"
  info "Hyprland:    $(pacman -Q hyprland | cut -d' ' -f2)"
  info "Log:         $LOG"
  [[ -n ${RIG_HANDOFF:-} ]] && return 0
  info "Reboot, log in if asked, and Hyprland starts with Claude on screen."
}

main() {
  if [[ $EUID -eq 0 ]]; then
    adopt_user
    return
  fi
  settle_in_home
  start_logging
  keep_sudo_alive
  install_claude
  update_system
  attach_git_history
  install_packages
  install_aur_helper
  install_aur_packages
  link_dotfiles
  write_machine_config
  configure_claude
  configure_snapshots
  configure_boot
  enable_services
  finish
}

main
