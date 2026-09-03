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
      user.name = "Jimi Vaubien";
      user.email = "jimi.vaubien@bitswired.com";
      init.defaultBranch = "main";
      # A new branch pushes without having to name the remote first.
      push.autoSetupRemote = true;
    };
  };

  # gh's config.yml, from the flake. Its token lives in hosts.yml beside this,
  # which is persisted instead - the two halves of that directory have
  # different owners on purpose. See kiwami.persist.userFiles.
  programs.gh = {
    enable = true;
    settings = {
      # https, not ssh: the token gh already holds is then enough to push, so
      # there is no key to place on a machine that wipes itself.
      git_protocol = "https";
    };
  };
}
