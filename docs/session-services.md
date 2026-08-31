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

**Kiwami uses a unit for the shell.** UWSM enables the option; it does not force
it, so this is a separate decision. We take it because `Restart=always`,
`journalctl --user -u kiwami-shell`, and `systemctl --user restart` come for
free, where the exec model needs a wrapper script to rebuild all three.

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


## Trap 3: replacing a directory breaks watchers

`kiwami-theme` first published by building a staging directory and swapping it:

```
mv "$STAGE" "$CURRENT.new"
rm -rf "$CURRENT"          # <- the file is gone here
mv "$CURRENT.new" "$CURRENT"
```

That window is short but real. The shell's `FileView` read during it and logged
`Read of .../colors.json failed: File does not exist.` — and then stopped
watching, so the shell was stuck on its fallback palette until restarted, even
after the theme was in place.

Two fixes, both needed:

- **Publish per file, never by replacing a directory.** `rsync -a --delete`
  writes each file to a temp name and renames it into place, so a consumer
  never sees it absent.
- **Recover from a failed read.** `onLoadFailed` retries after a short delay,
  so a watcher that loses its file is not dead for the rest of the session.

This is the same shape as the `rm -rf` in `just vm push` that made Hyprland's
config vanish mid-reload. Anything that deletes a tree other processes are
watching will produce it.


## Trap 4: NixOS wrappers break `pgrep -x` / `pkill -x`

NixOS wraps many binaries, and the kernel truncates `comm` to 15 characters, so
a process launched as `ghostty` reports:

```
comm: .ghostty-wrappe
```

`pkill -x ghostty` therefore matches nothing and fails **silently**. The same
bites `pgrep -x Hyprland`, which reports `.Hyprland-wrapp`. Scripts copied from
other distros hit this: Omarchy guards its terminal reload with
`pgrep -x ghostty`, which is correct on Arch and a no-op here.

Matching loosely is worse than not matching. An unhandled signal's default
disposition is to **terminate** the process, so an over-broad `pkill -USR2`
kills every unrelated process it hits. `kiwami` walks `/proc/*/comm` and
accepts only the exact name or NixOS's `.<name>-wrapp…` form.

### Verifying a signal is actually handled

`strings` on the binary is not a test — a Zig or Rust handler need not contain
the literal `"SIGUSR2"`. The authoritative check is the caught-signal mask:

```
grep SigCgt /proc/<pid>/status     # 0000000100000800
```

Bit 11 (`0x800`) is SIGUSR2. Set means the process installed a handler for it.


## Trap 5: one serial console, one client

QEMU's chardev socket accepts a single connection. Running `console.py` by hand
while `install.sh` is mid-run steals the socket from it, and the script then
sits waiting for output that is being delivered to someone else.

Use `just vm ssh` to look at a guest that a script is currently driving over
serial, or wait for it to finish.


## The "started without start-hyprland" banner under UWSM

UWSM launches the compositor binary directly, so Hyprland shows its
"started without start-hyprland" warning for a few seconds at session start.

It is cosmetic here. UWSM does the session setup the warning is about - it
imports the environment and activates graphical-session.target, both verified
above - it just is not the wrapper Hyprland looks for. The banner expires on
its own, which is why it appears in CI screenshots (captured seconds after
boot) and not in ones taken later.


## Trap 6: atomic writes detach a managed symlink

`~/.config/ghostty/config` is a symlink into `/etc`, and `/nix/store` is
read-only, so it cannot be edited through. But:

```
$ sed -i 's/foo/bar/' ~/.config/ghostty/config
$ ls -l ~/.config/ghostty/config
-r--r--r--  328   # a regular file now, not a symlink
```

`sed -i` does not edit in place. It writes a temp file and renames it over the
target, which **replaces the symlink** rather than following it. The result is
a real file, detached from `/etc`, that silently stops receiving distro
updates — and it inherits the store's `444`, so it cannot easily be edited
again either. Nothing looks broken; `/etc` still holds the pristine original.

Editors that save-and-rename, `install`, and some formatters do the same. This
is a general hazard of the symlink-into-store pattern, and the reason
`kiwami doctor` checks that entry points still point where we put them. It is
a warning rather than an error: taking over the file is legitimate if you meant
to.


## Shadowing: two things that bite

The shell loads a merged tree - what ships (or a checkout) first, then
`~/.config/kiwami/shell` overwriting by filename. Two failure modes came out
of building it.

**A stale override keeps loading.** A file cloned months ago still shadows the
shipped one, referencing things that have since moved. We hit exactly this: a
`Bar.qml` copied before widgets moved into `widgets/` failed with
`Tray is not a type`, and the symptom looked like a shell bug rather than an
old copy. `kiwami shell clone` therefore records a digest of what it copied,
and `kiwami shell list` flags an override whose shipped version has changed.

**Isolation has to cover the top level, not just widgets.** A broken widget is
contained by its Loader, but `shell.qml` originally instantiated Bar, Launcher
and the rest directly - so one bad override took the entire shell down. Every
top-level piece now goes through a Loader too, and a failure costs that piece
only.

One QML detail worth remembering: a `required property` must be supplied when
the component is created. Setting it in `onLoaded` is too late and the
component silently fails to build, so a Loader for such a component needs
`setSource(url, { prop: value })` rather than `source:`.
