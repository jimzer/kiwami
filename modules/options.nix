# The Kiwami option surface.
#
# This is the distro's API. Everything here uses mkDefault where it is a
# preference rather than a requirement, so a consumer importing
# nixosModules.default overrides it by simply setting the option - no forking,
# and our defaults keep improving underneath what they did not touch.
{ lib, ... }:

let
  inherit (lib) mkOption mkEnableOption types;

  # A colour is #rrggbb. Catching this at eval is not pedantry: an earlier
  # theme shipped "#4d4a६6" - valid JSON, invalid colour, silently rendered
  # as garbage.
  hexColor = types.strMatching "#[0-9a-fA-F]{6}";

  paletteType = types.submodule {
    options = lib.genAttrs [
      "accent" "accentDim" "selection" "muted"
      "background" "darkBackground" "lighterBackground" "surface"
      "foreground" "darkForeground" "lightForeground"
      "red" "orange" "yellow" "green" "cyan" "blue" "magenta"
      "brightRed" "brightOrange" "brightYellow" "brightGreen"
      "brightCyan" "brightBlue" "brightMagenta"
    ] (name: mkOption {
      type = hexColor;
      description = "The ${name} colour.";
    });
  };
in
{
  options.kiwami = {
    theme = {
      name = mkOption {
        type = types.str;
        default = "kiwami";
        description = ''
          Theme applied on a machine that has never had one set. Switching
          later is a runtime operation (`kiwami theme set`), not a rebuild,
          so this is only the starting point.
        '';
      };

      themes = mkOption {
        type = types.attrsOf paletteType;
        default = { };
        description = ''
          Palettes to ship. Every one is type checked, so a theme cannot be
          missing a key or carry a malformed colour. Themes downloaded at
          runtime land in ~/.config/kiwami/themes as plain JSON instead -
          deliberately, since a Nix theme would be arbitrary code.
        '';
      };
    };

    bar = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Whether to run the top bar at all.";
      };

      position = mkOption {
        type = types.enum [ "top" "bottom" ];
        default = "top";
      };

      height = mkOption {
        type = types.ints.positive;
        default = 32;
      };

      left = mkOption {
        type = types.listOf types.str;
        default = [ "workspaces" ];
        description = ''
          Widgets on the left, in order. Names resolve to QML components,
          user-provided ones first. Lists merge across modules, so a profile
          can add a widget without replacing the list.
        '';
      };

      center = mkOption {
        type = types.listOf types.str;
        default = [ "window" ];
      };

      right = mkOption {
        type = types.listOf types.str;
        default = [ "tray" "battery" "clock" ];
      };
    };

    terminal = {
      font = mkOption {
        type = types.str;
        default = "JetBrainsMono Nerd Font";
      };

      fontSize = mkOption {
        type = types.ints.positive;
        default = 11;
      };

      extraConfig = mkOption {
        # `lines` merges by concatenation, so several modules and the user can
        # all contribute. Ghostty applies the last definition of a key.
        type = types.lines;
        default = "";
        description = "Appended verbatim to the generated Ghostty config.";
      };
    };

    hyprland.extraConfig = mkOption {
      type = types.lines;
      default = "";
      description = "Lua appended after the generated Hyprland config.";
    };
  };
}
