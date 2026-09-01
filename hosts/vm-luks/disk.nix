# Encrypted layout for the LUKS install test.
#
# LVM inside LUKS: one encrypted container holding root and swap as logical
# volumes. That is the only arrangement where hibernation and encryption
# coexist safely - the hibernation image is a verbatim copy of RAM, and swap
# beside the container rather than inside it would write it out in the clear.
#
# This is the shape `kiwami install` generates for encrypt + hibernate. It is
# committed so a test can install it unattended.
{ ... }:

{
  disko.devices = {
    disk = {
      system = {
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
                # A real install prompts. This host exists to be installed
                # unattended, so the passphrase comes from a file the test
                # writes onto the installer's tmpfs - it never reaches the
                # installed system, and this host is never used on hardware.
                # Content-level, not under settings: everything in `settings`
                # is forwarded to boot.initrd.luks.devices.<name>, where
                # passwordFile is not an option. This one is used only while
                # formatting.
                passwordFile = "/tmp/luks.key";
                content = {
                  type = "lvm_pv";
                  vg = "pool";
                };
              };
            };
          };
        };
      };
    };
    lvm_vg.pool = {
      type = "lvm_vg";
      lvs = {
        swap = {
          size = "2G";
          content = {
            type = "swap";
            resumeDevice = true;
          };
        };
        root = {
          size = "100%FREE";
          content = {
            type = "filesystem";
            format = "ext4";
            mountpoint = "/";
          };
        };
      };
    };
  };
}
