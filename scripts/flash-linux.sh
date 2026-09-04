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

ISO="${1:-}"
WANT="${2:-Portable SSD T5}"

[[ -f "$ISO" ]] || { echo "usage: flash-linux.sh <image.iso> [\"Media Model\"]"; exit 1; }

# --- find every USB disk whose model matches --------------------------------
matches=()
while read -r name model tran; do
  [[ "$tran" == "usb" ]] || continue
  [[ "$model" == *"$WANT"* ]] || continue
  matches+=("/dev/$name")
done < <(lsblk -dno NAME,MODEL,TRAN | awk '{name=$1; tran=$NF; $1=""; $NF=""; sub(/^ +/,""); sub(/ +$/,""); print name, $0, tran}')

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
root_disk=$(lsblk -no PKNAME "$(findmnt -no SOURCE /)" 2>/dev/null | head -1)
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
for part in $(lsblk -lno NAME "$target" | tail -n +2); do
  mountpoint=$(findmnt -no TARGET "/dev/$part" 2>/dev/null || true)
  [[ -n "$mountpoint" ]] && { echo "  unmounting /dev/$part"; sudo umount "/dev/$part"; }
done

echo "==> writing"
sudo dd if="$ISO" of="$target" bs=4M status=progress conv=fsync
sudo sync
echo "==> done - $target is bootable"
