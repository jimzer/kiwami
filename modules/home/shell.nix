# The Kiwami desktop shell (Quickshell), as a systemd user service.
#
# Why a unit rather than exec-ing it from Hyprland: Restart=always, real journal
# logs, and `systemctl --user restart kiwami-shell` as a clean restart to pair
# with the disabled file watcher. See docs/session-services.md.
{ config, pkgs, lib, ... }:

let
  # nixpkgs' quickshell (0.3.0) is in the binary cache for aarch64; the upstream
  # flake input is 0.3.1 but uncached, which means compiling Qt in the VM on
  # every version bump. flake.lock pins nixpkgs, so this is still pinned - we
  # only give up tracking master. Switch to
  # `inputs.quickshell.packages.${pkgs.system}.default` when we need newer.
  quickshell = pkgs.quickshell;

  # The shell tree lives in the working copy so edits are live.
  shellDir = "%h/kiwami/shell";
in
{
  home.packages = [ quickshell ];

  systemd.user.services.kiwami-shell = {
    Unit = {
      Description = "Kiwami desktop shell (Quickshell)";
      # Ordering only - see ConditionEnvironment below for the actual gate.
      After = [ "graphical-session.target" ];
      # Stop when the session ends rather than linger on a dead compositor.
      PartOf = [ "graphical-session.target" ];
      # Without this, a rebuild over SSH starts the shell in a user manager
      # with no compositor. It would not crash - it would sit there active and
      # useless, and the later graphical login would not replace it.
      ConditionEnvironment = "WAYLAND_DISPLAY";
    };

    Service = {
      # `just vm push` does rm -rf + extract, so a file watcher would fire
      # mid-write and reload against a half-written tree. Restart deliberately.
      Environment = [ "QS_DISABLE_FILE_WATCHER=1" ];
      ExecStart = "${lib.getExe quickshell} -p ${shellDir}";
      Restart = "always";
      RestartSec = 2;
    };

    Install.WantedBy = [ "graphical-session.target" ];
  };
}
