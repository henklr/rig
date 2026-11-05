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
PASSWORD=rig-test-password # the dashes are on purpose, see type_keys
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

# Types on the VM's keyboard, as a person at the machine would. QEMU names keys by
# their place on a US keyboard, and slash is where a Danish keyboard has its dash,
# so the password only works if the Danish layout reached the boot screen.
type_keys() {
  local i key
  for ((i = 0; i < ${#1}; i++)); do
    key=${1:i:1}
    [[ $key == - ]] && key=slash
    monitor "sendkey $key"
    sleep 0.2
  done
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
    -device virtio-vga -display none -parallel none \
    -device qemu-xhci -device usb-mouse \
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
    RIG_LOCALE=en_DK.UTF-8 RIG_YES=1 RIG_NO_REBOOT=1 RIG_KERNEL_ARGS='console=ttyS0 plymouth.ignore-serial-consoles' \
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
  # The prompt is only on the screen now, so the serial port can't announce it.
  sleep 45
  screenshot 2-boot-screen
  # Ctrl + Backspace has to clear this, or the password after it is wrong.
  type_keys wrong
  sleep 1
  screenshot 2-boot-screen-typed
  monitor "sendkey ctrl-backspace"
  sleep 1
  screenshot 2-boot-screen-cleared
  type_keys "$PASSWORD"
  monitor "sendkey ret"
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
check "git pull and push have an upstream" git -C "$HOME/rig" rev-parse --verify '@{upstream}'
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

check "boot menu is hidden" sh -c 'printf "%s\n" "$PASSWORD" | sudo -S grep -q "^timeout 0" /boot/loader/loader.conf'
check "boot screen is in the initramfs" sh -c 'printf "%s\n" "$PASSWORD" | sudo -S lsinitcpio /boot/initramfs-linux.img | grep -q themes/rig/rig.script'
check "boot screen is switched on" grep -q splash /proc/cmdline
EOF
  grep -q '^FAIL' checks.txt && fail "some checks failed, see above."
  return 0
}

check_desktop() {
  say "Waiting for the desktop, without touching the keyboard"
  sleep 30
  screenshot 3-desktop
  remote "$USERNAME@localhost" 'loginctl list-sessions --no-legend | grep -q tty1' ||
    fail "tty1 did not log in by itself after the disk passphrase."

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
  desktop_state | tee desktop.txt
  grep -q 'class: rig.copilot' desktop.txt ||
    fail "Claude's window did not open on first login."
  grep -q 'special: special:copilot' desktop.txt ||
    fail "Claude's window is not showing on first login."
  grep -q 'flag: gone' desktop.txt ||
    fail "the first-login flag is still there, so Claude would open at every login."

  say "Pressing Super + A to hide Claude"
  monitor "sendkey meta_l-a"
  sleep 3
  desktop_state | tee after-hide.txt
  grep -q 'special: *$' after-hide.txt || fail "Super + A did not hide Claude."
  screenshot 5-claude-hidden

  say "Pressing Super + Return for a terminal"
  monitor "sendkey meta_l-ret"
  sleep 10
  desktop_state | tee after-terminal.txt
  [[ $(grep -c 'class:' after-terminal.txt) -ge 2 ]] || fail "Super + Return opened no terminal."
  screenshot 6-terminal

  say "Pressing Super + A to bring Claude back"
  monitor "sendkey meta_l-a"
  sleep 3
  desktop_state | tee after-show.txt
  grep -q 'special: special:copilot' after-show.txt || fail "Super + A did not bring Claude back."
  screenshot 7-claude-back

  say "Pressing Super + M for the rig menu"
  monitor "sendkey meta_l-m"
  sleep 3
  screenshot 8-menu
  remote "$USERNAME@localhost" 'pgrep -x fuzzel >/dev/null' || fail "Super + M opened no menu."
  monitor "sendkey esc"
  sleep 2
}

# Last, so it also shows that the button survives Waybar reloading after an update.
check_button() {
  say "Clicking the rig button in Waybar"
  remote "$USERNAME@localhost" bash -ls <<'EOF'
export XDG_RUNTIME_DIR=/run/user/$(id -u)
export HYPRLAND_INSTANCE_SIGNATURE=$(ls -t "$XDG_RUNTIME_DIR/hypr" | head -1)
hyprctl dispatch 'hl.dsp.cursor.move({ x = 1268, y = 15 })'
EOF
  monitor "mouse_move 1 0"
  sleep 1
  monitor "mouse_button 1"
  sleep 1
  monitor "mouse_button 0"
  sleep 3
  screenshot 9-menu-clicked
  remote "$USERNAME@localhost" 'pgrep -x fuzzel >/dev/null' || fail "the button in Waybar opened no menu."
  monitor "sendkey esc"
}

# Prints how many windows float on a workspace.
floating_state() {
  remote "$USERNAME@localhost" bash -ls -s "$1" <<'EOF'
export XDG_RUNTIME_DIR=/run/user/$(id -u)
export HYPRLAND_INSTANCE_SIGNATURE=$(ls -t "$XDG_RUNTIME_DIR/hypr" | head -1)
hyprctl clients -j | jq -r --argjson id "$1" \
  'map(select(.workspace.id == $id)) | "\(length) windows, \(map(select(.floating)) | length) floating"'
EOF
}

# Prints where the oldest window on the first workspace is.
first_window() {
  remote "$USERNAME@localhost" bash -ls <<'EOF'
export XDG_RUNTIME_DIR=/run/user/$(id -u)
export HYPRLAND_INSTANCE_SIGNATURE=$(ls -t "$XDG_RUNTIME_DIR/hypr" | head -1)
hyprctl clients -j | jq -c 'map(select(.workspace.id == 1))[0] | [.at, .size]'
EOF
}

expect_floating() {
  local state
  state=$(floating_state "$1")
  [[ $state == "$2" ]] || fail "$3 Workspace $1 has $state, expected $2."
}

check_floating() {
  say "Pressing Super + T to make the workspace float"
  monitor "sendkey meta_l-a" # Claude was showing, and it would get the new window
  sleep 3
  local tiled
  tiled=$(first_window)
  monitor "sendkey meta_l-t"
  sleep 3
  [[ $(first_window) == "$tiled" ]] || fail "Super + T moved a window from $tiled to $(first_window)."
  monitor "sendkey meta_l-ret"
  sleep 10
  screenshot a-floating
  expect_floating 1 "2 windows, 2 floating" "Super + T did not float every window."

  say "Opening a window on the next workspace, which should still tile"
  monitor "sendkey meta_l-2"
  sleep 3
  monitor "sendkey meta_l-ret"
  sleep 10
  expect_floating 2 "1 windows, 0 floating" "the floating leaked to another workspace."
  monitor "sendkey meta_l-1"
  sleep 3

  say "Pressing Super + T to tile it again"
  monitor "sendkey meta_l-t"
  sleep 3
  screenshot b-tiled
  expect_floating 1 "2 windows, 0 floating" "Super + T did not tile the windows again."

  say "Using what the menu runs"
  remote "$USERNAME@localhost" bash -ls <<'EOF'
export XDG_RUNTIME_DIR=/run/user/$(id -u)
export HYPRLAND_INSTANCE_SIGNATURE=$(ls -t "$XDG_RUNTIME_DIR/hypr" | head -1)
eval "$(sed -n 's/^Flydende.*|//p' ~/rig/bin/rig-menu)"
EOF
  sleep 3
  expect_floating 1 "2 windows, 2 floating" "the menu did not float the windows."
}

# Fails unless the login is in the middle of the screenshot, $2 x $3 pixels.
check_centered() {
  local box left top width height
  box=$(convert "$1.png" -trim -format '%X %Y %w %h' info:)
  read -r left top width height <<<"${box//+/}"
  local across=$((2 * left + width - $2)) down=$((2 * top + height - $3))
  if ((width < 300 || across <= -4 || across >= 4 || down <= -80 || down >= 80)); then
    fail "$1 has the login at $box instead of the middle of $2x$3."
  fi
}

# The monitor beside the T480s wakes up after Plymouth has started. It gets a
# bigger screen in here, because that is what moves everything on the small one.
check_late_screen() {
  say "Connecting a larger screen at the password prompt"
  # secondary-vga is the only screen QEMU can plug into a running VM, and the
  # initramfs has no driver for it. A reset doesn't flush, hence the sync.
  remote "$USERNAME@localhost" "PASSWORD=$PASSWORD bash -ls" <<'EOF'
printf '%s\n' "$PASSWORD" | sudo -S sh -c \
  'echo "MODULES=(bochs)" >/etc/mkinitcpio.conf.d/e2e.conf && mkinitcpio -P && sync'
EOF
  monitor system_reset
  sleep 45
  monitor "device_add secondary-vga,id=late,xres=1920,yres=1080"
  sleep 20
  screenshot 3-boot-screen-small
  monitor "screendump $WORK/3-boot-screen-large.png -f png late"
  sleep 2
  check_centered 2-boot-screen 1280 800
  check_centered 3-boot-screen-small 1280 800
  check_centered 3-boot-screen-large 1920 1080
}

# Prints what's on screen in a form the checks above can grep. An SSH session
# isn't part of the desktop, so it has to find the running Hyprland first.
desktop_state() {
  remote "$USERNAME@localhost" bash -ls <<'EOF'
export XDG_RUNTIME_DIR=/run/user/$(id -u)
export HYPRLAND_INSTANCE_SIGNATURE=$(ls -t "$XDG_RUNTIME_DIR/hypr" | head -1)
echo "errors: $(hyprctl configerrors)"
hyprctl clients | grep -E '^\s*class:'
echo "special: $(hyprctl monitors -j | jq -r '.[0].specialWorkspace.name')"
echo "processes: $(pgrep -c 'waybar|mako|hypridle')"
if [[ -e ~/.local/state/rig/first-boot ]]; then echo "flag: there"; else echo "flag: gone"; fi
EOF
}

# The same one-liner on a system that's already installed, which is also how
# you repair it. After the first login, so a second run can't bring back the
# flag that opens Claude. Passwordless for this run only: nobody is here to type.
check_rerun() {
  say "Running the one-liner again on the installed system"
  remote "$USERNAME@localhost" "PASSWORD=$PASSWORD REPO=$REPO BRANCH=$BRANCH bash -ls" <<'EOF' | tee rerun.txt
rule=/etc/sudoers.d/99-e2e
# verifypw too: sudo -v still asks as long as any other rule needs a password.
printf '%s\n' "$PASSWORD" | sudo -S sh -c \
  "printf '%s\n' 'Defaults:$USER verifypw=any' '$USER ALL=(ALL:ALL) NOPASSWD: ALL' >$rule"
curl -fsSL "https://github.com/$REPO/raw/$BRANCH/install.sh" |
  RIG_REPO=$REPO RIG_BRANCH=$BRANCH bash >/tmp/rerun.log 2>&1
echo "exit: $?"
tail -6 /tmp/rerun.log
grep -c 'could not update' /tmp/rerun.log | sed 's/^/update warnings: /'

# What the menu's Opdater runs: it must fetch what's new on its own.
# It runs from a copy, because going a commit back would also test the old script.
cp "$HOME/rig/bin/rig-update" /tmp/rig-update
git -C "$HOME/rig" reset -q --hard HEAD~1
/tmp/rig-update </dev/null >/tmp/update.log 2>&1
echo "update exit: $?"
echo "behind: $(git -C "$HOME/rig" rev-list --count 'HEAD..@{upstream}')"
grep -c 'Alt er opdateret' /tmp/update.log | sed 's/^/update finished: /'
sudo rm -f "$rule"
echo "repo changes: [$(git -C "$HOME/rig" status --porcelain)]"
if [[ -e ~/.local/state/rig/first-boot ]]; then echo "flag: there"; else echo "flag: gone"; fi
EOF
  grep -q '^exit: 0$' rerun.txt || fail "the installer failed on an installed system."
  grep -q '^update warnings: 0$' rerun.txt || fail "a second run could not update ~/rig."
  grep -q '^update exit: 0$' rerun.txt || fail "rig-update failed on an installed system."
  grep -q '^behind: 0$' rerun.txt || fail "rig-update did not fetch the newest commits."
  grep -q '^update finished: 1$' rerun.txt || fail "rig-update never got to its last question."
  grep -q '^repo changes: \[\]$' rerun.txt || fail "a second run changed the repo."
  grep -q '^flag: gone$' rerun.txt || fail "a second run brought back the first-login flag."
}

prepare
install_from_iso
unlock_disk
check_system
check_desktop
check_rerun
check_button
check_floating
check_late_screen
say "Everything passed"
