# Session, services, and traps

How the desktop session is wired, and the specific things that cost hours.
Every entry here was hit, not anticipated.

## How the session starts

greetd autologins into **UWSM**, which launches Hyprland inside a real systemd
user session:

```
graphical-session-pre.target     environment imported
        ↓
    Hyprland
        ↓
graphical-session.target         ← user units start here
        ↓
xdg-desktop-autostart.target
```

A compositor does not activate `graphical-session.target` on its own — it
stays init-agnostic so it can run without systemd. Without something doing it,
the target never activates and **every unit bound to it silently never
starts**. That is what UWSM is for.

`programs.hyprland.withUWSM` only enables `programs.uwsm`; the compositor must
still be registered under `programs.uwsm.waylandCompositors`.

The shell runs as a user unit rather than being exec'd from Hyprland, which
buys `Restart=always`, `journalctl --user -u kiwami-shell`, and a clean
`systemctl --user restart` to pair with the disabled file watcher.

## Trap 1: `After=` does not gate on a target

`After=` is **ordering only**. It never prevents a start. The `systemd --user`
instance is per *user*, not per *desktop*, and `pam_systemd` starts it on any
login — including SSH.

So over SSH, with no compositor:

1. Something starts the unit (a rebuild restarting changed units).
2. It launches with no `WAYLAND_DISPLAY` and cannot reach any compositor.
3. It does not crash. It sits there **active and useless**.
4. You log in graphically; the target activates.
5. systemd sees the unit already active and does nothing — `Wants=` pulls in
   stopped units, it does not restart running ones.

Not hypothetical: this machine is driven entirely over SSH, and
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

Related: enabling a unit while its target is **already active** does not start
it, and `systemctl --user start <already-active-target>` is a no-op.

## Trap 2: file watchers fire mid-write

Quickshell watches its QML tree and reloads on change. The watcher fires on the
*first* write, not when the writer finished. A reload against a half-written
tree fails, and the failed attempt leaves a second engine generation behind
that turns the *next* restart into a crash.

**Fix:** `QS_DISABLE_FILE_WATCHER=1`, and restart deliberately once the tree is
known complete. `just vm reload` does exactly that.

## Trap 3: replacing a directory breaks watchers

`kiwami theme set` first published by swapping a directory:

```
mv "$STAGE" "$CURRENT.new"
rm -rf "$CURRENT"          # <- the file is gone here
mv "$CURRENT.new" "$CURRENT"
```

That window is short but real. The shell's `FileView` read during it, logged
`File does not exist`, and **stopped watching** — so the shell was stuck on its
fallback palette until restarted, even after the theme was in place.

Two fixes, both needed:

- **Publish per file, never by replacing a directory.** Write each file to a
  temp name and rename it into place, so a consumer never sees it absent.
- **Recover from a failed read.** Retry after a short delay, so a watcher that
  loses its file is not dead for the rest of the session.

The same shape bit `just vm push` when it did `rm -rf` on a tree Hyprland was
reading. Anything that deletes a tree other processes watch will produce it.

## Trap 4: NixOS wrappers break `pgrep -x`

NixOS wraps many binaries and the kernel truncates `comm` to 15 characters, so
a process launched as `ghostty` reports `.ghostty-wrappe`, and Hyprland reports
`.Hyprland-wrapp`. `pkill -x ghostty` matches nothing and fails **silently**.
Scripts copied from other distros hit this.

Matching loosely is worse: an unhandled signal's default disposition is to
**terminate**, so an over-broad `pkill -USR2` kills every unrelated process it
hits. Walk `/proc/*/comm` and accept only the exact name or the wrapper form.

**Verifying a signal is actually handled:** `strings` on the binary is not a
test — a Zig or Rust handler need not contain the literal `"SIGUSR2"`. The
authoritative check is the caught-signal mask:

```
grep SigCgt /proc/<pid>/status     # 0000000100000800
```

Bit 11 (`0x800`) is SIGUSR2. Set means a handler is installed.

