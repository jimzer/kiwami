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

# Labels matter: hosts/vm-aarch64/hardware-configuration.nix mounts by label,
# so these names are part of the contract, not cosmetic.
step "partitioning"
$CONSOLE run 'parted -s /dev/vda -- mklabel gpt mkpart ESP fat32 1MiB 1024MiB set 1 esp on mkpart root ext4 1024MiB 100%' >/dev/null
$CONSOLE run 'mkfs.fat -F 32 -n boot /dev/vda1 >/dev/null 2>&1 && mkfs.ext4 -q -F -L nixos /dev/vda2' >/dev/null
# mkfs returns before udev has created /dev/disk/by-label/*, so settle udev
# before anything looks the labels up. We still mount by device path here
# because it cannot race at all; the installed system mounts by label.
$CONSOLE run 'udevadm settle --timeout=30' >/dev/null

step "mounting"
$CONSOLE run 'mount /dev/vda2 /mnt && mkdir -p /mnt/boot && mount -o umask=077 /dev/vda1 /mnt/boot && mountpoint -q /mnt && mountpoint -q /mnt/boot' >/dev/null

step "pushing the flake to the installer"
# The whole machine definition is the flake, so there is no
# nixos-generate-config step: hosts/vm-aarch64/hardware-configuration.nix is
# committed and mounts by LABEL, which install.sh sets below.
#
# Transfer is chunked base64 over the serial line: a tty in canonical mode
# truncates lines past ~4096 bytes, and one line per file would exceed that.
B64=$(cd "$VM_DIR/.." && COPYFILE_DISABLE=1 tar --no-xattrs -czf - \
        flake.nix flake.lock hosts modules | base64 | tr -d '\n')
echo "    payload: ${#B64} chars"
$CONSOLE run 'rm -rf /tmp/kiwami && mkdir -p /tmp/kiwami && rm -f /tmp/k.b64' >/dev/null
for (( i=0; i<${#B64}; i+=2500 )); do
  $CONSOLE run "printf '%s' '${B64:$i:2500}' >> /tmp/k.b64" >/dev/null
done
$CONSOLE run 'base64 -d /tmp/k.b64 | tar xzf - -C /tmp/kiwami' >/dev/null
LOCAL_SUM=$(cd "$VM_DIR/.." && cat flake.nix flake.lock hosts/vm-aarch64/*.nix modules/*.nix | shasum | cut -d' ' -f1)
REMOTE_SUM=$($CONSOLE run 'cat /tmp/kiwami/flake.nix /tmp/kiwami/flake.lock /tmp/kiwami/hosts/vm-aarch64/*.nix /tmp/kiwami/modules/*.nix | sha1sum | cut -d" " -f1' | tr -d '[:space:]')
[[ "$LOCAL_SUM" == "$REMOTE_SUM" ]] || { echo "flake transfer corrupted ($LOCAL_SUM != $REMOTE_SUM)"; exit 1; }
echo "    checksum ok"

step "installing from the flake (this is the slow part)"
# The installer ISO ships with flakes DISABLED, so nixos-install --flake needs
# them turned on explicitly for this shell.
$CONSOLE run "nohup env NIX_CONFIG='experimental-features = nix-command flakes' \
  nixos-install --flake /tmp/kiwami#${HOST} --no-root-passwd > /tmp/install.log 2>&1 &" >/dev/null
for _ in $(seq 1 60); do
  sleep 10
  if $CONSOLE run 'grep -q "installation finished" /tmp/install.log && echo DONE' 2>/dev/null | grep -q DONE; then
    echo "    installation finished"; break
  fi
  printf '    still installing...\n'
done
$CONSOLE run 'grep -q "installation finished" /tmp/install.log' >/dev/null || { echo "install failed:"; $CONSOLE run 'tail -25 /tmp/install.log'; exit 1; }

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
