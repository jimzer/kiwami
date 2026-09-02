-- Kiwami Hyprland configuration (Hyprland >= 0.55 Lua API).
--
-- This file is a plain config, not generated from Nix: edit it and reload,
-- no rebuild. See modules/home/hyprland.nix for how it is linked into place.

local mod = "SUPER"

-- Colours from the active theme. pcall so a missing or broken theme leaves the
-- compositor usable rather than refusing to start.
local ok, theme = pcall(dofile,
  os.getenv("HOME") .. "/.local/state/kiwami/current/theme/colors.lua")
if not ok or type(theme) ~= "table" then
  theme = { accent = "7ad07a", muted = "4b5a52" }
end

hl.config {
  general = {
    gaps_in = 4,
    gaps_out = 8,
    border_size = 2,
    ["col.active_border"] = "rgba(" .. theme.accent .. "ff)",
    ["col.inactive_border"] = "rgba(" .. theme.muted .. "80)",
  },
  decoration = {
    rounding = 6,
  },
  -- The dev VM has no GPU (llvmpipe). Animations are pointless there and
  -- make screenshots nondeterministic.
  animations = {
    enabled = false,
  },
  input = {
    kb_layout = "us",
    follow_mouse = 1,
  },
  misc = {
    disable_hyprland_logo = true,
    disable_splash_rendering = true,
  },
}

-- Escape hatches. These must exist before anything fancy does: if the shell
-- crashes, this is how you get a terminal back.
hl.bind(mod .. " + RETURN", hl.dsp.exec_cmd("ghostty"))
hl.bind(mod .. " + Q", hl.dsp.window.close())
hl.bind(mod .. " + SHIFT + E", hl.dsp.exit())

-- Escape hatch. The shell is a systemd unit with Restart=always, but a QML
-- error can leave it flapping or up-with-no-bar. This is bound in the
-- compositor, so it works even when the shell is completely gone.
hl.bind(mod .. " + SHIFT + R",
  hl.dsp.exec_cmd("systemctl --user restart kiwami-shell.service"))

-- Toggle the launcher. The shell registers a GlobalShortcut under
-- appid "kiwami", so the compositor forwards the key to it.
hl.bind(mod .. " + SPACE", hl.dsp.global("kiwami:launcher"))
hl.bind(mod .. " + SHIFT + P", hl.dsp.global("kiwami:power"))

-- Media and brightness keys. These only change the state; the shell's OSD
-- watches PipeWire and appears on its own, so nothing has to tell it to.
hl.bind("XF86AudioRaiseVolume", hl.dsp.exec_cmd("wpctl set-volume -l 1.0 @DEFAULT_AUDIO_SINK@ 5%+"), { repeating = true })
hl.bind("XF86AudioLowerVolume", hl.dsp.exec_cmd("wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-"), { repeating = true })
hl.bind("XF86AudioMute", hl.dsp.exec_cmd("wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle"))
-- Brightness leaves a marker the shell can watch. sysfs reports changes through
-- neither inotify nor udev - both were measured returning nothing - so the OSD
-- has no way to notice a backlight write on its own. The marker lives on a
-- tmpfs, where inotify does work.
local brightness = "brightnessctl set %s && touch \"$XDG_RUNTIME_DIR/kiwami-brightness\""
hl.bind("XF86MonBrightnessUp",
  hl.dsp.exec_cmd("sh -c '" .. string.format(brightness, "+5%%") .. "'"), { repeating = true })
hl.bind("XF86MonBrightnessDown",
  hl.dsp.exec_cmd("sh -c '" .. string.format(brightness, "5%%-") .. "'"), { repeating = true })

-- Workspaces
for i = 1, 9 do
  hl.bind(mod .. " + " .. i, hl.dsp.focus({ workspace = i }))
  hl.bind(mod .. " + SHIFT + " .. i, hl.dsp.window.move({ workspace = i }))
end
