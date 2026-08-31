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
# Scratch disks for the installer test matrix. Off by default: they only exist
# so `kiwami install` has something realistic to enumerate and refuse.
TEST_DISKS="${TEST_DISKS:-0}"
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
  # Explicit device rather than `if=virtio`, purely so a serial can be set:
  # without one QEMU creates no /dev/disk/by-id/ entry, and the installer
  # writes disko configs by stable id. With the shorthand the VM would be the
  # one machine that never exercises that path.
  -drive "file=$DISK,if=none,id=root0,format=qcow2,discard=unmap"
  -device virtio-blk-pci,drive=root0,serial=kiwami-root
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

if [[ "$TEST_DISKS" == "1" ]]; then
  NVME="$VM_DIR/disks/test-nvme.qcow2"       # empty, valid target
  DIRTY="$VM_DIR/disks/test-dirty.qcow2"     # has partitions already
  SMALL="$VM_DIR/disks/test-small.qcow2"     # below the minimum size
  [[ -f "$NVME"  ]] || qemu-img create -f qcow2 "$NVME" 40G >/dev/null
  [[ -f "$DIRTY" ]] || qemu-img create -f qcow2 "$DIRTY" 40G >/dev/null
  [[ -f "$SMALL" ]] || qemu-img create -f qcow2 "$SMALL" 8G >/dev/null
  args+=(
    -drive "file=$NVME,if=none,id=nvme0,format=qcow2"
    -device nvme,drive=nvme0,serial=kiwami-test-nvme
    -drive "file=$DIRTY,if=none,id=dirty0,format=qcow2"
    -device virtio-blk-pci,drive=dirty0,serial=kiwami-test-dirty
    -drive "file=$SMALL,if=none,id=small0,format=qcow2"
    -device virtio-blk-pci,drive=small0,serial=kiwami-test-small
  )
fi

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
