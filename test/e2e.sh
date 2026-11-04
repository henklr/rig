#!/usr/bin/env bash
# The whole journey in a real VM: boot the official Arch ISO, run the one-line
# installer, reboot, unlock the disk, log in, and look at what's on screen.
#
# This is the only test that can prove the machine boots, which is the thing
# you can't find out cheaply on real hardware. Needs KVM, so it runs in GitHub
# Actions (.github/workflows/e2e.yml). Results land in e2e/.
set -Eeuo pipefail

REPO=${REPO:-henklr/rig}
BRANCH=${BRANCH:-main}
WORK=${WORK:-$PWD/e2e}
ISO_URL=https://geo.mirror.pkgbuild.com/iso/latest/archlinux-x86_64.iso
OVMF_CODE=/usr/share/OVMF/OVMF_CODE_4M.fd
OVMF_VARS=/usr/share/OVMF/OVMF_VARS_4M.fd
SSH_PORT=2222
USERNAME=tester
PASSWORD=rigtestpassword # letters only: it gets typed on a virtual keyboard
VM_PID=

mkdir -p "$WORK"
cd "$WORK"

say() { printf '\n\033[1;36m[e2e]\033[0m %s\n' "$*"; }
fail() {
  printf '\033[1;31m[e2e] FAILED:\033[0m %s\n' "$*" >&2
  exit 1
}
cleanup() { [[ -n $VM_PID ]] && kill "$VM_PID" 2>/dev/null || true; }
trap cleanup EXIT

remote() {
  ssh -i key -p "$SSH_PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=5 -o LogLevel=ERROR "$@"
}

wait_for_ssh() {
  local i
  for i in {1..60}; do
    remote "$1@localhost" true 2>/dev/null && return 0
    sleep 5
  done
  fail "no SSH as $1 after 10 minutes. See serial-*.log and the screenshots."
}

monitor() { printf '%s\n' "$*" | socat -t 0.3 - UNIX-CONNECT:monitor.sock >>monitor.log 2>&1; }
screenshot() {
  monitor "screendump $WORK/$1.png -f png"
  sleep 2
}

