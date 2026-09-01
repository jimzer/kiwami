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
# On the live image there is no checkout yet, so the run starts by making one
# the way the login banner tells a person to - which tests that instruction
# as a side effect.
ON_ISO="${ON_ISO:-0}"
FLAKE="/home/nixos/kiwami"
if [[ "$ON_ISO" == "1" ]]; then
  echo "cloning the flake into the live image"
  "$SSH" "test -d $FLAKE || git clone -q https://github.com/jimzer/kiwami $FLAKE" || {
    echo "clone failed"; exit 1; }
fi
K="sudo kiwami install --force --flake $FLAKE --host vm-aarch64"
# Disk selection only happens for a host that does not declare its layout
# yet. An existing host's disk.nix is the target, so the menu is skipped.
KNEW="sudo kiwami install --force --flake $FLAKE --host tmptest --new"

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
# Context-dependent: an installed system is running off one of these disks,
# a live image is running off a tmpfs and a CD. Both facts are worth
# asserting, but only one of them is true at a time.
if [[ "$ON_ISO" == "1" ]]; then
  check "no disk is in use on live media" "0" \
    'kiwami disks | grep -c "IN USE" | tr -d "\n"'
else
  check "flags the in-use disk"          "IN USE"        'kiwami disks'
fi
check "counts existing partitions"     "existing partition" 'kiwami disks'

# --- refusals, before anything is written --------------------------------
# The same guard, from both sides. It used to test for /etc/NIXOS, which the
# live ISO also has, so it refused to run on the one machine it exists for -
# and the matrix only ever checked the installed side, where it was right by
# accident.
if [[ "$ON_ISO" == "1" ]]; then
  # Reaching the network step at all proves the media guard let it through.
  check "runs on installer media"      "checking network" \
    'sudo kiwami install --disk /dev/nvme0n1 --yes'
  check "kiwami is on PATH already"    "kiwami" 'command -v kiwami'
  check "flakes are enabled"           "0" \
    'nix eval --expr 1 >/dev/null 2>&1; echo $?'
  check "the banner says what to run"  "kiwami install" 'cat /etc/issue'
else
  check "refuses on an installed system" "not the installer ISO" \
    'kiwami install --disk /dev/nvme0n1 --yes'
fi
check "refuses without root"           "must run as root" \
  'kiwami install --force --disk /dev/nvme0n1 --yes'
check "refuses a disk that is too small" "needs at least 20 GiB" \
  "$KNEW --disk /dev/vdc --yes"
check "refuses an unknown disk"        "no such disk" \
  "$KNEW --disk /dev/nope --yes"
check "--disk cannot contradict disk.nix" "is not what vm-aarch64 declares" \
  "$K --disk /dev/vdb --yes"
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
# Its own host name: this is the one check that accepts the layout, which
# creates hosts/<name>/ - and a host that exists takes the already-declared
# path, so reusing tmptest would make every later menu check test nothing.
check "warns before erasing a non-empty disk" "Everything on it will be destroyed" \
  "printf 'n\nn\nn\ni\nno\n' | sudo kiwami install --force --flake $FLAKE --host tmpaccept --new --disk /dev/vdb"
check "targets the disk disk.nix names" "About to install to /dev/vda" \
  "echo no | $K"
check "offers a numbered disk menu"    "Install to which disk?" \
  "printf '1\nno\n' | $KNEW"
check "rejects an out-of-range choice" "Enter a number between" \
  "printf '99\n1\nno\n' | $KNEW"
check "offers a numbered host menu"    "Install which host?" \
  "printf '1\n1\nno\n' | sudo kiwami install --force --flake $FLAKE"

# --- the layout wizard ---------------------------------------------------
# Each of these aborts at the review step, so nothing is ever formatted.
WIZ="sudo timeout 90 kiwami install --force --flake $FLAKE --host wiztest --new"
# A leftover hosts/wiztest would make the host already-declared, and every
# check below would silently exercise the wrong path.
"$SSH" "sudo rm -rf $FLAKE/hosts/wiztest" >/dev/null 2>&1
check "wizard writes a disko layout"   "disko.devices.disk" \
  "printf '1\nn\nn\nn\na\n' | $WIZ"
check "names disks by stable id"       "/dev/disk/by-id/" \
  "printf '1\nn\nn\nn\na\n' | $WIZ"
check "prefers the readable id alias"  "nvme-QEMU_NVMe_Ctrl_kiwami-test-nvme" \
  "printf '1\nn\nn\nn\na\n' | $WIZ"
check "hibernation adds a sized swap"  "type = \"swap\"" \
  "printf '1\nn\nn\ny\na\n' | $WIZ"
check "encryption wraps root in luks"  "type = \"luks\"" \
  "printf '1\nn\ny\nn\na\n' | $WIZ"
check "refuses encrypt plus hibernate" "needs the swap area inside" \
  "printf '1\nn\ny\ny\n' | $WIZ"
check "review can abort"               "aborted; nothing was written" \
  "printf '1\nn\nn\nn\na\n' | $WIZ"
# A closed stdin used to spin the menu forever printing its retry message.
check "end of input is not a loop"     "no more input" \
  "printf '1\n' | $WIZ"
check "wizard host still evaluates"    "disko" \
  "printf '1\nn\nn\nn\ni\n' | $WIZ >/dev/null 2>&1; cd $FLAKE && nix eval --raw .#nixosConfigurations.wiztest.config.system.build.diskoScript"
"$SSH" "sudo rm -rf $FLAKE/hosts/wiztest" >/dev/null 2>&1

# --- the one that matters ------------------------------------------------
BEFORE=$("$SSH" 'lsblk -no NAME /dev/vdb | tr "\n" " "' 2>/dev/null)
check "cancelling reports nothing written" "nothing was written" \
  "printf 'n\nn\nn\na\n' | $KNEW --disk /dev/vdb"
AFTER=$("$SSH" 'sudo udevadm settle; lsblk -no NAME /dev/vdb | tr "\n" " "' 2>/dev/null)
if [[ "$BEFORE" == "$AFTER" && -n "$BEFORE" ]]; then
  printf '  \033[32mPASS\033[0m  cancelling leaves the disk untouched\n'; pass=$((pass + 1))
else
  printf '  \033[31mFAIL\033[0m  cancelling leaves the disk untouched\n        before: %s\n        after:  %s\n' \
    "$BEFORE" "$AFTER"; fail=$((fail + 1))
fi

# Hosts the wizard checks created. Left behind, they would make the next run
# take the already-declared path and quietly test nothing.
"$SSH" "sudo rm -rf $FLAKE/hosts/wiztest $FLAKE/hosts/tmptest $FLAKE/hosts/tmpaccept" >/dev/null 2>&1

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
