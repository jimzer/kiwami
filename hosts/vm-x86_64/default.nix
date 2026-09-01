# x86_64 QEMU guest. Same desktop as the aarch64 dev VM, different
# architecture, so CI catches anything that only breaks on x86_64.
#
# Nothing runs this interactively; it exists to be built and booted in CI.
{ pkgs, ... }:

{
  imports = [
    ./hardware.nix
    ./disk.nix
  ];

  home-manager.users.nixos = {
    imports = [
      ../../modules/home/configs.nix
      ../../modules/home/shell.nix
    ];
    home.stateVersion = "26.05";
  };

  # The harness drives this machine over ssh and serial; there is nobody to
  # type a password at a greeter.
  kiwami.autoLogin = true;

  networking.hostName = "kiwami-vm-x86";

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  boot.kernelParams = [ "console=tty0" "console=ttyS0,115200" ];

  services.qemuGuest.enable = true;
  environment.systemPackages = [ pkgs.efibootmgr ];

  users.users.nixos.initialPassword = "kiwami";
  users.users.root.initialPassword = "kiwami";

  system.stateVersion = "26.05";
}
