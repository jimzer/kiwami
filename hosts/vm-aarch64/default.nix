# The aarch64 development VM that runs on the Mac under QEMU/HVF.
{ pkgs, ... }:

{
  imports = [
    ./hardware-configuration.nix
    ../../modules/common.nix
    ../../modules/desktop.nix
  ];

  # Home Manager: package layer and dotfile links only, per the design note.
  home-manager.users.nixos = {
    imports = [ ../../modules/home/hyprland.nix ];
    home.stateVersion = "26.05";
  };

  networking.hostName = "kiwami-vm";

  boot.loader.systemd-boot.enable = true;
  # Must be true, or systemd-boot never registers an NVRAM entry and the
  # firmware drops to the EFI shell instead of booting. See vm/README.md.
  boot.loader.efi.canTouchEfiVariables = true;

  # Keep the serial console after install so the agent harness can drive the
  # machine with no graphical session.
  boot.kernelParams = [ "console=tty0" "console=ttyAMA0,115200" ];

  services.qemuGuest.enable = true;
  environment.systemPackages = [ pkgs.efibootmgr ];

  # Throwaway guest credentials. These must never appear on a real host.
  users.users.nixos.initialPassword = "kiwami";
  users.users.root.initialPassword = "kiwami";
  services.openssh.settings.PermitRootLogin = "yes";

  system.stateVersion = "26.05";
}
