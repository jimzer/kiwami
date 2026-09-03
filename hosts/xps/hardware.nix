# Hardware facts for this machine, detected by `kiwami install`.
#
# Generated with --show-hardware-config --no-filesystems, so it carries no
# UUIDs: the mounts are derived from disk.nix and survive a reformat.
#
# Do not edit by hand. `kiwami doctor` compares this against what the machine
# currently reports; regenerate with `kiwami install --regen-hardware`, or:
#   nixos-generate-config --show-hardware-config --no-filesystems
#
# Choices - hostname, users, monitors - belong in default.nix beside this.
{ config, lib, pkgs, modulesPath, ... }:

{
  imports =
    [ (modulesPath + "/installer/scan/not-detected.nix")
    ];

  boot.initrd.availableKernelModules = [ "xhci_pci" "nvme" "uas" "sd_mod" "rtsx_pci_sdmmc" ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ "kvm-intel" ];
  boot.extraModulePackages = [ ];

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  hardware.cpu.intel.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
}
