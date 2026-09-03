# Shared helpers for the tests.
{ pkgs }:

{
  # A test that can reach the real internet.
  #
  # nixosTest VMs are sandboxed and have no network. That is the right default:
  # a test that can fail because a mirror hiccupped is a test you eventually
  # stop believing, and this project has already watched two meaningless red
  # runs train exactly that reflex.
  #
  # But the sandbox is a policy, not a wall, and we own the builder. Two things
  # lift it: __noChroot on the derivation, and a user-mode NIC so the guest has
  # a route out. Both are here so a networked test is one call rather than
  # three remembered incantations.
  #
  # Use it only where a live service is the point. Everything about the
  # installer, the disk layout and the desktop session can be tested without
  # it, and should be.
  #
  # Two things to know before relying on it:
  #
  #   - The builder needs `sandbox = relaxed` in nix.conf, or Nix refuses the
  #     derivation outright.
  #   - Results are cached like any other build. A networked test that passed
  #     yesterday will not re-run today unless its inputs changed, so it can
  #     report a stale pass while the service it checks is broken. Force it
  #     with `nix build --rebuild` when that is what you actually want to know.
  networked = test:
    (test.overrideAttrs (old: {
      __noChroot = true;
    }));

  # The node-level half: a NIC with a route to the outside. The test VLANs
  # nixosTest sets up connect the nodes to each other and to nothing else.
  networkedNode = {
    virtualisation.qemu.networkingOptions = [
      "-netdev user,id=user.0"
      "-device virtio-net-pci,netdev=user.0"
    ];
  };
}
