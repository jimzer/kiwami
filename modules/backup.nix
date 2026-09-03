# /persist, to an S3-compatible bucket, with restic.
#
# The machine is declarative, so the only irreplaceable state is what
# kiwami.persist declares. That makes /persist the whole backup target and
# means there are no per-directory policies to drift: one list answers "what
# survives a reboot", "what survives the disk dying", and "what is `kiwami
# doctor` checking for gaps".
#
# The credentials are deliberately plain on disk. Encrypting them buys very
# little - whatever decrypts them at runtime is what an attacker would be
# running as - and the disk is the right place to solve at-rest exposure.
# What does help is a bucket lock at the far end, so a compromised machine
# cannot delete the backups it is allowed to write.
{ config, lib, pkgs, ... }:

let
  cfg = config.kiwami.backup;
in
{
  config = lib.mkIf cfg.enable {
    assertions = [{
      assertion = cfg.repository != "";
      message = "kiwami.backup.enable is on but kiwami.backup.repository is empty.";
    }];

    environment.systemPackages = [ pkgs.restic ];

    # The credentials outlive a wipe of the root, like everything else that
    # cannot be regenerated from the flake.
    kiwami.persist.directories = [ (builtins.dirOf cfg.credentialsFile) ];

    systemd.services.kiwami-backup = {
      description = "Back /persist up with restic";
      # Not wantedBy: the timer starts it. Running at boot would compete with
      # the desktop coming up for no benefit.
      serviceConfig = {
        Type = "oneshot";
        EnvironmentFile = cfg.credentialsFile;
        # Read-only for everything except restic's own cache: a backup job has
        # no business being able to modify what it is reading.
        ProtectSystem = "strict";
        ReadWritePaths = [ "/var/cache/restic" ];
        CacheDirectory = "restic";
        Nice = 10;
        IOSchedulingClass = "idle";
      };
      path = [ pkgs.restic ];
      script = ''
        set -euo pipefail

        restic snapshots >/dev/null 2>&1 || {
          echo "no repository at ${cfg.repository} - run: sudo kiwami backup setup"
          exit 1
        }

        restic backup /persist \
          --tag kiwami \
          --exclude-caches \
          --exclude-if-present .nobackup \
          ${lib.concatMapStringsSep " " (e: "--exclude '${e}'") cfg.exclude}

        # Forget is cheap; prune rewrites packs and is the expensive operation
        # against object storage, so it runs on the first of the month rather
        # than after every backup.
        restic forget \
          ${lib.concatStringsSep " "
            (lib.mapAttrsToList (k: v: "--keep-${k} ${toString v}") cfg.keep)} \
          $([ "$(date +%d)" = "01" ] && echo --prune || true)
      '';
    };

    systemd.timers.kiwami-backup = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.schedule;
        # A laptop is asleep at 03:00 more often than not.
        Persistent = true;
        RandomizedDelaySec = "15m";
      };
    };
  };
}
