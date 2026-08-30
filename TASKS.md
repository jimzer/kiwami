# Kiwami — task tracker

A personal NixOS distribution: Hyprland + a Quickshell desktop built from
scratch, developed largely by agents against a VM harness.

Status: **Tier 2 (the agent VM loop) is done first, on purpose** — it multiplies
every task after it. Tier 0 is next.

Legend: `[ ]` todo · `[~]` in progress · `[x]` done · `(?)` needs a decision

---

## Decisions taken

- **Base: NixOS**, not Arch. Considered seriously and reversed twice. Deciding
  factors: `flake.lock` pins Quickshell (an alpha dependency the whole desktop
  sits on), generations give per-config rollback, packages are declared by
  construction, and `nixosTest` exists. Costs accepted: idiom/ramp tax, 10–40s
  rebuilds, occasional derivation-writing for niche vendor binaries.
- **Ricing stays as files.** `~/.config/{hypr,quickshell}` via
  `mkOutOfStoreSymlink` into the live git checkout — edit and reload, no rebuild.
- **CLI is thin.** On NixOS `nixos-rebuild` does the real work, so `kiwami` is a
  wrapper, not a package manager.
- **Dev VM is aarch64**, native under HVF. Architecture is irrelevant for bar
  layout and launcher logic; GPU/kernel work happens on the real machine.
- **Never write a custom lock screen.** Keep `hyprlock` permanently.
- **Hyprland config in Lua** (v0.55+), not `hyprland.conf`. Decided before any
  binds were written, so there is nothing to port. Real logic in binds and rules
  stays in a language with functions and variables, and it matches the QML/JS
  side of the shell.

## Decisions still open

- (?) **Quickshell: from scratch vs fork.** Building from scratch is the stated
  goal; forking a public config to restyle is far faster. Possible split: fork to
  learn, rewrite once the API is familiar.
- (?) **Impermanence now or later.** Adopting later is an afternoon *if* the
  persist list is tracked as we go. Track it from day one regardless.
- (?) **Dictation STT** — local whisper.cpp vs an API. Affects latency and
  whether the GPU matters.

---

## Tier 2 — Agent VM loop  `[x] DONE`

- [x] QEMU aarch64 NixOS guest on macOS, HVF-accelerated
- [x] QMP channel — `screendump` → PNG, `sendkey`
- [x] Serial channel — run commands, capture stdout + exit code, auto-login
- [x] SSH channel — key auth, port-forwarded
- [x] Unattended install (`just vm install`, ~3 min, verified end to end)
- [x] Snapshot / restore (`just vm reset`)
- [x] `just` module interface as a stable API boundary
- [x] 13 gotchas documented in `vm/README.md`
- [ ] `nixosTest` harness alongside the manual one (needs a Linux host)
- [ ] CI: run the VM test on x86_64 GitHub runners, screenshots as artifacts

## Tier 0 — Foundation  `[~] IN PROGRESS`

- [x] Convert `vm/config/configuration.nix` into a flake
- [x] `hosts/vm-aarch64/` + `modules/common.nix`; `hosts/desktop/` still todo
- [x] Nix on the Mac (Determinate 3.22.2 / Nix 2.35.2) — lock + eval locally
- [x] `flake.lock` pins nixpkgs, home-manager, quickshell
- [x] VM rebuilt from the flake and **rebooted into it** (generation 3)
- [x] `install.sh` installs via `nixos-install --flake`; `vm/config/` deleted,
      so the flake is the single definition of the machine
- [x] Public repo at github.com/jimzer/kiwami — `nixos-install --flake
      github:jimzer/kiwami#<host>` verified to produce the same derivation as
      the local tree
- [x] Hyprland 0.55.4 autostarting via greetd in the VM, config in Lua
- [x] `mkOutOfStoreSymlink` wiring — `~/.config/hypr` resolves to the working
      tree, so `just vm reload` is edit -> `hyprctl reload`, no rebuild
- [x] Home Manager wired as the package/dotfile layer only
- [ ] `hosts/desktop/`
- [ ] `mkOutOfStoreSymlink` wiring for the live QML/Hyprland checkout
- [ ] Home Manager as **package layer only** (`home.packages`, git, ssh, direnv)
- [ ] Hyprland autostarting in the VM, with `SUPER+Return → terminal` and
      `SUPER+SHIFT+R → restart qs` hardcoded on disk (never lock yourself out)
- [ ] Pin Quickshell as a flake input (`github:quickshell-mirror/quickshell`)
- [ ] Track the impermanence persist-list from the start
- [ ] Install NixOS on the real desktop; generate + commit its
      `hardware-configuration.nix`

## Tier 1 — The product

- [ ] **Bar** — workspaces, clock, focused window; top/bottom as one setting
- [ ] **Launcher** — `DesktopEntries` + filter + Enter (~80 lines)
- [ ] **Theme pipeline** — one `colors.toml` feeding Hyprland + QML + kitty.
      *Do this before the third widget or it becomes a retrofit.*
- [ ] **`kiwami` CLI** — `update`, `rollback`, `doctor` only
- [ ] **`kiwami doctor`** — strays in `~/.local/bin`, `npm -g`, `cargo install`,
      and `nix profile list` must be empty (declarative-only invariant)
- [ ] **Power menu** — five exec lines, disproportionate payoff
- [ ] **Tray** — you will miss it on day two
- [ ] **Audio / brightness OSD** + battery

## Tier 3 — Differentiators

- [ ] **Push-to-talk dictation** — bind → `pw-record` → whisper → `wl-copy` +
      QML overlay pill. Ship clipboard-only; `wtype` injection is a best-effort
      flag, never a promise.
- [ ] Wrapped vendor binaries as flake outputs (Claude etc.)
- [ ] Clipboard manager, emoji picker
- [ ] Calendar popup on clock click (local month only, no sync)
- [ ] Notifications replacing mako — only after the bar is stable for weeks

## Tier 4 — Packaging

- [ ] `nix build .#iso` installer image
- [ ] Impermanence (root + `$HOME` on tmpfs, declared persistence)
- [ ] Dock — pick bar *or* dock as primary; two layout systems is two
      reserved-space bugs
- [ ] Plugin loading from `~/.config/kiwami/plugins/`

## Cut — do not build

Plugin marketplace · custom lock screen · calendar sync · per-machine theme
variants · anything requiring other people to adopt it

---

## Known debt

- **`graphical-session.target` is inactive.** `start-hyprland` sets up dbus,
  exports `WAYLAND_DISPLAY`, and starts the portals, but does not activate the
  target that user units bind to via `WantedBy=graphical-session.target`.
  Fine while the shell is launched with `hl.on("hyprland.start", ...)`; must be
  fixed (probably `programs.uwsm.enable` + `programs.hyprland.withUWSM`) before
  running Quickshell as a systemd user service.

- `hardware-configuration.nix` for the VM mounts **by label**, not UUID, because
  `just vm install` reformats and mkfs generates new UUIDs each time. Real
  hardware must use the generated UUIDs.
- VM credentials are hardcoded (`nixos`/`kiwami`) — fine for a throwaway guest,
  must not leak into the desktop host
- No CI; every check is manual
- `vm/scripts/install.sh` is verified only against the aarch64 QEMU guest
- The VM has no GPU (llvmpipe): validates layout and logic, not animation

## Ordering rules worth keeping

1. Theme pipeline before widget #3.
2. `kiwami doctor` before tools start accumulating.
3. No custom ISO until the shell has been daily-driven for a month.
4. Nothing in Tier 3+ until Tier 1 is boring.