# Types on the VM's keyboard, as a person at the machine would.
type_keys() {
  local i
  for ((i = 0; i < ${#1}; i++)); do
    monitor "sendkey ${1:i:1}"
    sleep 0.2
  done
  monitor "sendkey ret"
}

start_vm() {
  local name=$1
  shift
  rm -f serial.sock monitor.sock
  qemu-system-x86_64 -enable-kvm -cpu host -smp 4 -m 6144 \
    -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
    -drive if=pflash,format=raw,file=vars.fd \
    -drive file=disk.qcow2,if=virtio,format=qcow2 \
    -nic "user,model=virtio-net-pci,hostfwd=tcp::$SSH_PORT-:22" \
    -device virtio-vga -display none \
    -chardev "socket,id=serial,path=serial.sock,server=on,wait=off,logfile=serial-$name.log" \
    -serial chardev:serial \
    -monitor unix:monitor.sock,server=on,wait=off \
    "$@" &
  VM_PID=$!
}

stop_vm() {
  remote "$1@localhost" "${2:-}systemctl poweroff" 2>/dev/null || true
  local i
  for i in {1..60}; do
    kill -0 "$VM_PID" 2>/dev/null || break
    sleep 1
  done
  kill "$VM_PID" 2>/dev/null || true
  wait "$VM_PID" 2>/dev/null || true
  VM_PID=
}

prepare() {
  say "Preparing the VM"
  [[ -f arch.iso ]] || curl -fsSL -o arch.iso "$ISO_URL"
  ssh-keygen -q -t ed25519 -N '' -f key
  qemu-img create -q -f qcow2 disk.qcow2 40G
  cp "$OVMF_VARS" vars.fd

  # The ISO runs cloud-init, which is the supported way to get a key onto it.
  cat >user-data <<EOF
#cloud-config
bootcmd:
  - mkdir -p /root/.ssh
  - echo "$(cat key.pub)" >> /root/.ssh/authorized_keys
  - chmod 700 /root/.ssh
  - chmod 600 /root/.ssh/authorized_keys
EOF
  echo 'instance-id: rig-e2e' >meta-data
  genisoimage -quiet -output seed.iso -volid cidata -joliet -rock user-data meta-data
}

install_from_iso() {
  say "Booting the Arch ISO"
  start_vm iso -cdrom arch.iso \
    -drive file=seed.iso,if=virtio,format=raw,readonly=on
  wait_for_ssh root
  screenshot 1-iso

  say "Running the one-line installer"
  remote root@localhost "env RIG_DISK=/dev/vda RIG_USER=$USERNAME RIG_PASSWORD=$PASSWORD \
    RIG_HOSTNAME=e2e RIG_ENCRYPT=yes RIG_KEYMAP=dk RIG_TIMEZONE=Europe/Copenhagen \
    RIG_LOCALE=en_DK.UTF-8 RIG_YES=1 RIG_NO_REBOOT=1 RIG_KERNEL_ARGS=console=ttyS0 \
    RIG_REPO=$REPO RIG_BRANCH=$BRANCH \
    bash -c 'curl -fsSL https://github.com/$REPO/raw/$BRANCH/install.sh | bash'" | tee install.log

  grep -q 'desktop setup failed' install.log && fail "the desktop stage failed."
  grep -q 'Hyprland starts with Claude' install.log || fail "the installer did not finish."

  say "Opening SSH on the installed system so it can be inspected"
  remote root@localhost bash -s <<EOF
set -e
arch-chroot /mnt systemctl enable sshd
install -d -m 700 -o 1000 -g 1000 /mnt/home/$USERNAME/.ssh
install -m 600 -o 1000 -g 1000 /root/.ssh/authorized_keys /mnt/home/$USERNAME/.ssh/authorized_keys
umount -R /mnt
cryptsetup close cryptroot
EOF
  stop_vm root
}

unlock_disk() {
  say "Rebooting without the ISO and unlocking the disk"
  start_vm installed
  local i
  for i in {1..120}; do
    grep -qi passphrase serial-installed.log 2>/dev/null && break
    sleep 2
  done
  grep -qi passphrase serial-installed.log || {
    screenshot 2-no-passphrase-prompt
    fail "never asked for the disk passphrase."
  }
  screenshot 2-passphrase
  sleep 2
  # One key at a time: QEMU drops whatever it hasn't read when the socket closes.
  {
    for ((i = 0; i < ${#PASSWORD}; i++)); do
      printf '%s' "${PASSWORD:i:1}"
      sleep 0.1
    done
    printf '\n'
    sleep 2
  } | socat -u - UNIX-CONNECT:serial.sock
  wait_for_ssh "$USERNAME"

  grep -q 'Linux Boot Manager' serial-installed.log ||
    fail "the firmware has no boot entry of its own, only the fallback path."
}

check_system() {
  say "Checking the installed system"
  remote "$USERNAME@localhost" "PASSWORD=$PASSWORD bash -ls" <<'EOF' | tee checks.txt
ok()  { printf 'PASS  %s\n' "$1"; }
bad() { printf 'FAIL  %s\n' "$1"; }
check() { local name=$1; shift; if "$@" >/dev/null 2>&1; then ok "$name"; else bad "$name"; fi; }

echo "--- system"
findmnt -no SOURCE,FSTYPE,OPTIONS / | cut -c1-90
systemctl --failed --no-legend --plain
systemctl is-system-running

echo "--- checks"
check "root is encrypted btrfs" sh -c 'findmnt -no SOURCE / | grep -q /dev/mapper/cryptroot && findmnt -no FSTYPE / | grep -q btrfs'
check "root is the @ subvolume" sh -c 'findmnt -no OPTIONS / | grep -q subvol=/@'
check "home is a separate subvolume" sh -c 'findmnt -no OPTIONS /home | grep -q subvol=/@home'
check "zram swap is on" sh -c 'swapon --show | grep -q zram'
check "network is up" curl -fsS --max-time 15 -o /dev/null https://archlinux.org
check "NetworkManager is running" systemctl is-active NetworkManager
check "bluetooth is enabled" systemctl is-enabled bluetooth
check "keyboard is Danish" grep -q KEYMAP=dk /etc/vconsole.conf
check "locale is set" sh -c 'locale | grep -q en_DK.UTF-8'
check "installer left no sudo rule" sh -c '! ls /etc/sudoers.d/ 2>/dev/null | grep -q rig-install; test ! -e /etc/sudoers.d/99-rig-install'
check "sudo needs a password" sh -c '! sudo -n true'
check "claude runs" claude --version
check "yay runs" yay --version
check "git history is attached" git -C "$HOME/rig" log -1
check "repo is clean" sh -c 'test -z "$(git -C "$HOME/rig" status --porcelain)"'
check "config is linked from the repo" sh -c 'test "$(readlink -f ~/.config/hypr)" = "$HOME/rig/config/hypr"'
check "Hyprland accepts the config" sh -c 'Hyprland --verify-config 2>&1 | grep -q "config ok"'
check "snapper has a baseline" sh -c 'snapper list | grep -q "fresh install"'
check "pipewire is available" systemctl --user is-enabled pipewire.socket

# What the README promises about pacman and snapshots.
before=$(snapper list | wc -l)
printf '%s\n' "$PASSWORD" | sudo -S pacman -S --noconfirm --needed tree >/dev/null 2>&1
after=$(snapper list | wc -l)
snapper list | tail -4
if ((after >= before + 2)); then ok "pacman made a pre and post snapshot"; else bad "pacman made a pre and post snapshot"; fi

# rig-askpass names the command by reading its parent, so that parent must be sudo.
cat >/tmp/fake-askpass <<FAKE
#!/bin/sh
ps -o args= -p "\$PPID" >/tmp/askpass-parent
echo "$PASSWORD"
FAKE
chmod +x /tmp/fake-askpass
sudo -k
SUDO_ASKPASS=/tmp/fake-askpass sudo -A true
check "askpass can see the sudo command" grep -q '^sudo -A true$' /tmp/askpass-parent
EOF
  grep -q '^FAIL' checks.txt && fail "some checks failed, see above."
  return 0
}

check_desktop() {
  say "Logging in at the keyboard"
  screenshot 3-login
  type_keys "$USERNAME"
  sleep 3
  type_keys "$PASSWORD"
  sleep 60
  screenshot 4-after-login

  if remote "$USERNAME@localhost" 'pgrep -x Hyprland >/dev/null'; then
    say "Hyprland started on the console"
  else
    # A VM without a 3D GPU often can't drive the real display. Fall back to a
    # headless output, which runs all the same config and autostart code.
    say "No Hyprland on the VM's console, starting it headless"
    remote "$USERNAME@localhost" 'cat ~/.local/share/hyprland/*.log 2>/dev/null | tail -30' || true
    remote "$USERNAME@localhost" bash -ls <<'EOF' || true
touch ~/.local/state/rig/first-boot
export XDG_RUNTIME_DIR=/run/user/$(id -u) HYPRLAND_HEADLESS_ONLY=1
nohup start-hyprland >/tmp/hyprland.log 2>&1 &
EOF
    sleep 45
  fi

  say "Inspecting the running desktop"
  remote "$USERNAME@localhost" bash -ls <<'EOF' | tee desktop.txt
export XDG_RUNTIME_DIR=/run/user/$(id -u)
echo "--- config errors"; hyprctl configerrors
echo "--- monitors"; hyprctl monitors | head -3
echo "--- windows"; hyprctl clients | grep -E 'class|title|workspace'
echo "--- processes"; pgrep -a 'waybar|mako|hypridle' | cut -c1-60
echo "--- screenshot"; grim /tmp/desktop.png && echo saved
EOF
  scp -i key -P "$SSH_PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o LogLevel=ERROR "$USERNAME@localhost:/tmp/desktop.png" 5-desktop.png || true
  screenshot 6-end

  grep -q 'class: rig.copilot' desktop.txt ||
    fail "Claude's window did not open on first login."
}

prepare
install_from_iso
unlock_disk
check_system
check_desktop
say "Everything passed"
