# Hardware facts for an x86_64 QEMU guest.
#
# Exists so CI has something x86_64 to build and boot: the dev VM is aarch64,
# so without this nothing ever exercises the architecture real hardware uses.
#
# Written in the shape `nixos-generate-config --show-hardware-config
# --no-filesystems` produces, but by hand: no x86_64 guest is ever installed
# interactively, so there is no run to capture it from. `kiwami doctor` will
# report formatting drift if anyone ever does - see hosts/vm-aarch64.
{ config, lib, pkgs, modulesPath, ... }:

{
  imports =
    [ (modulesPath + "/profiles/qemu-guest.nix")
    ];

  boot.initrd.availableKernelModules = [ "ahci" "xhci_pci" "virtio_pci" "virtio_scsi" "sd_mod" "sr_mod" ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ "kvm-intel" "kvm-amd" ];
  boot.extraModulePackages = [ ];

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
}
