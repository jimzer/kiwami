# Disk layout for this machine, written by `kiwami install`.
#
# One declaration, two uses: disko formats from it, and fileSystems is derived
# from the same tree - so what gets erased and what gets mounted cannot drift
# apart.
#
# Devices are named by id, not /dev/sdX: kernel names follow the order disks
# are found in, so adding a drive can silently repoint this at another one.
#
# No swap partition: zram is used instead - compressed swap in RAM. It
# costs no disk, and can be turned off or joined by a swapfile with a
# rebuild, unlike this file.
#
# Editing this after installing does not repartition anything. It describes a
# disk that already exists.
{ ... }:

{
  disko.devices = {
    disk = {
      system = {
        type = "disk";
        device = "/dev/disk/by-id/nvme-PM981_NVMe_Samsung_512GB__S3ZHNA0M640707";
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
                mountOptions = [
                  "umask=0077"
                ];
              };
            };
            root = {
              size = "100%";
              content = {
                type = "btrfs";
                extraArgs = [
                  "-f"
                ];
                subvolumes = {
                  "@root" = {
                    mountpoint = "/";
                    mountOptions = [
                      "compress=zstd"
                      "noatime"
                    ];
                  };
                  "@nix" = {
                    mountpoint = "/nix";
                    mountOptions = [
                      "compress=zstd"
                      "noatime"
                    ];
                  };
                  # Everything declared is bound out of here, including the home
                  # paths - so this is what to snapshot or back up.
                  "@persist" = {
                    mountpoint = "/persist";
                    mountOptions = [
                      "compress=zstd"
                      "noatime"
                    ];
                  };
                  # Headroom, not hibernation - a second tier under zram for when
                  # cold pages stop compressing well. A file rather than a
                  # partition because nothing here needs a stable resume offset,
                  # and a file can be resized or dropped without repartitioning.
                  # Its own subvolume, uncompressed and never snapshotted, which
                  # is what a swapfile on btrfs requires.
                  "@swap" = {
                    mountpoint = "/swap";
                    mountOptions = [
                      "noatime"
                    ];
                    swap.swapfile.size = "8G";
                  };
                };
                postCreateHook = ''
MNTPOINT=$(mktemp -d)
                 mount "$device" "$MNTPOINT" -o subvol=/
                 trap 'umount "$MNTPOINT"; rm -rf "$MNTPOINT"' EXIT
                 btrfs subvolume snapshot -r "$MNTPOINT/@root" "$MNTPOINT/@root-blank"
          '';
              };
            };
          };
        };
      };
    };
  };
}
