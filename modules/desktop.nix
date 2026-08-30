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
    hyprlock          # the locker; the shell must never draw its own
    wireplumber       # wpctl, for the volume binds
    brightnessctl     # no backlight in the VM, present for real hardware
    libnotify         # notify-send, and what most apps link against
    wl-clipboard
    grim
    slurp
  ];

  fonts.packages = with pkgs; [
    nerd-fonts.jetbrains-mono
    noto-fonts
  ];

  # Battery and power-profile data for the bar. No battery in the VM, so the
  # widget stays hidden there; this is for real hardware.
  services.upower.enable = true;

  # Themes ship with the system so an installed machine has them without a
  # checkout. `kiwami` still prefers ~/kiwami/config/themes when it exists, so
  # editing a theme live keeps working.
  environment.etc."kiwami/themes".source = ../config/themes;

  # The shell tree ships too, for the same reason: an installed machine has no
  # checkout, and pointing the unit at one made it restart-loop forever.
  environment.etc."kiwami/shell".source = ../shell;

  # Hyprland and Ghostty configs, for the same reason again. This is the third
  # thing that only worked inside a checkout; anything the desktop needs at
  # runtime belongs here, with the working tree as an override.
  environment.etc."kiwami/config".source = ../config;

  security.polkit.enable = true;
  services.dbus.enable = true;
  xdg.portal = {
    enable = true;
    extraPortals = [ pkgs.xdg-desktop-portal-gtk ];
  };
}
