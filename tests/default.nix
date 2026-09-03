# Every test that needs a Linux builder, in one place.
#
# They live here rather than inline in flake.nix because there are about to be
# several: the installer conversation, the ephemeral root, encryption. A flake
# that carries a thousand lines of test script stops being readable as a
# description of the system.
#
# vm/ still holds the older QEMU-and-serial harness. It is kept until every
# one of these covers what it covered - a test that has not been replaced is
# not redundant.
{ pkgs, inputs, home-manager }:

let
  args = { inherit pkgs inputs home-manager; };
in
{
  desktop = import ./desktop.nix args;
  installer = import ./installer.nix args;
  ephemeral = import ./ephemeral.nix args;
  luks = import ./luks.nix args;
}
