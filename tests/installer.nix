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

    # The installer asks a flake which machines it describes. Doing that
    # offline with the real flake would mean carrying nixpkgs, home-manager,
    # disko and the rest into the VM's store just to read a list of names.
    nix.settings.experimental-features = [ "nix-command" "flakes" ];
  };

  testScript = ''
    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("NetworkManager.service")

    # The disk the installer will be offered. Hashed before and after: an
    # installer that writes before the confirmation is a worse bug than any
    # of the prompt failures this test exists for.
    before = machine.succeed("sha256sum /dev/vdb").split()[0]

    # A flake with no inputs at all. The installer only needs the *names* of
    # the machines it describes at this point, and this test aborts before
    # anything would be built - so a flake that declares two hosts and
    # depends on nothing evaluates offline in milliseconds, where the real
    # one would need its entire input closure copied into the VM.
    machine.succeed("mkdir -p /tmp/flake")
    machine.succeed(
        "cat > /tmp/flake/flake.nix <<'EOF'\n"
        "{\n"
        "  outputs = { self }: {\n"
        "    nixosConfigurations = { alpha = {}; beta = {}; };\n"
        "  };\n"
        "}\n"
        "EOF"
    )

    # Driven through a pipe rather than the console.
    #
    # send_chars types at the machine's console, which on a nixosTest node is
    # not reliably sitting at a shell - the keystrokes went nowhere and the
    # test sat watching NetworkManager retry until it timed out. A fifo needs
    # no shell and no tty, and the answers land in the installer's stdin
    # whatever the console is doing.
    #
    # The sleep holds the write end open: without it the first `echo` closes
    # the fifo and the installer reads EOF, which it correctly treats as a
    # user who has stopped answering.
    machine.succeed("mkfifo /tmp/in")
    machine.succeed("sleep 3600 > /tmp/in &")
    machine.succeed(
        "KIWAMI_NET_PROBE=file:///etc/os-release "
        "kiwami install --guided --flake /tmp/flake "
        "< /tmp/in > /tmp/out 2>&1 &"
    )

    def answer(text):
        machine.succeed("echo '%s' > /tmp/in" % text)

    def wait_for(text, timeout=120):
        machine.wait_until_succeeds(
            "grep -qF %s /tmp/out" % ("'" + text + "'"), timeout=timeout
        )

    with subtest("it checks the network first"):
        wait_for("checking network")

    with subtest("it offers remote access, and declining moves on"):
        wait_for("reachable over your tailnet")
        answer("n")
        wait_for("Machines this flake already describes")
        wait_for("alpha")

    with subtest("the host menu offers a new machine"):
        # It offered this and then refused it, because the clone it needed had
        # not happened yet. The offer and the acceptance broke separately, so
        # they are asserted separately.
        wait_for("n) a new machine")
        wait_for("Which?")

    with subtest("junk re-prompts instead of exiting"):
        # A question that rejects its own answer and quits cost a whole
        # reinstall to discover. The installer is the one program where
        # giving up leaves the machine unusable.
        answer("zzz")
        machine.wait_until_succeeds(
            "test $(grep -c 'Which?' /tmp/out) -ge 2", timeout=60
        )

    with subtest("the disk was never written"):
        after = machine.succeed("sha256sum /dev/vdb").split()[0]
        assert before == after, "the installer wrote to the disk before any confirmation"
  '';
}
