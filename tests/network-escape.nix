# Proof that a test VM can reach the real internet when we ask it to.
#
# Not a test of Kiwami. It exists to settle a question that changes how
# everything else gets tested: nixosTest is sandboxed and has no network, and
# the alternative - mocking every service a widget talks to - is a lot of
# ceremony to accept on the strength of an assumption.
#
# So this asserts the escape hatch works, and stays in the suite as the thing
# that tells us when it stops working. If it goes red, it is the sandbox
# policy that changed, not the code.
{ pkgs, inputs, home-manager }:

let
  lib' = import ./lib.nix { inherit pkgs; };
in
lib'.networked (pkgs.testers.nixosTest {
  name = "kiwami-network-escape";

  nodes.machine = { ... }: {
    imports = [ lib'.networkedNode ];
    environment.systemPackages = [ pkgs.curl ];
    virtualisation.memorySize = 1024;
  };

  testScript = ''
    machine.wait_for_unit("multi-user.target")

    with subtest("the guest has a route out"):
        # A plain fetch over TLS from a host that is not ours. DNS, routing
        # and certificates all have to work, which is what makes this a
        # meaningful proof rather than a ping.
        machine.wait_until_succeeds(
            "curl -sf --max-time 20 https://cache.nixos.org/nix-cache-info", timeout=120
        )
        machine.succeed(
            "curl -sf --max-time 20 https://cache.nixos.org/nix-cache-info | grep -q StoreDir"
        )
  '';
})
