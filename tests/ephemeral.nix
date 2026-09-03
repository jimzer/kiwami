# The root is wiped at every boot, and only what kiwami.persist declares comes
# back.
#
# The claim is not "it booted". A rollback that silently does nothing also
# boots, and looks perfectly healthy - which is why this writes a marker to /
# and another to /persist and reboots. Exactly one must survive. Both, or
# neither, means the wipe is not doing its job.
#
# Built on disko's own test helper rather than hand-rolled: it partitions from
# the same disk.nix a real machine uses, installs, and boots the result. The
# alternative - the vm/ harness - drove QEMU over a serial socket from macOS
# and could only run on one machine in the world.
{ pkgs, inputs, home-manager }:

inputs.disko.lib.testLib.makeDiskoTest {
  inherit pkgs;
  name = "kiwami-ephemeral";

  # The layout a real ephemeral machine gets, not a copy of it. If the
  # subvolumes or the blank snapshot ever drift, this fails rather than
  # testing a fiction.
  disko-config = ../hosts/vm-ephemeral/disk.nix;

  extraSystemConfig = {
    _module.args.inputs = inputs;
    imports = [
      home-manager.nixosModules.home-manager
      ../modules/common.nix
      ../modules/options.nix
      ../modules/impermanence.nix
    ];
    kiwami.user = "kiwami";
    kiwami.ephemeralRoot = true;
    home-manager.useGlobalPkgs = true;
    home-manager.useUserPackages = true;
    home-manager.extraSpecialArgs = { inherit inputs; };
    home-manager.users.kiwami.home.stateVersion = "26.05";
    system.stateVersion = "26.05";
  };

  extraTestScript = ''
    with subtest("the layout is what disk.nix describes"):
        machine.succeed("findmnt -no FSTYPE / | grep -q btrfs")
        machine.succeed("findmnt -no OPTIONS / | grep -q 'subvol=/@root'")
        machine.succeed("findmnt -no TARGET /persist | grep -q /persist")

    with subtest("declared state is bound out of /persist"):
        # Present is not enough: it has to come from the subvolume that
        # survives, or it is simply a directory on a root about to be erased.
        machine.succeed("findmnt -no SOURCE /var/lib/nixos | grep -q persist")

    with subtest("the blank snapshot the rollback restores from exists"):
        machine.succeed("mkdir -p /tmp/btrfs")
        machine.succeed(
            "mount -o subvol=/ /dev/disk/by-partlabel/disk-system-root /tmp/btrfs"
        )
        machine.succeed("btrfs subvolume show /tmp/btrfs/@root-blank")
        machine.succeed("umount /tmp/btrfs")

    with subtest("one marker survives the reboot and the other does not"):
        machine.succeed("touch /ephemeral-marker")
        machine.succeed("touch /persist/persistent-marker")
        machine.shutdown()
        machine.start()
        machine.wait_for_unit("multi-user.target")

        machine.fail("test -e /ephemeral-marker")
        machine.succeed("test -e /persist/persistent-marker")

    with subtest("and declared state is still bound after the wipe"):
        # The wipe working is only half of it. If the bind mounts do not come
        # back, the machine boots clean and has forgotten its own identity.
        machine.succeed("findmnt -no SOURCE /var/lib/nixos | grep -q persist")
  '';
}
