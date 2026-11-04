#!/usr/bin/env bash
# Stage 1, as root on the Arch ISO: wipe a disk and install Arch on it.
#
# Layout: 1 GiB EFI partition, the rest LUKS2 (optional) with btrfs subvolumes
# @ (/), @home, @log and @pkg, so a snapshot of / leaves your files alone.
#
# Unattended: set RIG_DISK, RIG_USER, RIG_PASSWORD, RIG_HOSTNAME, RIG_ENCRYPT,
# RIG_KEYMAP, RIG_TIMEZONE, RIG_LOCALE and RIG_YES=1.
set -Eeuo pipefail

RIG_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=lib/common.sh
source "$RIG_DIR/lib/common.sh"

LOG=/tmp/rig-install.log
exec > >(tee -a "$LOG") 2>&1
trap 'die "stopped at line $LINENO of iso.sh. Full log: $LOG"' ERR

ROOT_MAPPER=cryptroot
MOUNT_OPTS=noatime,compress=zstd:1
MIN_DISK_BYTES=$((20 * 1024 * 1024 * 1024))

preflight() {
  step "Checking the machine"
  [[ $EUID -eq 0 ]] || die "run this as root on the Arch ISO."
  [[ -d /sys/firmware/efi/efivars ]] ||
    die "booted in legacy BIOS mode. Reboot the ISO in UEFI mode."
  curl -fsS --max-time 20 -o /dev/null https://archlinux.org ||
    die "no network. For Wi-Fi run: iwctl station wlan0 connect \"<network>\""
  timedatectl set-ntp true

  # pacman-init fills the ISO's keyring a few seconds after boot.
  local i
  for i in {1..60}; do
    [[ $(systemctl show -p SubState --value pacman-init.service) == exited ]] && break
    sleep 1
  done
  # An ISO older than the newest packager keys fails pacstrap on signatures.
  pacman -Sy --noconfirm archlinux-keyring >/dev/null ||
    warn "could not refresh the keyring, continuing with the ISO's."
}

# Every internal disk, minus the USB stick the ISO itself runs from.
list_disks() {
  local iso_disk="" src
  src=$(findmnt -no SOURCE /run/archiso/bootmnt 2>/dev/null || true)
  [[ -n $src ]] && iso_disk=$(lsblk -no PKNAME "$src" 2>/dev/null | head -1)
  lsblk -dnpbo NAME,SIZE,TYPE,RO |
    awk -v skip="/dev/$iso_disk" -v min="$MIN_DISK_BYTES" \
      '$3 == "disk" && $4 == 0 && $2 >= min && $1 != skip { print $1 }'
}

