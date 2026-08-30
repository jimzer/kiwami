# Hyprland session. Shared by the VM and (later) real hardware.
{ pkgs, lib, ... }:

{
  programs.hyprland.enable = true;

  # Autologin straight into Hyprland: the VM must reach a desktop with no
  # interaction so the agent harness can screenshot it.
  #
  # Launch via start-hyprland, not the Hyprland binary directly. The wrapper
  # sets up the dbus/systemd user session; calling the binary raises
  # "started without start-hyprland" and leaves session services unreliable,
  # which matters as soon as the shell needs the session bus.
  services.greetd = {
    enable = true;
    settings.initial_session = {
      command = "${pkgs.hyprland}/bin/start-hyprland";
      user = "nixos";
    };
    settings.default_session = {
      command = "${pkgs.hyprland}/bin/start-hyprland";
      user = "nixos";
    };
  };

  environment.systemPackages = with pkgs; [
    ghostty
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
