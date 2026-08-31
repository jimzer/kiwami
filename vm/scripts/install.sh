#!/usr/bin/env bash
# Unattended NixOS install into the dev VM disk.
# Wipes the disk, installs from the ISO, fixes UEFI boot order, verifies SSH.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
VM_DIR="$(cd "$DIR/.." && pwd)"
DISK="$VM_DIR/disks/kiwami.qcow2"
KEY="$VM_DIR/keys/kiwami_vm"
CONSOLE="python3 $DIR/console.py"
HOST="${HOST:-vm-aarch64}"

step() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

step "resetting disk"
"$DIR/stop-vm.sh" || true
rm -f "$DISK" "$VM_DIR/disks/edk2-vars.fd"

step "booting installer ISO"
"$DIR/start-vm.sh" install headless

step "waiting for installer shell"
TIMEOUT=240 $CONSOLE expect 'nixos@nixos' >/dev/null || { echo "installer never came up"; exit 1; }
$CONSOLE send 'sudo -i' >/dev/null; sleep 1

step "pushing the flake to the installer"
# Chunked base64 over the serial line: a tty in canonical mode truncates
# lines past ~4096 bytes, so this cannot go in one write.
B64=$(cd "$VM_DIR/.." && COPYFILE_DISABLE=1 tar --no-xattrs --exclude='./cli/target' --exclude='cli/target' -czf - \
        flake.nix flake.lock hosts modules config shell cli | base64 | tr -d '\n')
