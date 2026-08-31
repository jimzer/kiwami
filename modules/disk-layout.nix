# The disk layout `kiwami install` creates.
#
# Every machine the installer touches gets the same two partitions, so this
# is stated once here rather than repeated in each host. install.rs owns the
# other half of the contract: it labels the ESP "boot" and the root "nixos"
# (mkfs.fat -n / mkfs.ext4 -L), and those labels are what this mounts.
#
# By label, never by UUID. `nixos-generate-config` writes UUIDs, and mkfs
# mints new ones on every reinstall - a stale UUID here does not fail loudly,
# it hangs boot.mount forever waiting for a device that no longer exists.
# Labels survive a reformat, which is why generation is run with
# --no-filesystems and this file supplies the mounts instead.
#
# A host with a different layout - LUKS, btrfs subvolumes, separate /home -
# simply does not import this file.
{ ... }:

{
  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
  };

  fileSystems."/boot" = {
    device = "/dev/disk/by-label/boot";
    fsType = "vfat";
    options = [ "fmask=0077" "dmask=0077" ];
  };

  swapDevices = [ ];
}
