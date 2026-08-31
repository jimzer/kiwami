# Turns kiwami.* options into the files the runtime consumes.
#
# The runtime contract is unchanged on purpose: themes are still colors.json,
# still watched by the shell, still switchable with `kiwami theme set` and no
# rebuild. Nix decides what ships and validates it; the runtime decides what
# is active.
{ config, lib, pkgs, ... }:

let
  cfg = config.kiwami;

  # Option names are camelCase because that is the Nix convention; the JSON
  # keys stay snake_case because the CLI and QML already read them and the
  # runtime format is a contract with downloaded themes.
  jsonKey = name:
    lib.toLower (builtins.replaceStrings
      (map (c: c) [ "A" "B" "C" "D" "E" "F" "G" "H" "I" "J" "K" "L" "M"
                    "N" "O" "P" "Q" "R" "S" "T" "U" "V" "W" "X" "Y" "Z" ])
      (map (c: "_" + c) [ "a" "b" "c" "d" "e" "f" "g" "h" "i" "j" "k" "l" "m"
                          "n" "o" "p" "q" "r" "s" "t" "u" "v" "w" "x" "y" "z" ])
      name);

  paletteJson = name: palette:
    builtins.toJSON ({ inherit name; mode = "dark"; }
      // lib.mapAttrs' (k: v: lib.nameValuePair (jsonKey k) v) palette);

  themeFiles = lib.mapAttrs' (name: palette:
    lib.nameValuePair "kiwami/themes/${name}/colors.json" {
      text = paletteJson name palette;
    }) cfg.theme.themes;

  # What the shell reads to lay itself out. Generated rather than hardcoded in
  # QML so `kiwami.bar.right = [...]` in a consumer's flake actually moves things.
  barManifest = builtins.toJSON {
    inherit (cfg.bar) enable position height left center right;
    defaultTheme = cfg.theme.name;
  };
in
{
  environment.etc = themeFiles // {
    "kiwami/bar.json".text = barManifest;
    "kiwami/shell".source = ../shell;

    "kiwami/config/ghostty/defaults".text = ''
      # Generated from kiwami.terminal.*. Do not edit; set the options instead.
      font-family = ${cfg.terminal.font}
      font-size = ${toString cfg.terminal.fontSize}

      window-padding-x = 10
      window-padding-y = 8
      window-decoration = false
      cursor-style = block
      confirm-close-surface = false
      scrollback-limit = 100000

      ${cfg.terminal.extraConfig}
    '';

    "kiwami/config/hypr/kiwami.lua".source = ../config/hypr/hyprland.lua;

    "kiwami/config/hypr/extra.lua".text = ''
      -- Generated from kiwami.hyprland.extraConfig.
      ${cfg.hyprland.extraConfig}
    '';

    # The file ~/.config/hypr/hyprland.lua points at. Deliberately thin: it is
    # the one file the user owns and we can never rewrite, so everything we
    # might want to improve lives behind these two loads, not in here.
    "kiwami/config/hypr/aggregator.lua".text = ''
      -- Kiwami Hyprland entry point.
      local function load(path)
        local ok, err = pcall(dofile, path)
        if not ok then
          print("kiwami: " .. tostring(err))
        end
      end

      load("/etc/kiwami/config/hypr/kiwami.lua")   -- distro config
      load("/etc/kiwami/config/hypr/extra.lua")    -- kiwami.hyprland.extraConfig

      -- Yours, loaded last so it wins. Optional.
      local home = os.getenv("HOME")
      local mine = home .. "/.config/hypr/mine.lua"
      local f = io.open(mine, "r")
      if f then f:close(); load(mine) end
    '';

    # Ghostty resolves includes after the containing file and the last include
    # wins, so layering is expressed purely by this order. Verified: inline
    # values lose to any include, regardless of position in the file.
    "kiwami/config/ghostty/config".text = ''
      # Kiwami Ghostty entry point. Put your own settings in
      # ~/.config/ghostty/overrides - it is loaded last and wins.
      config-file = ?/etc/kiwami/config/ghostty/defaults
      config-file = ?~/.local/state/kiwami/current/theme/ghostty.conf
      config-file = ?~/.config/ghostty/overrides
    '';
  };
}
