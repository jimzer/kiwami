# Disk layout for the aarch64 dev VM.
#
# One declaration, two uses: `disko --mode disko` formats from it, and the
# module derives fileSystems from the same tree. That replaces a contract
# previously kept in sync by hand between install.rs and a fileSystems module,
# where a mismatch failed in the initrd rather than at eval.
#
# By stable id, not /dev/vda: kernel names follow enumeration order, so adding
# a disk can silently point this at the wrong one. run-vm.sh gives the guest
# disks serials so the VM exercises the same path as real hardware.
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
