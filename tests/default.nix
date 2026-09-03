# The tests that need a Linux builder.
#
# Only the desktop test lives here. Porting the installer conversation to
# nixosTest was a mistake worth recording: a test node is not an installer
# image, so driving the prompts meant faking a user through a channel not
# built for it - send_chars into a console with no shell, then a fifo that
# blocked, then transient units - and what it would finally have asserted was
# weaker than what vm/scripts/guided-test.py already asserts against the real
# ISO, on a real console, with the installer actually autostarted.
#
# The prompt logic belongs in the CLI's own tests, where it needs no VM at
# all. The disk and boot claims - the ephemeral wipe, LUKS unlocking - stay in
# vm/, which drives them today and found three real bugs doing it.
{ pkgs, inputs, home-manager }:

{
  desktop = import ./desktop.nix { inherit pkgs inputs home-manager; };
}
