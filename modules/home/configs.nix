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
}
