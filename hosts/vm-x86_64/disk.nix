# Disk layout for the x86_64 QEMU guest.
#
# Never actually formatted - this host is only ever built and boot-tested in
# CI - but fileSystems has to come from somewhere or the config will not
# evaluate, and deriving it from a disko declaration keeps it identical in
# shape to every machine that is installed for real.
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
            type = "filesystem";
            format = "ext4";
            mountpoint = "/";
          };
        };
      };
    };
  };
}
