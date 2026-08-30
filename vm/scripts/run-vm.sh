#!/usr/bin/env bash
# Launch the Kiwami dev VM (aarch64 NixOS, HVF-accelerated).
#
#   ./run-vm.sh install        boot the ISO to install onto the disk
#   ./run-vm.sh run            boot the installed disk
#   ./run-vm.sh install gui    same, but with a cocoa window for human use
set -euo pipefail

VM_DIR="$(cd "$(dirname "$0")/.." && pwd)"
QEMU_SHARE="$(brew --prefix)/share/qemu"

ISO="${ISO:-$VM_DIR/iso/nixos-minimal-26.05-aarch64.iso}"
DISK="${DISK:-$VM_DIR/disks/kiwami.qcow2}"
VARS="$VM_DIR/disks/edk2-vars.fd"
QMP_SOCK="${QMP_SOCK:-/tmp/kiwami-qmp.sock}"
SERIAL_LOG="$VM_DIR/serial.log"
SERIAL_SOCK="${SERIAL_SOCK:-/tmp/kiwami-serial.sock}"
DISK_SIZE="${DISK_SIZE:-40G}"
MEM="${MEM:-8G}"
CPUS="${CPUS:-6}"
SSH_PORT="${SSH_PORT:-2222}"

MODE="${1:-run}"
DISPLAY_MODE="${2:-headless}"

[[ -f "$DISK" ]] || { echo ">> creating disk $DISK ($DISK_SIZE)"; qemu-img create -f qcow2 "$DISK" "$DISK_SIZE" >/dev/null; }
[[ -f "$VARS" ]] || { echo ">> seeding UEFI vars"; cp "$QEMU_SHARE/edk2-arm-vars.fd" "$VARS"; }
rm -f "$QMP_SOCK" "$SERIAL_SOCK"

args=(
  -M virt -cpu host -accel hvf
  -smp "$CPUS" -m "$MEM"
  -drive "if=pflash,format=raw,readonly=on,file=$QEMU_SHARE/edk2-aarch64-code.fd"
  -drive "if=pflash,format=raw,file=$VARS"
  -drive "file=$DISK,if=virtio,format=qcow2,discard=unmap"
  -device virtio-gpu-pci
  # A sound card with no host output: the guest gets a real PipeWire sink so
  # the volume OSD is testable, without QEMU grabbing the Mac's audio.
  -audiodev none,id=snd0
  -device intel-hda
  -device hda-duplex,audiodev=snd0
  -device qemu-xhci -device usb-kbd -device usb-tablet
  -netdev "user,id=n0,hostfwd=tcp::${SSH_PORT}-:22"
  -device virtio-net-pci,netdev=n0
  -qmp "unix:$QMP_SOCK,server,nowait"
  -chardev "socket,id=ser0,path=$SERIAL_SOCK,server=on,wait=off,logfile=$SERIAL_LOG"
  -serial chardev:ser0
  -rtc base=utc
)

if [[ "$MODE" == "install" ]]; then
  [[ -f "$ISO" ]] || { echo "!! ISO not found: $ISO" >&2; exit 1; }
  args+=(
    -device virtio-scsi-pci,id=scsi0
    -drive "file=$ISO,id=cd0,if=none,media=cdrom,format=raw,readonly=on"
    -device scsi-cd,drive=cd0,bus=scsi0.0,bootindex=0
  )
fi

case "$DISPLAY_MODE" in
  gui)      args+=(-display cocoa) ;;
  vnc)      args+=(-display none -vnc 127.0.0.1:1) ;;
  *)        args+=(-display none) ;;
esac

echo ">> mode=$MODE display=$DISPLAY_MODE qmp=$QMP_SOCK serial=$SERIAL_SOCK ssh=localhost:$SSH_PORT"
exec qemu-system-aarch64 "${args[@]}"
