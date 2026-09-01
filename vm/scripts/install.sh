#!/usr/bin/env bash
# Unattended NixOS install into the dev VM disk.
# Wipes the disk, installs from the ISO, fixes UEFI boot order, verifies SSH.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
VM_DIR="$(cd "$DIR/.." && pwd)"
# Overridable so the LUKS test can install onto its own disk instead of
# replacing the dev VM, which stays the machine everything else is driven from.
DISK="${DISK:-$VM_DIR/disks/kiwami.qcow2}"
VARS="${VARS:-$VM_DIR/disks/edk2-vars.fd}"
export DISK VARS
KEY="$VM_DIR/keys/kiwami_vm"
CONSOLE="python3 $DIR/console.py"
HOST="${HOST:-vm-aarch64}"
# A command run on the installer before `kiwami install`. The encrypted host
# takes its passphrase from a file, and this is where that file is written.
PRE_INSTALL="${PRE_INSTALL:-}"
# Sent to the console once after reboot. An encrypted root asks for its
# passphrase in the initrd, before networking exists - the serial line is the
# only channel alive that early, which is why this cannot be done over ssh.
UNLOCK="${UNLOCK:-}"
# Snapshotting is for the dev VM baseline; a throwaway test disk does not
# need one.
SNAPSHOT="${SNAPSHOT:-1}"

step() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

step "resetting disk"
"$DIR/stop-vm.sh" || true
rm -f "$DISK" "$VARS"

# The Kiwami image when it has been built, otherwise the stock NixOS one.
# Only ours carries the harness key, which is what lets the flake go over ssh
# instead of down the serial line.
KIWAMI_ISO="$VM_DIR/iso/kiwami-installer-aarch64.iso"
if [[ -f "$KIWAMI_ISO" ]]; then
  export ISO="$KIWAMI_ISO"
  echo "    using the Kiwami image"
fi

step "booting installer ISO"
"$DIR/start-vm.sh" install headless

step "waiting for installer shell"
TIMEOUT=240 $CONSOLE expect 'nixos@nixos' >/dev/null || { echo "installer never came up"; exit 1; }
$CONSOLE send 'sudo -i' >/dev/null; sleep 1

step "pushing the flake to the installer"
# Over ssh when the installer has our key, which is every image we build. The
# fallback is chunked base64 down the serial line, and it only exists for the
# stock NixOS ISO: a tty in canonical mode truncates lines past ~4096 bytes,
# so a 40MB tarball becomes some sixteen thousand writes.
TAR=(env COPYFILE_DISABLE=1 tar --no-xattrs --exclude='./cli/target' --exclude='cli/target'
     -czf - flake.nix flake.lock hosts modules config shell cli)

if "$DIR/vmssh" 'true' 2>/dev/null; then
  echo "    over ssh"
  (cd "$VM_DIR/.." && "${TAR[@]}") \
    | "$DIR/vmssh" 'rm -rf /tmp/kiwami && mkdir -p /tmp/kiwami && tar xzf - -C /tmp/kiwami'
