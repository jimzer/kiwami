# Kiwami dev VM

An aarch64 NixOS VM on macOS, drivable by an agent. HVF-accelerated, so it runs
at native speed on Apple Silicon.

## Verified capabilities

| Capability | Mechanism | Status |
|---|---|---|
| Boot NixOS aarch64 | QEMU `-M virt` + edk2 UEFI + HVF | works |
| Run commands, read output + exit code | serial unix socket (`console.py`) | works |
| Screenshot the framebuffer | QMP `screendump` → PNG | works |
| Inject keystrokes | QMP `sendkey` | works, see caveat |
| Fast shell / file transfer | SSH on `localhost:2222` | works |
| Reset to a known state | `qemu-img snapshot -a` | works |

## Usage

Everything goes through `just`. Recipe names are the stable interface —
`scripts/*` are implementation details and may change.

```bash
just vm                       # list commands
just vm install               # wipe disk, unattended NixOS install (~2 min)
just vm start                 # boot headless, detached
just vm gui                   # boot with a window you can click in
just vm status                # qemu / qmp / serial / ssh health
just vm ssh 'uname -a'        # run a command in the guest
just vm run 'systemctl ...'   # same, over serial (works before ssh is up)
just vm screenshot bar        # -> screenshots/bar.png
just vm reset                 # stop, restore 'installed' snapshot, boot
just vm stop
```

`gui` and `headless` share one disk image — you can sit in the VM yourself,
then let the agent drive the same machine.

Requires `just >= 1.31` for module support (`mod vm` in the root justfile).

## Layout

```
scripts/run-vm.sh          QEMU invocation
scripts/install.sh         drives `kiwami install` end to end
scripts/install-test.sh    installer matrix against scratch disks
scripts/start-vm.sh        detached launcher (survives tool timeouts)
scripts/console.py         serial console driver: expect / run / send
scripts/qmp.py             QMP client: screenshot / key / type
scripts/vmssh              ssh wrapper
scripts/snapshot.sh        disk snapshot management
scripts/stop-vm.sh         graceful shutdown
disks/  iso/  keys/        gitignored artifacts
```

## Gotchas found the hard way

- **UEFI shell needs CR, not LF.** `\n` does not submit a command; `\r` does.
- **`boot.loader.efi.canTouchEfiVariables` must be `true`**, or systemd-boot never
  registers an NVRAM entry and the firmware falls through to the EFI shell.
- **BootOrder puts new entries last.** After install, reorder so `Linux Boot
  Manager` is first: `efibootmgr -o 0003,...`. Stored in `disks/edk2-vars.fd`;
  deleting that file re-breaks unattended boot.
- **QMP `sendkey` coalesces repeated identical keys** — `&&` arrives as `&`. Use
  the serial console or SSH for text; reserve `sendkey` for single keybinds.
- **`console.py run` wraps commands in a subshell** (`( cmd )`). The naive
  `echo S; cmd; echo E$?` form is a *syntax error* when `cmd` ends in `&`
  (`& ;`), which silently ran nothing. Consequence: `cd` and exports do not
  persist between `run()` calls — use `send()` for stateful things like
  `sudo -i`.
- **Boot order is fixed via `nixos-enter --root /mnt -- efibootmgr`**, using the
  freshly installed system rather than `nix-shell` on the ISO, so it needs no
  network and no channel.
- **Sentinel echo race.** The terminal echoes the command line, so a naive
  `expect(END)` matches the *echoed command* and parses before the command has
  run — intermittently, only when the line is long enough to arrive in its own
  read. Fixed by quoting the nonce (`echo __E"$n"__$?`) so the echoed line does
  not contain the literal sentinel.
- **`expect()` scans the whole buffer, including seeded history.** An old
  `Password:` in the log matched instantly and desynchronised the entire login
  sequence. `login()` clears the buffer before every step.
- **`mkfs` returns before udev creates `/dev/disk/by-label/*`.** Mounting by
  label straight after formatting races; `udevadm settle` plus mounting by
  device path avoids it.
- **`findmnt` takes one target.** `findmnt /mnt /mnt/boot` returns 1 and silently
  broke an `&&` chain whose mounts had actually succeeded.
- **`console.py` seeds its buffer from `serial.log`**, because QEMU does not
  replay pre-connection output on the socket.
- **`snapshot.sh list` needs `qemu-img -U`** to read an image the running VM holds a lock on.
- **No `setsid` on macOS** — `start-vm.sh` uses a Python `fork`+`setsid`.

The guest's configuration is not here — it comes from `hosts/vm-aarch64` in
the flake, the same as any other machine.

## Guest

`kiwami-vm`, user `nixos` / password `kiwami`, passwordless sudo, key auth via
`keys/kiwami_vm`. Serial console stays enabled after install
(`console=ttyAMA0,115200`) so the harness works with no graphical session.

## Limits

No GPU — software rendering only. Fine for Quickshell layout, launcher logic, and
IPC; useless for judging Hyprland animation smoothness. aarch64, not x86_64, so
kernel/NVIDIA/CUDA work needs the real machine.
