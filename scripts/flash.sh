#!/usr/bin/env bash
# Write an image to a removable drive, on macOS.
#
# `dd` has no idea what it is pointing at. /dev/disk9 is a position in a queue,
# not an identity: unplug something, replug it, and the number moves. The
# installer refuses to work that way for the same reason, so neither does this.
#
# The target is named by what is written on the drive, not by its number, and
# anything internal or non-removable is refused outright.
set -euo pipefail

ISO="${1:-}"
WANT="${2:-Portable SSD T5}"

[[ -f "$ISO" ]] || { echo "usage: flash.sh <image.iso> [\"Media Name\"]"; exit 1; }

# --- find every external, physical disk whose media name matches ------------
matches=()
while read -r node; do
  info=$(diskutil info "$node" 2>/dev/null) || continue
  name=$(sed -n 's/^ *Device \/ Media Name: *//p' <<<"$info")
  # Not every macOS version prints an "Internal:" line - this one does not,
  # and reading a field that is absent silently yields "", which compared
  # unequal to "No" and refused the only correct target. Ask for the field
  # that is actually there, and require it to say External.
  location=$(sed -n 's/^ *Device Location: *//p' <<<"$info" | tr -d ' ')
  internal=$(sed -n 's/^ *Internal: *//p' <<<"$info" | tr -d ' ')
  protocol=$(sed -n 's/^ *Protocol: *//p' <<<"$info")
  [[ "$name" == *"$WANT"* ]] || continue
  # Belt and braces: the name could match something soldered inside.
  [[ "$location" == "External" || "$internal" == "No" ]] \
    || { echo "refusing $node: diskutil does not call it external (location=${location:-unset}, internal=${internal:-unset})"; exit 1; }
  [[ "$protocol" == "USB" || "$protocol" == "Thunderbolt" ]] \
    || { echo "refusing $node: protocol is $protocol, not an external bus"; exit 1; }
  matches+=("$node")
done < <(diskutil list | sed -n 's|^/dev/\(disk[0-9]*\) (external, physical):|/dev/\1|p')

if [[ ${#matches[@]} -eq 0 ]]; then
  echo "no external disk matching \"$WANT\" is attached."
  echo "Attached external disks:"
  diskutil list | grep -E '^/dev/disk[0-9]+ \(external' || echo "  (none)"
  exit 1
fi
# Two drives with the same name is precisely when a wrong guess goes unnoticed.
if [[ ${#matches[@]} -gt 1 ]]; then
  echo "more than one disk matches \"$WANT\": ${matches[*]}"
  echo "Unplug the one you do not mean, or pass a more specific name."
  exit 1
fi

DEV="${matches[0]}"
# Just the human part: diskutil appends the byte count and the 512-byte unit
# count, which buries the one number you are checking.
SIZE=$(diskutil info "$DEV" | sed -n 's/^ *Disk Size: *//p' | sed 's/ (.*//')
NAME=$(diskutil info "$DEV" | sed -n 's/^ *Device \/ Media Name: *//p')

echo
printf '  image:   %s  (%s)\n' "$(basename "$ISO")" "$(du -h "$ISO" | cut -f1 | tr -d ' ')"
printf '  target:  %s  -  %s  -  %s\n' "$DEV" "$NAME" "$SIZE"
echo
echo "Everything on it will be destroyed. Current partitions:"
diskutil list "$DEV" | tail -n +2 | sed 's/^/    /'
echo
# The size goes in the prompt itself, not only in the summary above it. The
# last thing read before committing should identify the drive - a 500 GB
# reading when you expected 1 TB means you are looking at a different disk.
read -r -p "Type 'yes' to erase $DEV ($NAME, $SIZE): " answer
[[ "$answer" == "yes" ]] || { echo "cancelled; nothing was written"; exit 1; }

diskutil unmountDisk "$DEV"
# The raw node is roughly an order of magnitude faster. BSD dd has no
# status=progress; press ctrl-T to see how far along it is.
echo "writing (ctrl-T for progress)..."
sudo dd if="$ISO" of="${DEV/disk/rdisk}" bs=4m
diskutil eject "$DEV"
echo "done - macOS will say the disk is unreadable, which is correct. Ignore it."
