#!/usr/bin/env bash
# Write an image to a removable drive, on Linux.
#
# The companion to flash.sh, which does this on macOS. It exists because the
# machine that can build an x86_64 image is the x86_64 machine - macOS cannot
# build Linux derivations at all - so the laptop builds its own installer and
# writes it to the stick already plugged into it. The Mac is never involved,
# and therefore never at risk.
#
# `dd` has no idea what it is pointing at. /dev/sda is a position in a queue,
# not an identity: unplug something, replug it, and the letter moves. So the
# target is named by what is written on the drive, and anything that is not on
# the USB bus is refused outright.
set -euo pipefail

# This writes to a raw block device, so it refuses to run anywhere it was not
# meant to. Today it would fail on macOS anyway - no lsblk, no /dev/sda - but
# that is luck rather than intent, and the cost of being wrong here is somebody
# else's disk. Being explicit means the protection cannot quietly evaporate
# because a tool got installed.
[[ "$(uname -s)" == "Linux" ]] || {
  echo "flash-linux.sh only runs on Linux. On macOS use: just flash <image>" >&2
  exit 1
}

ISO="${1:-}"
WANT="${2:-Portable SSD T5}"

[[ -f "$ISO" ]] || { echo "usage: flash-linux.sh <image.iso> [\"Media Model\"]"; exit 1; }

# --- find every USB disk whose model matches --------------------------------
# The model is last on purpose. `read a b c` puts everything after the second
# word into c, so with NAME,MODEL,TRAN a multi-word model like "Samsung
# Portable SSD T5" swallows the bus field and nothing ever matches - which is
# exactly what happened, and the script correctly refused to guess rather than
# picking a disk.
matches=()
while read -r name tran model; do
  [[ "$tran" == "usb" ]] || continue
  [[ "$model" == *"$WANT"* ]] || continue
  matches+=("/dev/$name")
done < <(lsblk -dno NAME,TRAN,MODEL)

# Deliberately the bus, not the "removable" flag. A Samsung T5 reports
# removable=0 - it is an SSD in a box, not a memory stick - so the obvious
# check refuses the only correct target and would push someone towards
# picking a device letter by hand, which is exactly how the wrong disk gets
# erased.
if [[ ${#matches[@]} -eq 0 ]]; then
  echo "no USB disk matching \"$WANT\". What is attached:"
  lsblk -dno NAME,SIZE,TRAN,MODEL | sed 's/^/  /'
  exit 1
fi
if [[ ${#matches[@]} -gt 1 ]]; then
  echo "more than one disk matches \"$WANT\": ${matches[*]}"
  echo "unplug one, or pass a more specific name"
  exit 1
fi

target="${matches[0]}"
size=$(lsblk -dno SIZE "$target")
model=$(lsblk -dno MODEL "$target")

# The root filesystem's disk, whatever it is called today. Being on the USB
# bus should already have excluded it, but the cost of being wrong here is the
# machine, so it is checked rather than assumed.
# The subvolume has to be stripped first. On btrfs `findmnt -no SOURCE /`
# answers /dev/nvme0n1p2[/@root], which lsblk cannot parse - it exits 32, and
# under set -e that killed the script *inside the safety check*, before
# anything was written. The guard meant to protect this machine was defeated
# by this machine's own disk layout, and reported nothing while doing it.
root_src=$(findmnt -no SOURCE / | sed 's/\[.*\]//')
root_disk=$(lsblk -no PKNAME "$root_src" 2>/dev/null | head -1 || true)
if [[ -n "$root_disk" && "$target" == "/dev/$root_disk" ]]; then
  echo "$target is the disk this system is running from. Refusing."
  exit 1
fi

echo
echo "  image   $ISO ($(du -h "$ISO" | cut -f1))"
echo "  target  $target - $model, $size"
echo
echo "Everything on that drive will be destroyed."
read -rp "Type 'yes' to write it: " answer
[[ "$answer" == "yes" ]] || { echo "nothing written"; exit 1; }

# Unmount anything that got automounted, or dd writes underneath a mounted
# filesystem and the kernel keeps serving the old contents from cache.
# `[[ ... ]] && { ... }` would be wrong here: as the last statement in the loop
# body it returns non-zero whenever the partition is not mounted, and set -e
# then kills the script - which it did, with exit 32 and no output at all,
# looking exactly like a umount failure.
for part in $(lsblk -lno NAME "$target" | tail -n +2); do
  mountpoint=$(findmnt -no TARGET "/dev/$part" 2>/dev/null || true)
  if [[ -n "$mountpoint" ]]; then
    echo "  unmounting /dev/$part from $mountpoint"
    sudo umount "/dev/$part"
  fi
done

echo "==> writing"
sudo dd if="$ISO" of="$target" bs=4M status=progress conv=fsync
sudo sync
echo "==> done - $target is bootable"
