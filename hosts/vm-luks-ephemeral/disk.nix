# An encrypted disk whose root is also wiped at every boot.
#
# The two features were built separately and never ran together, which hid a
# real defect: the rollback runs in the initrd and mounted the root partition
# by name, so on an encrypted machine it would have been handed a LUKS
# container to mount as btrfs. That fails in the initrd, where there is no
# shell to debug from, and the machine lands in emergency mode on the first
# boot after installing - the most expensive moment to discover anything.
#
# This host exists so the combination is exercised rather than assumed.
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
            type = "luks";
            name = "cryptroot";
            settings.allowDiscards = true;
            # Unattended, like the other test hosts: the passphrase comes from
            # a file the harness writes onto the installer's tmpfs. That a real
            # machine is prompted for it, and comes up, is what the luks test
            # covers - this one is about what happens after it is unlocked.
            passwordFile = "/tmp/luks.key";

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
              # this is the one moment @root is empty: disko has just created
              # it and nixos-install has not written to it yet.
              postCreateHook = ''
                MNTPOINT=$(mktemp -d)
                # $device is a shell variable disko exports into hook scripts.
                # Inside a LUKS container it is /dev/mapper/cryptroot, which is
                # exactly why kiwami.rootDevice has to be set to match.
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
}
