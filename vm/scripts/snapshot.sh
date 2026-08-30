#!/usr/bin/env bash
# Manage dev-VM disk snapshots. VM must be stopped.
#   snapshot.sh list
#   snapshot.sh save <tag>
#   snapshot.sh restore <tag>
set -euo pipefail
DISK="$(cd "$(dirname "$0")/.." && pwd)/disks/kiwami.qcow2"
if pgrep -f qemu-system-aarch64 >/dev/null && [[ "${1:-list}" != "list" ]]; then
  echo "!! VM is running - stop it first" >&2; exit 1
fi
case "${1:-list}" in
  list)    qemu-img snapshot -l -U "$DISK" ;;
  save)    qemu-img snapshot -c "$2" "$DISK" && echo "saved: $2" ;;
  restore) qemu-img snapshot -a "$2" "$DISK" && echo "restored: $2" ;;
  *)       echo "usage: snapshot.sh {list|save <tag>|restore <tag>}" >&2; exit 1 ;;
esac
