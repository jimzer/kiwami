# Session services

How to run something for the lifetime of the desktop, and the two traps that
make it fail silently. Everything here was verified in the dev VM.

## The two launch models

**Compositor exec** — Hyprland spawns it as a child:

```lua
hl.on("hyprland.start", function()
  hl.exec_cmd("quickshell")
end)
```

**systemd user unit** — systemd starts it when the desktop comes up. Needs
`graphical-session.target` to actually activate, which is why we run UWSM.

Omarchy uses both: the shell is exec'd from Hyprland (wrapped in a script that
adds journal logging and a restart loop), while peripheral services like fcitx5
and the bluetooth agent are user units.

## Why UWSM

A compositor does not activate `graphical-session.target` on its own — it stays
init-agnostic so it can run without systemd at all. Without something doing it,
the target never activates and **every unit bound to it silently never starts**.

UWSM wraps the compositor in a real systemd session: imports the environment,
then activates `graphical-session-pre` → `graphical-session` →
`xdg-desktop-autostart`, and unwinds on logout.

Enabled in `modules/desktop.nix`. Note `programs.hyprland.withUWSM` only flips
`programs.uwsm.enable`; the compositor must still be registered under
`programs.uwsm.waylandCompositors`.

## Trap 1: `After=` does not gate on the target

`After=` is **ordering only**. It never prevents a start. The `systemd --user`
instance is per *user*, not per *desktop*, and `pam_systemd` starts it on any
login — including SSH.

So over SSH, with no compositor:

1. Something starts the unit (a rebuild restarting changed units, a manual start).
2. It launches with no `WAYLAND_DISPLAY` and cannot reach any compositor.
3. It does not crash. It sits there **active and useless**.
4. You log in graphically; the target activates.
5. systemd sees the unit already active and does nothing — `Wants=` pulls in
   stopped units, it does not restart running ones.
6. Broken for the whole session, with logs that look clean.

This is not hypothetical here: we drive this machine entirely over SSH, and
`nixos-rebuild switch` restarts changed user units.

**Fix — `ConditionEnvironment=`:**

```ini
[Unit]
After=graphical-session.target
PartOf=graphical-session.target      # stop cleanly when the session ends
ConditionEnvironment=WAYLAND_DISPLAY # skip entirely if there is no session

[Install]
WantedBy=graphical-session.target
```

Verified: with the variable absent the unit is *skipped*, not failed
(`skipped, unmet condition check`), stays enabled, and starts normally at the
next graphical login.

## Trap 2: file watchers fire mid-write

Quickshell watches its QML tree and hot-reloads on change. The watcher fires on
the *first* write, not when the writer finished.

`just vm push` does `rm -rf ~/kiwami && tar x` — the tree is deleted and
recreated file by file. A watcher sees a half-written tree, the reload fails,
and (per Omarchy's own note) the failed attempt leaves a second engine
generation behind that turns the *next* restart into a crash. The damage happens
during a push; the symptom appears later.

**Fix:** `QS_DISABLE_FILE_WATCHER=1` and restart the shell deliberately, once
the tree is known complete.

## Also worth knowing

Enabling a unit while the target is **already active** does not start it, and
`systemctl --user start <already-active-target>` is a no-op. Restart the session
or start the unit explicitly.