## Trap 5: one serial console, one client

QEMU's chardev socket accepts a single connection. Running `console.py` by hand
while `install.sh` is mid-run steals the socket, and the script then waits for
output being delivered to someone else. Use `just vm ssh` to observe a guest a
script is driving.

## Trap 6: atomic writes detach a managed symlink

`~/.config/hypr/hyprland.lua` is a symlink into the store, and `/nix/store` is
read-only, so it cannot be edited through. But:

```
$ sed -i 's/foo/bar/' ~/.config/hypr/hyprland.lua
$ ls -l ~/.config/hypr/hyprland.lua
-r--r--r--   # a regular file now, not a symlink
```

`sed -i` writes a temp file and renames it over the target, which **replaces
the symlink** rather than following it. The result is a real file, detached
from the store, that no longer tracks the flake — and it inherits `444`, so it
cannot easily be edited again either.

Home Manager then refuses to activate, with `would be clobbered`, which is at
least loud. Editors that save-and-rename and some formatters do the same.

## Trap 7: a QML `required property` must be set at creation

Assigning it in `onLoaded` is too late and the component silently fails to
build. A `Loader` for such a component needs:

```qml
Component.onCompleted: setSource("Bar.qml", { modelData: modelData })
```

Related: QML resolves singletons **per directory**. Moving widgets into
`shell/widgets/` meant they could no longer see `Theme.qml` one level up, and
they did not error — they rendered with undefined colours. `import ".."` fixes
it.

## Testing the desktop: assert effects, not processes

Two CI runs passed while the shell was completely broken. The assertion was
`pgrep -f quickshell`, and a unit flapping under `Restart=always` matches
`pgrep` every time it respawns. The screenshot was 233 bytes of blank
framebuffer and nobody opened it.

What actually works:

- `NRestarts` is low — distinguishes *running* from *being resurrected*
- the compositor mapped a layer surface (`hyprctl layers | grep quickshell`)
- a config value that is ours and not the default (`general:gaps_in` is 4, the
  Hyprland default is 5) — otherwise the compositor silently runs its
  autogenerated config and every other assertion still passes

## The UWSM startup banner

Hyprland prints "started without start-hyprland" for a few seconds under UWSM.
Cosmetic: UWSM does the session setup the warning refers to, it is just not the
wrapper Hyprland looks for. It expires, which is why it appears in screenshots
taken seconds after boot and not in later ones.

## Driving the desktop without fingers

The shell can be exercised remotely - which is what makes developing it on a
machine you are not sitting at practical. Four things, and the first is the one
that wastes an afternoon.

**`hyprctl dispatch` takes Lua, because the config is Lua.** It wraps its
arguments as Lua source, so the syntax from every tutorial is a parse error:

    $ hyprctl dispatch global kiwami:launcher
    error: [string "return hl.dispatch(global kiwami:launcher)"]:1: ')' expected

    $ hyprctl dispatch 'hl.dsp.global("kiwami:launcher")'
    ok

Same family as `hyprctl` reporting every bind as `__lua`, which is why the CI
test checks `gaps_in` rather than keybinds.

**`wtype` types, but does not trigger binds.** Text reaches the focused
surface - typing into the launcher's search box filters it - but a synthetic
`SUPER+SPACE` does not fire the Hyprland bind. Use the dispatcher for
shortcuts and `wtype` for text.

**`wlrctl pointer move|click`** works, via the wlroots virtual-pointer
protocol. `hyprctl cursorpos` confirms it moved.

**Assert a surface, not a screenshot.** `hyprctl layers` names every layer
surface, so "the launcher opened" is `grep kiwami-launcher` rather than
eyeballing a picture. A screenshot proves it *rendered*, which is a different
and weaker claim - the first frame may not have landed yet.

Both tools are ordinary Wayland clients using the virtual-keyboard and
virtual-pointer protocols, so they need session access and nothing more.
`ydotool` would cover both from one binary, but only by way of a root daemon
holding /dev/uinput open - a much larger surface for the same result.
