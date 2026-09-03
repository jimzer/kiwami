# Application configs, placed by Home Manager straight from the flake.
#
# Read-only symlinks into the store, replaced on every rebuild. There is no
# user-override layer: you change a config by editing it in the flake and
# rebuilding, which is the same motion as changing anything else here.
#
# The one runtime hook that survives is the theme - colours are switched by
# `kiwami theme set` without a rebuild, so both files include or load the
# generated palette rather than embedding colours.
{ config, lib, ... }:

{
  xdg.configFile = {
    "hypr/hyprland.lua".source = ../../config/hypr/hyprland.lua;
    "ghostty/config".source = ../../config/ghostty/config;
  };

  # An identity, so the machine can commit its own config.
  #
  # It could not: `kiwami install` scaffolds hosts/<name>/ and stages it,
  # which is all a flake needs to build from - but git refused to commit with
  # "Author identity unknown", and there were no GitHub credentials either.
  # So the one machine that knows its own hardware was the one machine that
  # could not record it anywhere else.
  programs.git = {
    enable = true;
    settings = {
      user.name = "jimzer";
      user.email = "jimi.vaubien@protonmail.com";
      init.defaultBranch = "main";
      # A new branch pushes without having to name the remote first.
      push.autoSetupRemote = true;
    };
  };

  # gh is deliberately not configured from here.
  #
  # The tidy version of this split gave the flake config.yml and persisted
  # hosts.yml beside it. gh does not agree: `gh auth login` writes
  # git_protocol into config.yml, hit a read-only store symlink, and reported
  # "gh did not complete" on a login that had in fact succeeded.
  #
  # config.yml is state that gh maintains, not configuration we impose, so it
  # is persisted whole and gh owns it. The principle stands - what the flake
  # owns, it owns completely - and the lesson is that the boundary belongs
  # where the program puts it, not where the split looks neatest.
}
