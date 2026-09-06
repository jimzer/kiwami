#!/usr/bin/env bash
# `--relayout` rewrites a host's disk.nix, and aborting puts it back.
#
# Changing a machine's disk layout is the one edit that cannot be made on the
# running machine: disk.nix is a recipe for formatting, and the disk is already
# formatted. So the layout changes where formatting happens, and --relayout is
# how. That makes it a command that rewrites a committed file moments before
# erasing a disk, which is worth being sure about.
#
# This deliberately stops at the review and aborts. Everything new lives before
# that point - running the wizard for a host that already declares its disks,
# showing what changes, rewriting the file, and restoring it if the change is
# refused - and stopping there keeps the test to a couple of minutes with no
# disk erased. That the encrypted layout it produces actually boots and wipes
# is a separate claim, proved by the luks-ephemeral test.
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
VM_DIR="$(cd "$DIR/.." && pwd)"
CONSOLE="python3 $DIR/console.py"
HOST=vm-ephemeral

pass=0; fail=0
ok() { printf '  \033[32mPASS\033[0m  %s\n' "$1"; pass=$((pass+1)); }
no() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); }
step() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

step "booting the installer with the flake on it"
DISK="$VM_DIR/disks/relayout.qcow2" VARS="$VM_DIR/disks/relayout-vars.fd" \
  "$DIR/stop-vm.sh" >/dev/null 2>&1 || true
rm -f "$VM_DIR/disks/relayout.qcow2" "$VM_DIR/disks/relayout-vars.fd"
qemu-img create -f qcow2 "$VM_DIR/disks/relayout.qcow2" 20G >/dev/null
cp -f "$(brew --prefix)/share/qemu/edk2-arm-vars.fd" "$VM_DIR/disks/relayout-vars.fd"

ISO="$VM_DIR/iso/kiwami-installer-aarch64.iso" \
DISK="$VM_DIR/disks/relayout.qcow2" \
VARS="$VM_DIR/disks/relayout-vars.fd" \
  "$DIR/start-vm.sh" install headless >/dev/null

TIMEOUT=600 $CONSOLE expect 'nixos@nixos' >/dev/null || { echo "installer never came up"; exit 1; }
$CONSOLE send 'sudo -i' >/dev/null; sleep 1

# The tree under test, pushed the same way every other VM test pushes it.
(cd "$VM_DIR/.." && env COPYFILE_DISABLE=1 tar --no-xattrs --exclude='cli/target' \
  -czf - flake.nix flake.lock hosts modules config shell cli) \
  | "$DIR/vmssh" 'rm -rf /tmp/kiwami && mkdir -p /tmp/kiwami && tar xzf - -C /tmp/kiwami' \
  || { echo "could not push the flake"; exit 1; }

before=$("$DIR/vmssh" "grep -c 'type = \"luks\"' /tmp/kiwami/hosts/$HOST/disk.nix" 2>/dev/null | tr -d '[:space:]')
[ "${before:-0}" = "0" ] && ok "the host starts out unencrypted" || no "the host starts out unencrypted"

step "running the wizard for a host that already declares its disks"
# Answers, in order: which disk, /home elsewhere, encrypt, then abort at the
# review. Fed on stdin rather than typed at the console - the prompts read
# stdin, and this keeps the test deterministic.
# sudo, because vmssh lands as the unprivileged installer user and the
# installer refuses without root - it enumerates disks and is about to erase
# one. `sudo env` rather than -E: sudo strips the environment, and nix needs
# its experimental features flag to run a flake.
"$DIR/vmssh" "cd /tmp && printf '1\\nn\\ny\\na\\n' | \
  sudo env NIX_CONFIG='experimental-features = nix-command flakes' \
  nix run /tmp/kiwami#kiwami -- install --host $HOST --relayout \
    --flake /tmp/kiwami --force > /tmp/relayout.log 2>&1; true" >/dev/null 2>&1

log=$("$DIR/vmssh" 'cat /tmp/relayout.log' 2>/dev/null)

echo "$log" | grep -q "is being replaced" \
  && ok "it says the layout is being replaced" || no "it says the layout is being replaced"
# Colour codes sit between the indentation and the text, so a pattern
# anchored on "+" never matched. Strip them and read the summary instead.
echo "$log" | sed 's/\x1b\[[0-9;]*m//g' | grep -qE 'encrypted: no -> yes' \
  && ok "it reports encryption being turned on" || no "it reports encryption being turned on"

step "and aborting leaves no trace"
after=$("$DIR/vmssh" "grep -c 'type = \"luks\"' /tmp/kiwami/hosts/$HOST/disk.nix" 2>/dev/null | tr -d '[:space:]')
[ "${after:-0}" = "0" ] \
  && ok "disk.nix is back to the layout it had" \
  || no "disk.nix still carries the refused layout"

# The disk itself must be untouched: the abort happens before formatting, and
# an installer that writes before you confirm is worse than any prompt bug.
# lsblk under sudo, not blkid as the installer user: unprivileged blkid reads
# a cache and exits 0, so a blank disk reported as formatted and this check
# failed on a disk that was in fact untouched.
state=$("$DIR/vmssh" 'sudo lsblk -no FSTYPE,PTTYPE /dev/vda | tr -d " \n"' 2>/dev/null)
[ -z "$state" ] \
  && ok "the disk was never touched" || no "the disk was never touched (found: $state)"

echo
if [ $fail -eq 0 ]; then
  printf '\033[1;32m==> relayout rewrites, and abort restores (%d checks)\033[0m\n' "$pass"
else
  printf '\033[1;31m==> %d failed, %d passed\033[0m\n' "$fail" "$pass"
  echo "--- installer log:"; echo "$log" | tail -20 | sed 's/^/    /'
  exit 1
fi
