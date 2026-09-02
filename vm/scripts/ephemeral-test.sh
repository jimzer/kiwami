#!/usr/bin/env bash
# Install a machine with an ephemeral root, then prove it is ephemeral.
#
# The claim is not "it booted" - a rollback that silently does nothing also
# boots, and looks perfectly healthy. The claim is that a file written to /
# is gone after a reboot while a file written to /persist is not, which is
# the only observation that distinguishes a working wipe from an absent one.
#
# Runs on its own disk so the dev VM survives.
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
VM_DIR="$(cd "$DIR/.." && pwd)"

HOST=vm-ephemeral \
DISK="$VM_DIR/disks/ephemeral.qcow2" \
VARS="$VM_DIR/disks/ephemeral-vars.fd" \
SNAPSHOT=0 \
  "$DIR/install.sh" || { echo "install failed"; exit 1; }

pass=0; fail=0
ok() { printf '  \033[32mPASS\033[0m  %s\n' "$1"; pass=$((pass+1)); }
no() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); }
ssh_() { "$DIR/vmssh" "$@" 2>/dev/null; }

echo
echo "layout"
ssh_ 'findmnt -no FSTYPE / | grep -q btrfs' \
  && ok "root is btrfs" || no "root is btrfs"
ssh_ 'findmnt -no OPTIONS / | grep -q "subvol=/@root"' \
  && ok "root is the @root subvolume" || no "root is the @root subvolume"
ssh_ 'findmnt -no TARGET /persist | grep -q /persist' \
  && ok "/persist is mounted" || no "/persist is mounted"
ssh_ 'sudo btrfs subvolume show /mnt-btrfs 2>/dev/null; sudo mkdir -p /tmp/b && sudo mount -o subvol=/ /dev/disk/by-partlabel/disk-system-root /tmp/b && sudo btrfs subvolume show /tmp/b/@root-blank >/dev/null' \
  && ok "@root-blank snapshot exists" || no "@root-blank snapshot exists"

# Declared state must actually be bound out of /persist, not merely present.
ssh_ 'findmnt -no SOURCE /var/lib/nixos | grep -q persist' \
  && ok "/var/lib/nixos comes from /persist" || no "/var/lib/nixos comes from /persist"

echo
echo "the wipe"
# A marker on the root, and one on /persist. After a reboot exactly one should
# survive; either both or neither means the rollback is not doing its job.
ssh_ 'sudo touch /ephemeral-marker && sudo touch /persist/persistent-marker' >/dev/null
ssh_ 'test -e /ephemeral-marker && test -e /persist/persistent-marker' \
  && ok "both markers written" || no "both markers written"

echo "  rebooting..."
ssh_ 'sudo systemctl reboot' >/dev/null 2>&1
sleep 20
for _ in $(seq 1 40); do ssh_ true && break; sleep 5; done

if ! ssh_ true; then
  no "machine came back after reboot"
else
  ok "machine came back after reboot"
  ssh_ 'test ! -e /ephemeral-marker' \
    && ok "the root marker is gone - the root was wiped" \
    || no "the root marker survived - THE ROLLBACK DID NOT RUN"
  ssh_ 'test -e /persist/persistent-marker' \
    && ok "the persist marker survived" || no "the persist marker survived"
  ssh_ 'sudo test -d /var/lib/nixos && findmnt -no SOURCE /var/lib/nixos | grep -q persist' \
    && ok "declared state is bound back after the wipe" \
    || no "declared state is bound back after the wipe"
fi

echo
[[ $fail -eq 0 ]] && printf '\033[1;32m==> ephemeral root works\033[0m\n' \
  || { printf '\033[1;31m==> %d check(s) failed\033[0m\n' "$fail"; exit 1; }
