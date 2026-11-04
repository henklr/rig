#!/usr/bin/env bash
# Stage 2, as root inside the new system. iso.sh calls this twice:
#   chroot.sh system   locale, user, initramfs, bootloader: makes it bootable
#   chroot.sh desktop  hands over to setup.sh as the new user
set -Eeuo pipefail

RIG_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=lib/common.sh
source "$RIG_DIR/lib/common.sh"

configure_locale() {
  sed -i -e 's/^#\(en_US\.UTF-8 UTF-8\)/\1/' \
    -e "s/^#\(${RIG_LOCALE//./\\.} UTF-8\)/\1/" /etc/locale.gen
  locale-gen >/dev/null
  echo "LANG=$RIG_LOCALE" >/etc/locale.conf
  echo "KEYMAP=$RIG_KEYMAP" >/etc/vconsole.conf
  ln -sf "/usr/share/zoneinfo/$RIG_TIMEZONE" /etc/localtime
  hwclock --systohc || warn "could not set the hardware clock."
}

configure_host() {
  echo "$RIG_HOSTNAME" >/etc/hostname
  cat >/etc/hosts <<EOF
127.0.0.1 localhost
::1       localhost
127.0.1.1 $RIG_HOSTNAME
EOF
  cat >/etc/systemd/zram-generator.conf <<'EOF'
[zram0]
zram-size = min(ram / 2, 8192)
compression-algorithm = zstd
EOF
}

create_user() {
  id "$RIG_USER" &>/dev/null || useradd -m -G wheel,video -s /bin/bash "$RIG_USER"
  install -m 440 /dev/null /etc/sudoers.d/10-wheel
  echo '%wheel ALL=(ALL:ALL) ALL' >/etc/sudoers.d/10-wheel
  visudo -cq
}

build_initramfs() {
  local hooks="base systemd autodetect microcode modconf kms keyboard sd-vconsole block"
  [[ $RIG_ENCRYPT == yes ]] && hooks+=" sd-encrypt"
  hooks+=" filesystems fsck"
  mkdir -p /etc/mkinitcpio.conf.d
  echo "HOOKS=($hooks)" >/etc/mkinitcpio.conf.d/rig.conf
  mkinitcpio -P
}

install_bootloader() {
  bootctl install --esp-path=/boot
  cat >/boot/loader/loader.conf <<'EOF'
default arch.conf
timeout 3
editor no
EOF
  cat >/boot/loader/entries/arch.conf <<EOF
title   Arch Linux
linux   /vmlinuz-linux
initrd  /initramfs-linux.img
options $RIG_ROOT_ARGS rootflags=subvol=@ rw quiet loglevel=3 $RIG_KERNEL_ARGS
EOF
  systemctl enable systemd-boot-update.service
}

phase_system() {
  step "Setting up locale, host and user"
  configure_locale
  configure_host
  create_user

  step "Building the initramfs and installing the bootloader"
  build_initramfs
  install_bootloader

  # Enabled here too, so the network works even if the desktop stage fails.
  systemctl enable NetworkManager.service systemd-timesyncd.service
}

phase_desktop() {
  local home=/home/$RIG_USER
  [[ -e $home/rig ]] || cp -a /opt/rig-src "$home/rig"
  chown -R "$RIG_USER:$RIG_USER" "$home/rig"
  run_as_user "$RIG_USER" "$home" bash "$home/rig/install/setup.sh"
}

case ${1:-} in
system) phase_system ;;
desktop) phase_desktop ;;
*) die "usage: chroot.sh system|desktop" ;;
esac
