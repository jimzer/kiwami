# Hyprland session. Shared by the VM and (later) real hardware.
{ pkgs, lib, ... }:

{
  programs.hyprland.enable = true;

  # Autologin straight into Hyprland: the VM must reach a desktop with no
  # interaction so the agent harness can screenshot it.
  services.greetd = {
    enable = true;
    settings.initial_session = {
      command = "${pkgs.hyprland}/bin/Hyprland";
      user = "nixos";
    };
    settings.default_session = {
      command = "${pkgs.hyprland}/bin/Hyprland";
      user = "nixos";
    };
  };

  environment.systemPackages = with pkgs; [
    kitty
    wl-clipboard
    grim
    slurp
  ];

  fonts.packages = with pkgs; [
    nerd-fonts.jetbrains-mono
    noto-fonts
  ];

  security.polkit.enable = true;
  services.dbus.enable = true;
  xdg.portal = {
    enable = true;
    extraPortals = [ pkgs.xdg-desktop-portal-gtk ];
  };
}