echo "    payload: ${#B64} chars"
$CONSOLE run 'rm -rf /tmp/kiwami && mkdir -p /tmp/kiwami && rm -f /tmp/k.b64' >/dev/null
for (( i=0; i<${#B64}; i+=2500 )); do
  $CONSOLE run "printf '%s' '${B64:$i:2500}' >> /tmp/k.b64" >/dev/null
done
$CONSOLE run 'base64 -d /tmp/k.b64 | tar xzf - -C /tmp/kiwami' >/dev/null
LOCAL_SUM=$(cd "$VM_DIR/.." && find flake.nix flake.lock hosts modules config shell cli/src -type f | sort | xargs cat | shasum | cut -d' ' -f1)
REMOTE_SUM=$($CONSOLE run 'cd /tmp/kiwami && find flake.nix flake.lock hosts modules config shell cli/src -type f | sort | xargs cat | sha1sum | cut -d" " -f1' | tr -d '[:space:]')
[[ "$LOCAL_SUM" == "$REMOTE_SUM" ]] || { echo "flake transfer corrupted ($LOCAL_SUM != $REMOTE_SUM)"; exit 1; }
echo "    checksum ok"

step "installing via kiwami install"
# The installer under test is the one that ships. Previously this script
# partitioned and formatted itself, which meant `just vm install` proved
# nothing about `kiwami install` - two installers, guaranteed to drift.
#
# --regen-hardware makes this the end-to-end test of the generation path:
# the guest detects its own hardware, the result is written into the pushed
# tree, and the machine then boots from it. Anything the generated config
# misses shows up here as a VM that never comes back.
#
# kiwami is built from the pushed flake rather than downloaded: that also
# checks the package builds in the installer environment, which is what a
# real `nixos-install --flake github:...` does. A custom ISO will ship the
# binary and this step becomes a plain `kiwami install`.
$CONSOLE run "nohup env NIX_CONFIG='experimental-features = nix-command flakes' \
  nix run /tmp/kiwami#kiwami -- install \
    --disk /dev/vda --yes --force --regen-hardware \
    --flake /tmp/kiwami --host ${HOST} > /tmp/install.log 2>&1 &" >/dev/null

for _ in $(seq 1 90); do
  sleep 10
  if $CONSOLE run 'grep -q "installation finished" /tmp/install.log && echo DONE' 2>/dev/null | grep -q DONE; then
    echo "    installation finished"; break
  fi
  # Surface the installer's own refusals immediately rather than after 15min.
  if $CONSOLE run 'grep -q "^install:" /tmp/install.log && echo REFUSED' 2>/dev/null | grep -q REFUSED; then
    echo "    installer refused:"; $CONSOLE run 'grep "^install:" /tmp/install.log'; exit 1
  fi
  printf '    still installing...\n'
done
$CONSOLE run 'grep -q "installation finished" /tmp/install.log' >/dev/null || {
  echo "install failed:"; $CONSOLE run 'tail -25 /tmp/install.log'; exit 1; }

step "placing the repo in the user's home"
# modules/home/hyprland.nix symlinks ~/.config/hypr into ~/kiwami/config, so
# the repo must exist there on first boot or the link dangles.
$CONSOLE run 'mkdir -p /mnt/home/nixos/kiwami && cp -r /tmp/kiwami/. /mnt/home/nixos/kiwami/ && nixos-enter --root /mnt -- chown -R nixos:users /home/nixos/kiwami' >/dev/null
echo "    ~/kiwami placed"

step "seeding ssh key"
[[ -f "$KEY" ]] || ssh-keygen -t ed25519 -N '' -C kiwami-vm -f "$KEY" >/dev/null
PUB=$(cat "$KEY.pub")
$CONSOLE run "mkdir -p /mnt/home/nixos/.ssh && echo '$PUB' > /mnt/home/nixos/.ssh/authorized_keys && chmod 700 /mnt/home/nixos/.ssh && chmod 600 /mnt/home/nixos/.ssh/authorized_keys && nixos-enter --root /mnt -- chown -R nixos:users /home/nixos/.ssh" >/dev/null

step "fixing UEFI boot order"
# systemd-boot appends its NVRAM entry LAST, behind UiApp and the EFI Shell,
# so the firmware drops to a shell instead of booting. Move it to the front.
# efibootmgr comes from the freshly installed system via nixos-enter, so this
# needs no network and no channel on the ISO.
EFI_OUT=$($CONSOLE run 'nixos-enter --root /mnt -- efibootmgr 2>/dev/null')
ENTRY=$(echo "$EFI_OUT" | grep "Linux Boot Manager" | head -1 | sed 's/^Boot\([0-9A-Fa-f]*\).*/\1/' | tr -d '[:space:]')
ORDER=$(echo "$EFI_OUT" | grep '^BootOrder' | head -1 | cut -d' ' -f2 | tr -d '[:space:]')
if [[ -n "$ENTRY" && -n "$ORDER" ]]; then
  NEW="$ENTRY,$(echo "$ORDER" | tr ',' '\n' | grep -v "^$ENTRY$" | paste -sd, -)"
  $CONSOLE run "nixos-enter --root /mnt -- efibootmgr -o $NEW -t 1" >/dev/null
  echo "    BootOrder -> $NEW"
else
  echo "    !! Linux Boot Manager entry not found; unattended boot may drop to the EFI shell"
  echo "$EFI_OUT" | head -10
fi

step "rebooting into installed system"
$CONSOLE send 'poweroff' >/dev/null 2>&1 || true
sleep 12
"$DIR/stop-vm.sh" || true
"$DIR/start-vm.sh" run headless

step "verifying"
for _ in $(seq 1 30); do
  sleep 5
  if "$DIR/vmssh" 'true' 2>/dev/null; then
    echo "    ssh ok: $("$DIR/vmssh" 'hostname; uname -m' 2>/dev/null | paste -sd' ' -)"
    # Snapshot the pristine system so `just vm reset` has a baseline.
    # qemu-img needs the image unlocked, so stop, snapshot, boot again.
    "$DIR/stop-vm.sh" >/dev/null 2>&1 || true
    "$DIR/snapshot.sh" save installed >/dev/null 2>&1 && echo "    snapshot 'installed' saved"
    "$DIR/start-vm.sh" run headless >/dev/null
    printf '\n\033[1;32m==> install complete\033[0m\n'
    exit 0
  fi
done
echo "!! system did not come up over ssh"; exit 1
