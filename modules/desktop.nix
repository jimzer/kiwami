# Hyprland session. Shared by the VM and (later) real hardware.
{ pkgs, lib, ... }:

{
  programs.hyprland = {
    enable = true;
    # UWSM wraps the compositor in a real systemd user session: it imports the
    # environment, then activates graphical-session-pre -> graphical-session ->
    # xdg-desktop-autostart, and unwinds them on logout. Without it
    # graphical-session.target never activates and any user unit bound to it
    # silently never starts.
    withUWSM = true;
  };

  # withUWSM only flips programs.uwsm.enable; the compositor still has to be
  # registered so UWSM knows what to launch.
  programs.uwsm.waylandCompositors.hyprland = {
    prettyName = "Hyprland";
    comment = "Hyprland, managed by UWSM";
    binPath = "/run/current-system/sw/bin/Hyprland";
  };

  # Autologin straight into Hyprland: the VM must reach a desktop with no
  # interaction so the agent harness can screenshot it.
  #
  # Launched through UWSM rather than the Hyprland binary (or start-hyprland),
  # so the session gets its systemd targets. This mirrors the Exec= line the
  # uwsm module writes into its own wayland-session desktop entry.
  services.greetd = {
    enable = true;
    settings.initial_session = {
      command = "${pkgs.uwsm}/bin/uwsm start -F -- /run/current-system/sw/bin/Hyprland";
      user = "nixos";
    };
    settings.default_session = {
      command = "${pkgs.uwsm}/bin/uwsm start -F -- /run/current-system/sw/bin/Hyprland";
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
