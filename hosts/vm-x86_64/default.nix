# x86_64 QEMU guest. Same desktop as the aarch64 dev VM, different
# architecture, so CI catches anything that only breaks on x86_64.
{ pkgs, ... }:

{
  imports = [
    ./hardware-configuration.nix
    ../../modules/common.nix
    ../../modules/desktop.nix
  ];

  networking.hostName = "kiwami-vm-x86";

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  boot.kernelParams = [ "console=tty0" "console=ttyS0,115200" ];

  services.qemuGuest.enable = true;
  environment.systemPackages = [ pkgs.efibootmgr ];

  users.users.nixos.initialPassword = "kiwami";
  users.users.root.initialPassword = "kiwami";

  home-manager.users.nixos = {
    imports = [
      ../../modules/home/dotfiles.nix
      ../../modules/home/shell.nix
    ];
    home.stateVersion = "26.05";
  };

  system.stateVersion = "26.05";
}
