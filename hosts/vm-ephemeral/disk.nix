# Ephemeral-root layout: one btrfs partition, four subvolumes.
#
# Subvolumes rather than partitions because sizes stay shared - deciding now
# how much of the disk /nix will ever want is a guess you get to live with -
# and because a subvolume can be snapshotted and rolled back on its own, which
# is the whole mechanism.
#
#   @root      /          deleted and recreated blank at every boot
#   @nix       /nix       the store; wiping it would leave no system at all
#   @persist   /persist   everything that survives, bound back over /
#
# No @home. Home lives on the ephemeral root and is wiped with it; the paths
# worth keeping are declared and land in /persist/home/<user>, which is where
# impermanence puts them without being asked. A separate home subvolume would
# only buy independent snapshots or quotas, and snapshotting /persist covers
# home anyway - it is where the home survivors live.
{ ... }:

{
  disko.devices.disk.system = {
    type = "disk";
    device = "/dev/disk/by-id/virtio-kiwami-root";
    content = {
      type = "gpt";
      partitions = {
        ESP = {
          size = "1G";
          type = "EF00";
          content = {
            type = "filesystem";
            format = "vfat";
            mountpoint = "/boot";
            mountOptions = [ "umask=0077" ];
          };
        };
        root = {
          size = "100%";
          content = {
            type = "btrfs";
            extraArgs = [ "-f" ];
            subvolumes = {
              "@root" = {
                mountpoint = "/";
                mountOptions = [ "compress=zstd" "noatime" ];
              };
              "@nix" = {
                mountpoint = "/nix";
                mountOptions = [ "compress=zstd" "noatime" ];
              };
              "@persist" = {
                mountpoint = "/persist";
                mountOptions = [ "compress=zstd" "noatime" ];
              };
            };

            # The blank snapshot the initrd restores from, taken here because
            # this is the one moment @root is empty: disko has just created it
            # and nixos-install has not written to it yet. Taken any later and
            # "blank" would contain a whole installed system.
            postCreateHook = ''
              MNTPOINT=$(mktemp -d)
              # $device is a shell variable disko exports into hook scripts,
              # not Nix interpolation - the content submodule's config is not
              # in scope here.
              mount "$device" "$MNTPOINT" -o subvol=/
              trap 'umount "$MNTPOINT"; rm -rf "$MNTPOINT"' EXIT
              btrfs subvolume snapshot -r "$MNTPOINT/@root" "$MNTPOINT/@root-blank"
            '';
          };
        };
      };
    };
  };
}
