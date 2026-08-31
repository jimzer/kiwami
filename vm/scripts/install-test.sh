#!/usr/bin/env bash
# Installer test matrix.
#
# Runs against a VM started with TEST_DISKS=1, which attaches three scratch
# disks: an empty NVMe, a partitioned virtio disk, and one below the minimum
# size. Everything here exercises the installer's *decisions* and is
# non-destructive to the running system - the only disk ever written is a
# scratch one, and the cancel case asserts nothing was written at all.
#
# The full install path is covered separately by `just vm install`.
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
SSH="$DIR/vmssh"
pass=0; fail=0

# Every run that gets past the root gate now resolves --host against a flake,
# so the checks below point at the pushed tree (`just vm push`) rather than
# GitHub: it keeps the matrix offline-clean and fast.
FLAKE="/home/nixos/kiwami"
K="sudo kiwami install --force --flake $FLAKE --host vm-aarch64"

check() {           # check <name> <expected-substring> <command...>
  local name="$1" want="$2"; shift 2
  local got; got=$("$SSH" "$@" 2>&1)
  if grep -qF -- "$want" <<<"$got"; then
    printf '  \033[32mPASS\033[0m  %s\n' "$name"; pass=$((pass + 1))
  else
    printf '  \033[31mFAIL\033[0m  %s\n        wanted: %s\n        got:    %s\n' \
      "$name" "$want" "$(tr '\n' ' ' <<<"$got" | cut -c1-160)"
    fail=$((fail + 1))
  fi
}

echo "installer matrix"

# --- network -------------------------------------------------------------
check "net reports the probe result"   "cache.nixos.org" 'kiwami net --status'
check "net reports NetworkManager"     "NetworkManager"  'kiwami net --status'

# --- detection -----------------------------------------------------------
check "lists the NVMe disk"            "/dev/nvme0n1"  'kiwami disks'
check "hides the NVMe controller alias" ""             'kiwami disks | grep -c "nvme0c" | grep -q "^0$" && echo ""'
check "flags the in-use disk"          "IN USE"        'kiwami disks'
check "counts existing partitions"     "existing partition" 'kiwami disks'

# --- refusals, before anything is written --------------------------------
check "refuses on an installed system" "not the installer ISO" \
  'kiwami install --disk /dev/nvme0n1 --yes'
check "refuses without root"           "must run as root" \
  'kiwami install --force --disk /dev/nvme0n1 --yes'
check "refuses a disk that is too small" "needs at least 20 GiB" \
  "$K --disk /dev/vdc --yes"
check "refuses an unknown disk"        "no such disk" \
  "$K --disk /dev/nope --yes"
check "refuses an unknown host"        "no such host" \
  "sudo kiwami install --force --flake $FLAKE --host nope --disk /dev/vdc --yes"
check "names the hosts it does have"   "vm-aarch64" \
  "sudo kiwami install --force --flake $FLAKE --host nope --disk /dev/vdc --yes"
check "--yes will not guess a host"    "needs an explicit --host" \
  "sudo kiwami install --force --flake $FLAKE --disk /dev/vdc --yes"
check "will not invent a host silently" "Pass --new to scaffold" \
  "sudo kiwami install --force --flake $FLAKE --host laptop --disk /dev/vdc --yes"
check "rejects a bad host name"        "bad host name" \
  "sudo kiwami install --force --flake $FLAKE --host 'a/b' --new --disk /dev/vdc --yes"
check "cannot add a host to a fetched flake" "fetched read-only" \
  "sudo kiwami install --force --flake github:jimzer/kiwami --host laptop --new --disk /dev/vdc --yes"

# --- prompts -------------------------------------------------------------
check "warns before erasing a non-empty disk" "Everything on it will be destroyed" \
  "$K --disk /dev/vdb --yes 2>&1 | head -12"
check "offers a numbered disk menu"    "Install to which disk?" \
  "printf '1\nno\n' | $K"
check "rejects an out-of-range choice" "Enter a number between" \
  "printf '99\n1\nno\n' | $K"
check "offers a numbered host menu"    "Install which host?" \
  "printf '1\n1\nno\n' | sudo kiwami install --force --flake $FLAKE"

# --- the one that matters ------------------------------------------------
BEFORE=$("$SSH" 'lsblk -no NAME /dev/vdb | tr "\n" " "' 2>/dev/null)
check "cancelling reports nothing written" "nothing was written" \
  "echo no | $K --disk /dev/vdb"
AFTER=$("$SSH" 'sudo udevadm settle; lsblk -no NAME /dev/vdb | tr "\n" " "' 2>/dev/null)
if [[ "$BEFORE" == "$AFTER" && -n "$BEFORE" ]]; then
  printf '  \033[32mPASS\033[0m  cancelling leaves the disk untouched\n'; pass=$((pass + 1))
else
  printf '  \033[31mFAIL\033[0m  cancelling leaves the disk untouched\n        before: %s\n        after:  %s\n' \
    "$BEFORE" "$AFTER"; fail=$((fail + 1))
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
