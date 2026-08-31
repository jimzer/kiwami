# Points the user's config files at Kiwami's generated entry points.
#
# Both targets are thin aggregators that load the distro config and then the
# user's own file, so improving a default never has to touch anything here.
# Resolved at activation, because whether a working tree exists is a property
# of the machine rather than of the build.
{ config, lib, ... }:

let
  repo = "${config.home.homeDirectory}/kiwami";
in
{
  home.activation.kiwamiConfigs = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    link() {  # link <dest under ~/.config> <system path> <path within the checkout>
      target="${repo}/$3"
      [ -f "$target" ] || target="$2"
      $DRY_RUN_CMD mkdir -p "$(dirname "$HOME/.config/$1")"
      $DRY_RUN_CMD ln -sfn "$target" "$HOME/.config/$1"
    }

    link hypr/hyprland.lua    /etc/kiwami/config/hypr/aggregator.lua  .kiwami-no-override
    link ghostty/config       /etc/kiwami/config/ghostty/config       .kiwami-no-override

    # Seed the user-owned override files once, empty, so they are obvious and
    # editable. Never touched again.
    for f in "$HOME/.config/ghostty/overrides" "$HOME/.config/hypr/mine.lua"; do
      if [ ! -e "$f" ]; then
        $DRY_RUN_CMD mkdir -p "$(dirname "$f")"
        $DRY_RUN_CMD install -m644 /dev/null "$f"
      fi
    done
  '';
}
