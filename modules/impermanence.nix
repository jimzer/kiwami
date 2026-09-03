# An ephemeral root: wiped at every boot, with declared state bound back over
# it from a subvolume that is not wiped.
#
# The point is that untracked state cannot accumulate. NixOS guarantees cover
# /nix/store; /etc and /var are ordinary mutable directories that nothing
# garbage-collects, so a service removed from the config leaves its state
# behind forever and nothing mentions it. Wiping by default inverts that: what
# survives is what somebody named.
#
# Only active when kiwami.ephemeralRoot is set, which requires a disk layout
# with the right subvolumes - see hosts/vm-ephemeral/disk.nix.
{ config, lib, pkgs, inputs, ... }:

let
  cfg = config.kiwami;
in
{
  imports = [ inputs.impermanence.nixosModules.impermanence ];

  config = lib.mkIf cfg.ephemeralRoot {
    # Everything kiwami.persist declares, bound back from /persist. The list
    # is the same one `kiwami doctor` reports against, so what gets kept and
    # what gets checked cannot drift apart.
    environment.persistence."/persist" = {
      hideMounts = true;
      directories = cfg.persist.directories;
      files = cfg.persist.files;

      # Home is wiped with the root now, so anything under it that matters has
      # to be named. impermanence stores these in /persist/home/<user> and
      # restores ownership, which is the part that is tedious to hand-roll.
      users.${cfg.user} = {
        directories = cfg.persist.userDirectories;
        files = cfg.persist.userFiles;
      };
    };

    # /persist and /nix must be mounted before anything tries to bind out of
    # them, and neither is the root, so they need to be there early.
    fileSystems."/persist".neededForBoot = true;

    # Roll the root subvolume back to the blank snapshot taken at install.
    #
    # In the initrd, because a subvolume cannot be deleted while it is the one
    # you are running from. systemd initrd is the default here, so this is a
    # unit rather than the older postDeviceCommands hook, which is silently
    # ignored under systemd.
    # btrfs, explicitly. A systemd initrd carries a deliberately small set of
    # binaries, and a rollback that cannot find its tools fails in the one
    # place with no shell to debug from - the machine lands in emergency mode
    # with the journal on the root that did not mount.
    boot.initrd.systemd.extraBin = {
      btrfs = "${pkgs.btrfs-progs}/bin/btrfs";
    };

    boot.initrd.systemd.services.rollback = {
      description = "Roll the root subvolume back to a blank snapshot";
      wantedBy = [ "initrd.target" ];
      after = [ "dev-disk-by\\x2dpartlabel-disk\\x2dsystem\\x2droot.device" ];
      requires = [ "dev-disk-by\\x2dpartlabel-disk\\x2dsystem\\x2droot.device" ];
      before = [ "sysroot.mount" ];
      unitConfig.DefaultDependencies = "no";
      serviceConfig.Type = "oneshot";
      script = ''
        set -eu

        # Progress goes to the console on purpose. This runs before there is
        # anywhere to write a log that would survive the boot it is part of.
        echo "rollback: mounting the btrfs top level"
        mkdir -p /mnt-btrfs
        mount -t btrfs -o subvol=/ /dev/disk/by-partlabel/disk-system-root /mnt-btrfs

        # Keep exactly one previous root, so "what did I forget to persist" is
        # a diff against a real filesystem rather than a guess. Only one,
        # because naming several needs date and stat - and those are not in a
        # systemd initrd, which is what broke the first attempt.
        if [ -e /mnt-btrfs/@root-old ]; then
          echo "rollback: deleting the previous old root"
          btrfs subvolume list -o /mnt-btrfs/@root-old | cut -f9 -d' ' | while read -r sub; do
            btrfs subvolume delete "/mnt-btrfs/$sub" || true
          done
          btrfs subvolume delete /mnt-btrfs/@root-old
        fi

        if [ -e /mnt-btrfs/@root ]; then
          echo "rollback: setting the outgoing root aside as @root-old"
          mv /mnt-btrfs/@root /mnt-btrfs/@root-old
        fi

        echo "rollback: restoring @root from @root-blank"
        btrfs subvolume snapshot /mnt-btrfs/@root-blank /mnt-btrfs/@root

        umount /mnt-btrfs
        echo "rollback: done"
      '';
    };
  };
}
