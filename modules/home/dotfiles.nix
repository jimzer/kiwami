# Links live configs into place.
#
# mkOutOfStoreSymlink points at the working tree, NOT the Nix store, so these
# files stay writable and a change is a reload rather than a rebuild. That is
# the "ricing stays as files" decision made concrete.
#
# Anything listed here must exist in the repo, and the repo must be present at
# `repo` below on the target machine (install.sh places it; `just vm push`
# keeps it current) or the link dangles.
{ config, lib, ... }:

let
  repo = "${config.home.homeDirectory}/kiwami";
  link = path: config.lib.file.mkOutOfStoreSymlink "${repo}/config/${path}";
in
{
  xdg.configFile = {
    "hypr/hyprland.lua".source = link "hypr/hyprland.lua";
    "ghostty/config".source = link "ghostty/config";
  };
}