else
  echo "    over serial (stock ISO, no key)"
  B64=$(cd "$VM_DIR/.." && "${TAR[@]}" | base64 | tr -d '\n')
  echo "    payload: ${#B64} chars"
  $CONSOLE run 'rm -rf /tmp/kiwami && mkdir -p /tmp/kiwami && rm -f /tmp/k.b64' >/dev/null
  for (( i=0; i<${#B64}; i+=2500 )); do
    $CONSOLE run "printf '%s' '${B64:$i:2500}' >> /tmp/k.b64" >/dev/null
  done
  $CONSOLE run 'base64 -d /tmp/k.b64 | tar xzf - -C /tmp/kiwami' >/dev/null
fi

LOCAL_SUM=$(cd "$VM_DIR/.." && find flake.nix flake.lock hosts modules config shell cli/src -type f | sort | xargs cat | shasum | cut -d' ' -f1)
# The checksum stays for both paths. Over ssh corruption is unlikely, but the
# point is that the tree being installed is the tree on this machine, and that
# is worth asserting however it got there.
if "$DIR/vmssh" 'true' 2>/dev/null; then
  REMOTE_SUM=$("$DIR/vmssh" 'cd /tmp/kiwami && find flake.nix flake.lock hosts modules config shell cli/src -type f | sort | xargs cat | sha1sum | cut -d" " -f1' | tr -d '[:space:]')
else
  REMOTE_SUM=$($CONSOLE run 'cd /tmp/kiwami && find flake.nix flake.lock hosts modules config shell cli/src -type f | sort | xargs cat | sha1sum | cut -d" " -f1' | tr -d '[:space:]')
fi
[[ "$LOCAL_SUM" == "$REMOTE_SUM" ]] || { echo "flake transfer corrupted ($LOCAL_SUM != $REMOTE_SUM)"; exit 1; }
echo "    checksum ok"

if [[ -n "$PRE_INSTALL" ]]; then
  step "preparing the installer"
  $CONSOLE run "$PRE_INSTALL" >/dev/null
fi

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

# The repo is placed on the installed system by `kiwami install` itself now.
# It used to happen here, which meant the harness was quietly supplying
# something a real install did not - the machine would boot and then have no
# checkout to rebuild from, and the generated hardware.nix would be gone.

step "seeding ssh key"
[[ -f "$KEY" ]] || ssh-keygen -t ed25519 -N '' -C kiwami-vm -f "$KEY" >/dev/null
PUB=$(cat "$KEY.pub")
$CONSOLE run "mkdir -p /mnt/home/nixos/.ssh && echo '$PUB' > /mnt/home/nixos/.ssh/authorized_keys && chmod 700 /mnt/home/nixos/.ssh && chmod 600 /mnt/home/nixos/.ssh/authorized_keys && nixos-enter --root /mnt -- chown -R nixos:users /home/nixos/.ssh" >/dev/null

# The boot order is corrected by `kiwami install` itself now. It used to
# happen here, which is why the installer's silence went unnoticed: every VM
# install came out with a working order and nothing ever pointed at the CLI.

step "rebooting into installed system"
$CONSOLE send 'poweroff' >/dev/null 2>&1 || true
sleep 12
"$DIR/stop-vm.sh" || true
"$DIR/start-vm.sh" run headless

if [[ -n "$UNLOCK" ]]; then
  step "unlocking over serial"
  # The prompt has to be waited for: sending early goes nowhere, and there is
  # no ssh to fall back on until the root filesystem is open.
  # systemd asks "Please enter passphrase for disk <label> (<name>):" - match
  # the part that is stable, in the case it is actually printed. Guessing at
  # "Passphrase for" cost a run that sat until the unlock timed out and the
  # machine dropped to emergency mode with the prompt plainly on screen.
  if TIMEOUT=180 $CONSOLE expect 'passphrase for' >/dev/null 2>&1; then
    $CONSOLE send "$UNLOCK" >/dev/null
    echo "    passphrase sent"
  else
    echo "!! no passphrase prompt appeared on the console; last output was:"
    tail -c 1200 "$VM_DIR/serial.log" | tr '\r' '\n' | tail -8
    exit 1
  fi
fi

step "verifying"
for _ in $(seq 1 30); do
  sleep 5
  if "$DIR/vmssh" 'true' 2>/dev/null; then
    echo "    ssh ok: $("$DIR/vmssh" 'hostname; uname -m' 2>/dev/null | paste -sd' ' -)"
    # Snapshot the pristine system so `just vm reset` has a baseline.
    # qemu-img needs the image unlocked, so stop, snapshot, boot again.
    if [[ "$SNAPSHOT" == "1" ]]; then
      "$DIR/stop-vm.sh" >/dev/null 2>&1 || true
      "$DIR/snapshot.sh" save installed >/dev/null 2>&1 && echo "    snapshot 'installed' saved"
      "$DIR/start-vm.sh" run headless >/dev/null
    fi
    printf '\n\033[1;32m==> install complete\033[0m\n'
    exit 0
  fi
done
echo "!! system did not come up over ssh"; exit 1
