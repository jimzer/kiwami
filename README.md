# Kiwami

A personal NixOS desktop: Hyprland, a Quickshell shell written from scratch,
and a small CLI — developed against a VM the agent can drive.

Status: early. The desktop works in a VM; it has never run on real hardware.
See [TASKS.md](TASKS.md).

## The model

**The flake is the machine.** Configs are placed by Home Manager as read-only
symlinks into the Nix store. You change one by editing it here and rebuilding
— the same motion as changing a package or a service. There is no separate
user-override layer.

Two things stay at runtime, because a rebuild is the wrong granularity for
them:

- **Themes.** Authored as typed Nix, generated to JSON, switched with
  `kiwami theme set` and no rebuild. The shell watches the file and retints
  live, which is what designing a palette needs.
- **The shell tree during development.** The launcher prefers `~/kiwami/shell`
  when it exists, so iterating on QML is a 0.8s restart rather than an 8s
  rebuild.

## Using it

Install NixOS, then:

```bash
nixos-install --flake github:jimzer/kiwami#desktop
```

## Building on it

A machine is a small flake of its own — no fork:

```nix
{
  inputs.kiwami.url = "github:jimzer/kiwami";

  outputs = { nixpkgs, kiwami, ... }: {
    nixosConfigurations.my-laptop = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        kiwami.nixosModules.default
        ./hardware-configuration.nix
        { kiwami.bar.position = "bottom"; }
      ];
    };
  };
}
```

Kiwami's defaults use `mkDefault`, so your values win and ours fill the rest.
`nix flake update` pulls improvements without touching what you overrode.

## Options

`kiwami.*` is the API. It exists so machines can differ without forking files.

| | |
|---|---|
| `bar.{enable,position,height,left,center,right}` | which widgets, where |
| `theme.{name,themes}` | palettes, type-checked as `#rrggbb` |
| `terminal.{settings,extraConfig}` | per-machine Ghostty overrides |
| `hyprland.extraConfig` | Lua appended after ours |

Widgets resolve by filename: add `shell/widgets/Weather.qml`, name it in
`kiwami.bar.right`, done.

## The CLI

```bash
kiwami install             # install to a disk, from the live ISO
kiwami disks               # what the installer can see
kiwami theme list / set    # switch theme, no rebuild
kiwami doctor              # drift + health; non-zero exit on problems
kiwami commands --json     # actions the launcher offers
```

The launcher merges those commands with `.desktop` entries, so typing "theme"
offers the switches without opening a terminal.

## Keybinds

| | |
|---|---|
| `SUPER+RETURN` | terminal |
| `SUPER+SPACE` | launcher |
| `SUPER+SHIFT+P` | power menu |
| `SUPER+SHIFT+R` | restart the shell — bound in the compositor, so it works when the shell is gone |
| `SUPER+1..9` | workspaces |
| `XF86Audio*` / `XF86MonBrightness*` | volume and brightness, with OSD |

## Development

```bash
just vm install      # wipe + unattended install (~3 min)
just vm start        # boot headless
just vm gui          # boot in a window
just vm reload       # push + restart the shell, no rebuild
just vm rebuild      # push + nixos-rebuild switch
just vm screenshot x
just vm doctor       # or: just vm ssh 'kiwami doctor'
just vm install-test # installer matrix
```

The VM is aarch64 so it runs natively under HVF on Apple silicon. CI builds
and boots x86_64, which is the architecture real hardware will use.

## Layout

```
flake.nix          inputs, hosts, nixosModules.default
modules/           options, themes, generation, desktop, home-manager
config/            hyprland.lua, ghostty config, theme palettes
shell/             Quickshell QML
cli/               kiwami: install, theme, doctor, commands
hosts/             per-machine: choices + hardware facts
vm/                the development VM and its harness
docs/              notes worth keeping
```

## Notes

[docs/session-services.md](docs/session-services.md) — how the session is
wired, and the traps that cost real time.
