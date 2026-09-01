#!/usr/bin/env bash
# Install an encrypted machine and boot it.
#
# The one claim about LUKS that evaluation cannot make: that the thing boots
# and asks for a passphrase, and that answering it yields a working system.
# An encrypted root is unlocked in the initrd - before networking, before
# sshd - so the only channel alive at that moment is the serial console.
#
# Runs on its own disk so the dev VM everything else is driven from survives.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
VM_DIR="$(cd "$DIR/.." && pwd)"
PASS="${PASS:-kiwami-test}"

HOST=vm-luks \
DISK="$VM_DIR/disks/luks.qcow2" \
VARS="$VM_DIR/disks/luks-vars.fd" \
SNAPSHOT=0 \
PRE_INSTALL="printf '%s' '$PASS' > /tmp/luks.key" \
UNLOCK="$PASS" \
  "$DIR/install.sh"

echo
echo "checking the encrypted system"
fail=0
ok() { printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
no() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=1; }

# The root really is on an encrypted volume, not a plain partition that
# happened to boot.
"$DIR/vmssh" 'findmnt -no SOURCE / | grep -q "^/dev/mapper/"' \
  && ok "root is on a mapped device" || no "root is on a mapped device"
"$DIR/vmssh" 'sudo cryptsetup status cryptroot | grep -q "type: *LUKS"' \
  && ok "cryptroot is a LUKS volume" || no "cryptroot is a LUKS volume"
# Swap inside the container is the whole point: a hibernation image written
# beside it would be a plaintext copy of RAM.
#
# Asked as a dependency question rather than by name. swapon reports the
# device-mapper node (/dev/dm-1), not /dev/pool/swap, so matching on a path
# failed against a layout that was in fact correct. `lsblk -s` walks from the
# device up through its parents, so finding a crypt layer there is the actual
# claim - and it holds whatever the volume group is called.
"$DIR/vmssh" 'lsblk -sno TYPE "$(swapon --show=NAME --noheadings | head -1)" | grep -q crypt' \
  && ok "swap is inside the encrypted container" || no "swap is inside the encrypted container"
"$DIR/vmssh" 'lsblk -no TYPE | grep -q crypt' \
  && ok "a crypt layer exists" || no "a crypt layer exists"

echo
[[ $fail -eq 0 ]] && printf '\033[1;32m==> encrypted install works\033[0m\n' \
  || { printf '\033[1;31m==> encrypted install broken\033[0m\n'; exit 1; }
