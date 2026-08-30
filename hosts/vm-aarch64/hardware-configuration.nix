# Hardware facts for the QEMU dev VM.
#
# Deliberately NOT the verbatim output of nixos-generate-config: that pins
# filesystems by UUID, and `just vm install` reformats the disk, so mkfs
# generates fresh UUIDs every time. A stale UUID here makes boot.mount hang
# forever waiting for a device that no longer exists - and would leave the
# machine unbootable after a reboot.
#
# install.sh sets the labels (mkfs.fat -n boot, mkfs.ext4 -L nixos), so they
# are stable across reinstalls. Real hardware should use the generated UUIDs
# instead; only this throwaway guest gets reformatted on demand.
{ config, lib, pkgs, modulesPath, ... }:

{
  imports = [ (modulesPath + "/profiles/qemu-guest.nix") ];

  boot.initrd.availableKernelModules = [ "xhci_pci" "virtio_pci" "virtio_scsi" "usbhid" "sr_mod" ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ ];
  boot.extraModulePackages = [ ];

  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
  };

  fileSystems."/boot" = {
    device = "/dev/disk/by-label/boot";
    fsType = "vfat";
    options = [ "fmask=0077" "dmask=0077" ];
  };

  swapDevices = [ ];

  nixpkgs.hostPlatform = lib.mkDefault "aarch64-linux";
}
