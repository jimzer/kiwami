# Hardware facts for the aarch64 QEMU dev VM.
#
# The body is verbatim `nixos-generate-config --show-hardware-config
# --no-filesystems` output captured from the running guest, so it is exactly
# the shape `kiwami install` writes for a real machine - which is what lets
# `kiwami doctor` diff facts rather than formatting.
#
# No fileSystems and no UUIDs: the mounts come from modules/disk-layout.nix,
# which is why `just vm install` can reformat the disk without invalidating
# this file.
#
# Detected modules follow whatever QEMU has attached, so this differs slightly
# from the file an install writes (the ISO has a CD-ROM; `just vm
# start-test-disks` adds an NVMe controller). Extra modules are harmless.
{ config, lib, pkgs, modulesPath, ... }:

{
  imports =
    [ (modulesPath + "/profiles/qemu-guest.nix")
    ];

  boot.initrd.availableKernelModules = [ "xhci_pci" "virtio_pci" "usbhid" ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ ];
  boot.extraModulePackages = [ ];

  nixpkgs.hostPlatform = lib.mkDefault "aarch64-linux";
}
