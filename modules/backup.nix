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
      # Before `kiwami snapshot setup` there are no credentials, and the timer
      # firing into that failed loudly every day. Skipping is the honest
      # behaviour: nothing is wrong, it is simply not configured yet.
      unitConfig.ConditionPathExists = cfg.credentialsFile;

      serviceConfig = {
        Type = "oneshot";
        EnvironmentFile = cfg.credentialsFile;
        # Read-only for everything except what restic genuinely writes: a
        # backup job has no business being able to modify what it is reading.
        ProtectSystem = "strict";
        CacheDirectory = "restic";
        # Where the status file is written. Everything else stays read-only:
        # a backup job should not be able to modify what it is reading.
        ReadWritePaths = [ (builtins.dirOf cfg.credentialsFile) ];
        # restic assembles pack files in TMPDIR before uploading them. Under
        # ProtectSystem=strict /tmp is read-only, so the first real backup
        # died on "read-only file system" partway through - after reporting
        # that it had started. PrivateTmp gives it a writable tmpfs of its
        # own, which is also the tidier answer: nothing it writes there
        # outlives the run.
        PrivateTmp = true;
        # And it locates its cache through XDG_CACHE_HOME or HOME, neither of
        # which a system unit has - CacheDirectory alone only creates the
        # directory, it does not tell restic where to look.
        Environment = [ "XDG_CACHE_HOME=/var/cache" ];
        Nice = 10;
        IOSchedulingClass = "idle";
      };
      path = [ pkgs.restic ];
      script = ''
        set -euo pipefail

        # What happened, written down for the bar to read.
        #
        # The widget runs as the desktop user and cannot open the repository -
        # the credentials are root-only, and asking object storage every thirty
        # seconds for a fact that changes once a day would be wrong even if it
        # could. So the job that already knows records the answer, and the
        # widget reads a file: instant, offline, and able to say "the last one
        # failed", which querying the repository could never tell you.
        status=${builtins.dirOf cfg.credentialsFile}/status.json
        record() {
          printf '{"ok":%s,"time":"%s","id":"%s","bytes":%s}\n' \
            "$1" "$(date -Is)" "''${2:-}" "''${3:-0}" > "$status"
          chmod 0644 "$status"
        }
        trap 'record false' ERR

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

        id=$(restic snapshots --tag kiwami --latest 1 --json | ${pkgs.jq}/bin/jq -r '.[0].short_id // ""')
        bytes=$(restic stats latest --mode raw-data --json | ${pkgs.jq}/bin/jq -r '.total_size // 0')
        record true "$id" "$bytes"
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
