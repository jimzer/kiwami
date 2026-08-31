# Kiwami — task tracker

A personal NixOS desktop: Hyprland plus a Quickshell shell written from
scratch, developed against a VM an agent can drive.

Legend: `[ ]` todo · `[~]` partial · `[x]` done · `(?)` open question

---

## Decisions

- **Base: NixOS.** Reversed twice before settling. Deciding factors:
  `flake.lock` pins Quickshell (an alpha dependency the whole desktop sits on),
  generations give rollback, packages are declared by construction, and
  `nixosTest` exists. Rebuild cost was *measured*, not assumed — 2.5s no-op,
  7.7s after a config change. The early "utter pain" framing was wrong.

- **The flake is the machine.** Configs are read-only store symlinks placed by
  Home Manager. Changing one means editing it here and rebuilding. A
  `~/.config` override layer was built and removed: it existed for someone who
  will not write Nix, who is not the audience, and it caused stale overrides,
  detached symlinks and three separate bugs.

- **Options are for multiple machines, not multiple users.**
  `kiwami.bar.position` is how a laptop differs from a desktop without forking
  QML, and what a consumer flake overrides.

- **Themes stay runtime.** Authored as typed Nix, generated to JSON, switched
  by `kiwami theme set` with no rebuild. Designing a palette needs instant
  feedback; it costs one file and a watcher.

- **Ship config in the app's own format.** `hyprland.lua` and `ghostty/config`
  are real files. Generating Ghostty's from a Nix attrset cost three mechanisms
  to express eight lines and bought nothing visible.

- **The session runs under UWSM**, so `graphical-session.target` activates.
  The shell is a user unit, not exec'd from Hyprland.

- **Hyprland config in Lua** (0.55+). Binds use loops and function calls, which
  Nix can only express as escaped strings.

- **Never write a custom lock screen.** `hyprlock` permanently.

- **Dev VM is aarch64** (native under HVF); CI builds and boots x86_64.

## Open

- (?) **Quickshell: keep writing from scratch, or read others' configs for the
  hard parts?** Current approach is from scratch, reading upstream's type stubs
  when stuck, which has worked.
- (?) **Impermanence timing.** Rehearse in the VM before the desktop is
  daily-driven — a forgotten path costs nothing there and everything on real
  hardware.
- (?) **Dictation STT** — local whisper vs an API.

---

## Done

**Foundation** — flake with pinned inputs, `hosts/{vm-aarch64,vm-x86_64}`,
Home Manager, UWSM session, `nixosModules.default` exported and verified from a
consumer flake pulling from GitHub.

**Desktop** — Hyprland 0.55, Ghostty, bar (workspaces, window title, clock,
tray, battery), launcher merging apps with CLI actions, power menu, volume OSD,
notifications, theme pipeline with live retint.

**Options** — `kiwami.*` typed; colours are `types.strMatching "#[0-9a-fA-F]{6}"`,
which rejects at eval the malformed value that once shipped. Bar composes from
a generated manifest; widgets resolve by filename.

**CLI** — `install` (disk detection, selection, refusals, confirmation),
`theme`, `doctor`, `commands --json`.

**Harness** — 3-minute unattended install, QMP/serial/SSH channels,
snapshot/reset, installer matrix (13 checks), CI on x86_64 (evaluate, build,
boot test with screenshots).

---

## Next

### Clipboard and emoji
- [ ] Extract `Picker.qml` from `Launcher.qml` — the refactor is the work; both
      features fall out of it
- [ ] `cliphist` as a user unit; `SUPER+V`
- [ ] Emoji dataset in the store; `SUPER+.`
- [ ] Copy on select. Paste needs synthetic input and stays a flag, never a
      promise

### Custom ISO
- [ ] `nixosConfigurations.installer` from `installation-cd-minimal.nix`, with
      `kiwami` baked in and flakes enabled
- [ ] Carry the flake rather than fetch it — an installer that needs DHCP to
      work is a bad installer
- [ ] Autologin into the installer
- [ ] Build in CI (x86_64 cannot be built on the Mac); boot it in the VM and
      run the existing matrix against it

### Impermanence
- [ ] **Phase 0, start now:** generate `/etc/kiwami/persist.json` from the
      config and have `doctor` report paths that exist and are not persisted.
      Pure reporting, builds the list empirically
- [ ] Phase 1: rehearse in the VM with a generous list, reinstall, see what
      breaks
- [ ] Phase 2: tighten. Phase 3: real machine
- [ ] Non-obvious entries: `/etc/ssh/ssh_host_*` (or SSH warns every boot),
      `/var/lib/systemd` (machine-id, journal), `/var/lib/nixos` (uid/gid
      allocation)
- [ ] Keep a btrfs snapshot of a pristine root so the diff answers "what did I
      forget" instead of guessing

### Real hardware  *(blocked: needs the machine)*
- [ ] `hosts/desktop/` with a generated `hardware-configuration.nix`
- [ ] Brightness OSD and battery widget are written and wired but **never
      rendered** — the VM has no backlight and no battery, so both paths only
      prove they hide cleanly
- [ ] One installer run on real firmware. Vendor UEFI quirks are what QEMU
      cannot model, and we already saw a preview when edk2 put the boot entry
      last in `BootOrder`

### Smaller
- [ ] Calendar popup on the clock (local month, no sync)
- [ ] Bar top/bottom is an option but only `top` has been looked at carefully
- [ ] `kiwami update` / `rollback` — thin wrappers, worth it once there is a
      machine to live on
- [ ] Push-to-talk dictation: bind → `pw-record` → whisper → `wl-copy` + an
      overlay pill

## Cut

Plugin marketplace · custom lock screen · calendar sync · per-machine theme
variants · anything that assumes a user who will not write Nix

## Known debt

- CI's boot test asserts the desktop comes up; it does not check that widgets
  render correctly
- `vm/scripts/install.sh` is verified only against the aarch64 QEMU guest
- The VM has no GPU (llvmpipe): validates layout and logic, not animation