choose_disk() {
  if [[ -n ${RIG_DISK:-} ]]; then
    [[ -b $RIG_DISK ]] || die "RIG_DISK=$RIG_DISK is not a block device."
    return 0
  fi
  local -a disks
  mapfile -t disks < <(list_disks)
  ((${#disks[@]})) || die "found no internal disk of at least 20 GiB."

  local i
  echo
  for i in "${!disks[@]}"; do
    printf '  %d) %s\n' "$((i + 1))" \
      "$(lsblk -dno NAME,SIZE,MODEL "${disks[$i]}" | tr -s ' ')"
  done
  local choice=""
  ask choice "Which disk should Arch go on? (number)" "" '^[0-9]+$'
  ((choice >= 1 && choice <= ${#disks[@]})) || die "no disk number $choice."
  RIG_DISK=${disks[$((choice - 1))]}
}

confirm_wipe() {
  [[ ${RIG_YES:-} == 1 ]] && return 0
  echo
  warn "this erases EVERYTHING on $RIG_DISK:"
  lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT "$RIG_DISK" || true
  local typed
  read -rp "Type the disk's name (${RIG_DISK##*/}) to erase it: " typed
  [[ $typed == "${RIG_DISK##*/}" ]] || die "not erased. Nothing was changed."
}

gather_settings() {
  step "A few questions, then it runs by itself"
  ask RIG_KEYMAP "Keyboard layout" dk '^[a-zA-Z0-9_-]+$'
  loadkeys "$RIG_KEYMAP" 2>/dev/null || true
  ask RIG_HOSTNAME "Computer name" rig '^[a-z0-9][a-z0-9-]*$'
  ask RIG_USER "Your username" "" '^[a-z_][a-z0-9_-]*$'
  ask_secret RIG_PASSWORD "Password (login, sudo and disk encryption)"
  ask RIG_ENCRYPT "Encrypt the disk? (yes/no)" yes '^(yes|no)$'
  ask RIG_TIMEZONE "Time zone" Europe/Copenhagen '^[A-Za-z0-9_+/-]+$'
  [[ -e /usr/share/zoneinfo/$RIG_TIMEZONE ]] || die "unknown time zone $RIG_TIMEZONE."
  ask RIG_LOCALE "Locale" en_DK.UTF-8 '^[a-zA-Z_]+\.UTF-8$'
  choose_disk
  confirm_wipe
}

partition_names() {
  # /dev/nvme0n1 -> /dev/nvme0n1p1, /dev/sda -> /dev/sda1
  local sep=""
  [[ $RIG_DISK =~ [0-9]$ ]] && sep=p
  EFI_PART="${RIG_DISK}${sep}1"
  ROOT_PART="${RIG_DISK}${sep}2"
}

prepare_disk() {
  step "Erasing and partitioning $RIG_DISK"
  # A previous, failed run may still hold these.
  umount -R /mnt 2>/dev/null || true
  cryptsetup close "$ROOT_MAPPER" 2>/dev/null || true

  wipefs --all --force "$RIG_DISK" >/dev/null
  sgdisk --zap-all "$RIG_DISK" >/dev/null
  sgdisk -n 1:0:+1G -t 1:ef00 -c 1:EFI \
    -n 2:0:0 -t 2:8304 -c 2:root "$RIG_DISK" >/dev/null
  partprobe "$RIG_DISK"
  udevadm settle
  partition_names

  local root_dev=$ROOT_PART
  if [[ $RIG_ENCRYPT == yes ]]; then
    step "Encrypting the root partition"
    printf '%s' "$RIG_PASSWORD" |
      cryptsetup luksFormat --batch-mode --type luks2 --key-file=- "$ROOT_PART"
    printf '%s' "$RIG_PASSWORD" |
      cryptsetup open --key-file=- "$ROOT_PART" "$ROOT_MAPPER"
    root_dev=/dev/mapper/$ROOT_MAPPER
  fi

  step "Creating file systems"
  mkfs.fat -F 32 -n EFI "$EFI_PART" >/dev/null
  mkfs.btrfs -f -L rig "$root_dev" >/dev/null

  mount "$root_dev" /mnt
  local subvolume
  for subvolume in @ @home @log @pkg; do
    btrfs -q subvolume create "/mnt/$subvolume"
  done
  umount /mnt

  mount -o "$MOUNT_OPTS,subvol=@" "$root_dev" /mnt
  mount --mkdir -o "$MOUNT_OPTS,subvol=@home" "$root_dev" /mnt/home
  mount --mkdir -o "$MOUNT_OPTS,subvol=@log" "$root_dev" /mnt/var/log
  mount --mkdir -o "$MOUNT_OPTS,subvol=@pkg" "$root_dev" /mnt/var/cache/pacman/pkg
  mount --mkdir -o fmask=0077,dmask=0077 "$EFI_PART" /mnt/boot
}

install_base() {
  step "Installing the Arch base system"
  local -a packages
  mapfile -t packages < <(read_pkgs "$RIG_DIR/packages/base.txt")
  case $(awk -F': ' '/^vendor_id/ {print $2; exit}' /proc/cpuinfo) in
  GenuineIntel) packages+=(intel-ucode) ;;
  AuthenticAMD) packages+=(amd-ucode) ;;
  esac
  sed -i 's/^#\?ParallelDownloads.*/ParallelDownloads = 8/' /etc/pacman.conf
  pacstrap -K /mnt "${packages[@]}"

  # subvolid breaks a later rollback; subvol= alone is enough.
  genfstab -U /mnt | sed -E 's/subvolid=[0-9]+,?//; s/,+([[:space:]])/\1/' >>/mnt/etc/fstab
}

# The ISO's Wi-Fi lives in iwd, the installed system uses NetworkManager.
# Without this you'd reboot to no network, and Claude can't log in offline.
carry_over_wifi() {
  local file name ssid psk dest
  shopt -s nullglob
  for file in /var/lib/iwd/*.psk; do
    name=$(basename "$file" .psk)
    ssid=$name
    # iwd hex-encodes names with special characters as =<hex>.
    if [[ $name == =* ]]; then
      # shellcheck disable=SC2001
      ssid=$(printf '%b' "$(sed 's/../\\x&/g' <<<"${name#=}")")
    fi
    psk=$(sed -n 's/^Passphrase=//p' "$file")
    [[ -n $psk ]] || psk=$(sed -n 's/^PreSharedKey=//p' "$file")
    [[ -n $psk ]] || continue

    dest="/mnt/etc/NetworkManager/system-connections/$(tr -c 'A-Za-z0-9._-' _ <<<"$ssid").nmconnection"
    install -D -m 600 /dev/null "$dest"
    cat >"$dest" <<EOF
[connection]
id=$ssid
type=wifi

[wifi]
ssid=$ssid

[wifi-security]
key-mgmt=wpa-psk
psk=$psk

[ipv4]
method=auto

[ipv6]
method=auto
EOF
    info "kept Wi-Fi network $ssid"
  done
  shopt -u nullglob
}

configure_system() {
  step "Configuring the new system"
  cp -a "$RIG_DIR" /mnt/opt/rig-src

  local root_args
  if [[ $RIG_ENCRYPT == yes ]]; then
    root_args="rd.luks.name=$(blkid -s UUID -o value "$ROOT_PART")=$ROOT_MAPPER root=/dev/mapper/$ROOT_MAPPER"
  else
    root_args="root=UUID=$(blkid -s UUID -o value "$ROOT_PART")"
  fi

  local -a to_chroot=(
    RIG_USER="$RIG_USER" RIG_HOSTNAME="$RIG_HOSTNAME" RIG_KEYMAP="$RIG_KEYMAP"
    RIG_TIMEZONE="$RIG_TIMEZONE" RIG_LOCALE="$RIG_LOCALE" RIG_ENCRYPT="$RIG_ENCRYPT"
    RIG_REPO="${RIG_REPO:-henklr/rig}" RIG_BRANCH="${RIG_BRANCH:-main}"
    RIG_ROOT_ARGS="$root_args" RIG_KERNEL_ARGS="${RIG_KERNEL_ARGS:-}"
  )
  arch-chroot /mnt /usr/bin/env "${to_chroot[@]}" \
    bash /opt/rig-src/install/chroot.sh system

  # Piped in here, not passed along, so it never shows up in a process list.
  printf '%s:%s\n' "$RIG_USER" "$RIG_PASSWORD" | arch-chroot /mnt chpasswd

  # The system boots from here on. A failure below leaves a working console
  # with Claude on it, which is a better place to fix things than this ISO.
  DESKTOP_OK=yes
  arch-chroot /mnt /usr/bin/env "${to_chroot[@]}" \
    bash /opt/rig-src/install/chroot.sh desktop || DESKTOP_OK=no
  rm -rf /mnt/opt/rig-src
}

finish() {
  cp "$LOG" /mnt/var/log/rig-install.log || true

  step "Done"
  if [[ $DESKTOP_OK == yes ]]; then
    info "Log in after the reboot and Hyprland starts with Claude on screen."
  else
    warn "the desktop setup failed, but the system boots."
    info "Log in after the reboot and run ~/rig/install.sh, or just: claude"
    info "Log: /var/log/rig-install.log"
  fi

  [[ ${RIG_NO_REBOOT:-} == 1 ]] && return 0
  read -rp "Remove the USB stick and press Enter to reboot. " _ || true
  umount -R /mnt
  [[ $RIG_ENCRYPT == yes ]] && cryptsetup close "$ROOT_MAPPER"
  reboot
}

main() {
  preflight
  gather_settings
  prepare_disk
  install_base
  carry_over_wifi
  configure_system
  finish
}

main
