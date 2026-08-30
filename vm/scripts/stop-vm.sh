#!/usr/bin/env bash
# Stop the dev VM (graceful if possible).
DIR="$(cd "$(dirname "$0")" && pwd)"
pgrep -f qemu-system-aarch64 >/dev/null || { echo "not running"; exit 0; }
"$DIR/vmssh" 'sudo poweroff' >/dev/null 2>&1 || true
for _ in $(seq 1 10); do
  sleep 1
  pgrep -f qemu-system-aarch64 >/dev/null || { echo "stopped"; exit 0; }
done
pkill -f qemu-system-aarch64 2>/dev/null || true
sleep 1
echo "stopped (forced)"
