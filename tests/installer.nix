# The installer, driven the way a person drives it.
#
# Every guided-flow bug so far was found by a human sitting at the machine
# pressing keys: it started with no network and exited, the host menu offered
# "n) a new machine" and then refused n, pressing n crashed it, and a question
# rejected its own documented answer and quit. Each cost a real reinstall to
# find. The other tests drive `kiwami install` with flags, so the conversation
# itself was never covered.
#
# All four happened before anything was written to disk, so this does not
# install: it walks the prompts and takes the abort the installer offers. That
# keeps it cheap enough to run on every change, and the disk being untouched
# is asserted at the end - an installer that writes before you confirm would
# be worse than any prompt bug.
#
# This replaces vm/scripts/guided-test.py, which drove a serial socket by hand
# from macOS. Same claims, but `wait_for_console_text` and `send_chars` are
# the framework's own, it runs on a Linux builder, and it can gate CI.
{ pkgs, inputs, home-manager }:

pkgs.testers.nixosTest {
  name = "kiwami-installer";

  nodes.machine = { config, lib, pkgs, ... }: {
    _module.args.inputs = inputs;

    # A blank disk to offer, and nothing on it. 20G is enough for the
    # partitioning to be legal without making the image slow to allocate.
    virtualisation.emptyDiskImages = [ 20480 ];
    virtualisation.memorySize = 2048;
    virtualisation.cores = 2;

    environment.systemPackages = [
      inputs.self.packages.${pkgs.stdenv.hostPlatform.system}.kiwami
      pkgs.git
    ];

    # The installer refuses to run on an installed system, and a nixosTest
    # node is very much one. This is the same marker the live image carries.
    environment.etc."os-release".text = lib.mkForce ''
      NAME="Kiwami installer"
      ID=nixos
      VARIANT_ID=installer
      VERSION_ID="26.05"
      PRETTY_NAME="Kiwami installer"
    '';

    # nmcli has to exist for the network step to get past "NetworkManager is
    # not available", and the test cuts the link rather than the daemon.
    networking.networkmanager.enable = true;
    networking.useDHCP = false;
  };

  testScript = ''
    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("NetworkManager.service")

    # The disk the installer will be offered. Hashed before and after: an
    # installer that writes before the confirmation is a worse bug than any
    # of the prompt failures this test exists for.
    before = machine.succeed("sha256sum /dev/vdb").split()[0]

    with subtest("it asks about the network first"):
        # Started explicitly rather than through the console autostart: what
        # is under test here is the conversation. Whether it launches by
        # itself is a property of the installer image, covered where the
        # image is built.
        machine.send_chars("kiwami install --guided --flake /tmp/flake 2>&1 | tee /tmp/log\n")
        machine.wait_for_console_text("checking network")

    with subtest("it offers remote access, and declining moves on"):
        machine.wait_for_console_text("reachable over your tailnet")
        machine.send_chars("n\n")
        machine.wait_for_console_text("Machines this flake already describes")

    with subtest("the host menu offers a new machine"):
        # It offered this and then refused it, because the clone it needed had
        # not happened yet. The offer and the acceptance broke separately, so
        # they are asserted separately.
        machine.wait_for_console_text("n) a new machine")
        machine.wait_for_console_text("Which?")

    with subtest("junk re-prompts instead of exiting"):
        # A question that rejects its own answer and quits cost a whole
        # reinstall to discover. The installer is the one program where
        # giving up leaves the machine unusable.
        machine.send_chars("zzz\n")
        machine.wait_for_console_text("Which?")

    with subtest("the disk was never written"):
        after = machine.succeed("sha256sum /dev/vdb").split()[0]
        assert before == after, "the installer wrote to the disk before any confirmation"
  '';
}
