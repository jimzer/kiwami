# An encrypted machine asks for a passphrase and then comes up.
#
# The one claim evaluation cannot make. `nix eval` will happily tell you the
# LUKS options are set; only a boot tells you the initrd can actually find the
# device, unlock it, and hand a working root to systemd. Getting that wrong
# leaves a machine that builds, switches, and then never boots again - the
# most expensive failure this project can produce, because you find out after
# the disk is already encrypted.
#
# Replaces vm/scripts/luks-test.sh, which did the same thing by driving QEMU
# over a serial socket from macOS.
{ pkgs, inputs, home-manager }:

inputs.disko.lib.testLib.makeDiskoTest {
  inherit pkgs;
  name = "kiwami-luks";

  disko-config = ../hosts/vm-luks/disk.nix;

  extraSystemConfig = {
    _module.args.inputs = inputs;
    imports = [
      home-manager.nixosModules.home-manager
      ../modules/common.nix
      ../modules/options.nix
      ../modules/impermanence.nix
    ];
    kiwami.user = "kiwami";
    home-manager.useGlobalPkgs = true;
    home-manager.useUserPackages = true;
    home-manager.extraSpecialArgs = { inherit inputs; };
    home-manager.users.kiwami.home.stateVersion = "26.05";
    system.stateVersion = "26.05";
  };

  # The passphrase, typed at the prompt the initrd puts on the console. This
  # is the whole point of the test: a keyfile baked into the image would prove
  # nothing about the path a person actually takes.
  bootCommands = ''
    machine.wait_for_console_text("[Pp]assphrase for")
    machine.send_chars("secretsecret\n")
  '';

  extraTestScript = ''
    with subtest("the root is inside the LUKS container"):
        # Not just "it booted": a fallback that quietly mounted an
        # unencrypted partition would also boot, and would look identical
        # from userspace unless you ask what the root is sitting on.
        machine.succeed("findmnt -no SOURCE / | grep -q /dev/mapper/")
        machine.succeed("cryptsetup status cryptroot | grep -q 'type:.*LUKS'")

    with subtest("the encrypted device is the disk, not a file"):
        machine.succeed("cryptsetup status cryptroot | grep -q 'device:.*/dev/'")
  '';
}
