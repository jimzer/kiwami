#!/usr/bin/env bash
# Start the VM fully detached (own session) so it survives the calling shell.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
MODE="${1:-run}"; DISP="${2:-headless}"
pkill -f qemu-system-aarch64 2>/dev/null || true
sleep 1
rm -f "$DIR/../serial.log"
python3 - "$DIR/run-vm.sh" "$MODE" "$DISP" <<'PY'
import os, sys
if os.fork() == 0:
    os.setsid()
    fd = os.open("/tmp/kiwami-vm.log", os.O_WRONLY | os.O_CREAT | os.O_TRUNC)
    os.dup2(fd, 1); os.dup2(fd, 2)
    os.dup2(os.open("/dev/null", os.O_RDONLY), 0)
    os.execv("/bin/bash", ["bash"] + sys.argv[1:])
PY
sleep 4
pgrep -f qemu-system-aarch64 >/dev/null && echo "VM started ($MODE/$DISP)" || { echo "FAILED"; cat /tmp/kiwami-vm.log; exit 1; }
