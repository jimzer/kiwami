# Kiwami

A personal NixOS desktop: Hyprland, a Quickshell shell built from scratch, and a
small CLI to drive it — developed against an agent-drivable VM harness.

Status: early. The VM harness and the flake foundation work; the desktop does
not exist yet. See [TASKS.md](TASKS.md).

## Installing on real hardware

Boot the official NixOS ISO, partition, then:

```bash
nixos-install --flake github:jimzer/kiwami#desktop
```

The dev VM deliberately does *not* install this way: `just vm install` ships the
working tree over the serial console, so it tests uncommitted changes rather than
the last pushed commit.

## The CLI

`cli/` is a Rust binary built by this flake as `packages.<system>.kiwami`, so
the same build serves `nix run github:jimzer/kiwami`, the system closure, and
any future image.

```bash
kiwami install             # install to a disk (from the live ISO)
kiwami disks               # what the installer can see
kiwami doctor              # drift + health; non-zero exit on problems
kiwami theme list          # available themes, active one marked
kiwami theme set midnight  # switch, regenerate, retint everything
kiwami commands --json     # actions the launcher should offer
```

The launcher merges `kiwami commands --json` with `.desktop` applications, so
typing "theme" offers the theme switches without opening a terminal. The CLI
stays the single source of truth for what it can do.

## Layout

```
flake.nix              inputs (nixpkgs, home-manager, quickshell) + hosts
flake.lock             exact commits — the whole point
hosts/<host>/          per-machine: choices + hardware facts
modules/               shared across hosts
vm/                    aarch64 dev VM on macOS, drivable by an agent
```

## Quick start

```bash
just                 # list commands
just vm              # list the VM subsystem
just vm install      # wipe + unattended install into the dev VM (~3 min)
just vm start        # boot it headless
just vm gui          # boot it in a window
just vm ssh 'uname -a'
just vm screenshot bar
just vm rebuild      # push the flake and nixos-rebuild switch
just vm reload       # push, reload Hyprland, restart the shell — no rebuild
just vm shell-log    # journal for the shell unit
just vm start-test-disks   # boot with the installer's scratch disks
just vm install-test       # installer test matrix
just vm hyprctl clients
```

Requires `just >= 1.31` (modules), QEMU, and Nix on the host for
`just vm eval` / `just vm update`.

## Design notes

**The flake is the only definition of a machine.** `just vm install` runs
`nixos-install --flake`, so a from-scratch install and an in-place `rebuild`
produce byte-identical store paths.

**Ricing stays as files.** Hyprland and Quickshell configs are edited live and
reloaded, not rebuilt — `mkOutOfStoreSymlink` into the working tree.

**Quickshell is pinned.** It is alpha and ships breaking QML API changes, so it
moves when `flake.lock` says, not when upstream pushes.

**Hyprland is configured in Lua** (v0.55+), not `hyprland.conf`.

## Keybinds

| | |
|---|---|
| `SUPER+RETURN` | terminal |
| `SUPER+SPACE` | launcher (apps + `kiwami` commands) |
| `SUPER+SHIFT+P` | power menu |
| `SUPER+1..9` | workspaces |
| `XF86Audio*` / `XF86MonBrightness*` | volume and brightness, with OSD |

## Session services

Hyprland is launched through UWSM so `graphical-session.target` actually
activates. Two traps that make session services fail silently — and their fixes
— are written up in [docs/session-services.md](docs/session-services.md).

## The VM harness

Three independent channels into the guest — QMP for framebuffer screenshots and
key injection, a serial console that works before the network does, and SSH once
it is up. Plus snapshot/restore for reset-per-iteration.

See [vm/README.md](vm/README.md), especially the gotchas section.
