# Links the live Hyprland config into place.
#
# mkOutOfStoreSymlink points at the working tree, NOT the Nix store, so the
# file stays writable and a change is `hyprctl reload` rather than a rebuild.
# That is the whole "ricing stays as files" decision made concrete.
{ config, lib, ... }:

let
  # Where the repo lives on the target machine. install.sh places it here,
  # and `just vm push` keeps it current.
  repo = "${config.home.homeDirectory}/kiwami";
in
{
  xdg.configFile."hypr/hyprland.lua".source =
    config.lib.file.mkOutOfStoreSymlink "${repo}/config/hypr/hyprland.lua";
}
