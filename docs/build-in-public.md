# Kiwami — raw material for build-in-public posts

Notes, not posts. Each **moment** below is self-contained: a hook, the concrete
detail, and the turn. Pull one, write it in your own voice, ship it.

Written first-person as you, since that's how it'll be posted.

---

## The one-line version

I'm building my own Linux distro — NixOS underneath, Hyprland, a desktop shell
written from scratch — and almost all of it is built by an AI agent that drives
a QEMU VM on my Mac. Last night it moved onto real hardware: it installed the
thing on my XPS 13 over Tailscale, and now iterates on it while I watch.

## The arc

1. Argue about Arch vs NixOS. Pick NixOS. Regret nothing.
2. Agent boots a VM, writes an installer, installs the machine, screenshots it.
3. Everything works in the VM. **Everything.**
4. Put it on a real laptop. Four bugs in an hour, none of which the VM could
   ever have produced.
5. Make the machine wipe itself at every boot. Discover what that breaks.
6. End up with a laptop whose entire state is 776 KB.

---

## Moments

### 1. The installer refused to run on the installer

`kiwami install` checked for `/etc/NIXOS` to decide "am I on an installed
system?" — and refused if it found one. Turns out the live NixOS ISO has that
file too. So the installer refused to run on the one machine it exists for.

Nothing caught it: the automated install passes `--force`, and the test suite
only ever asserted the refusal *from an installed system*, where it was right
for the wrong reason. Green for weeks.

Found it 60 seconds after booting the ISO in a window and looking at it.

**Turn:** a test that only checks the half you thought about is a test that
teaches you it checked everything.

---

### 2. My VM never had the thing the code depended on

The installer names disks by `/dev/disk/by-id/...` — stable names built from
the drive's model and serial — because `/dev/sda` is a position in a queue, and
positions move.

Except QEMU doesn't give virtual disks a serial unless you ask. So `by-id`
entries never existed in my VM, and the code path that used them was never
exercised. My entire dev environment was quietly taking a different route
through the code than any real machine.

Nothing failed. Nothing was red. I only found it because I checked whether the
names existed before relying on them.

**Turn:** a test environment that's *easier* than reality reports success right
up until the moment it matters.

---

### 3. Then real hardware produced a fourth name

Fixed the above, gave the VM disks serials, wrote a preference rule: pick the
readable `model_serial` name over the opaque ones.

Ran it on the actual laptop. Real NVMe offers a form QEMU never emits —
`nvme-eui.335a48304d6407070025384100000001` — which my rule didn't recognise
*and* which happened to be the shortest, so it won the tiebreak outright.

The config would have been written with 32 hex digits instead of
`nvme-PM981_NVMe_Samsung_512GB__S3ZHNA0M640707`.

Both are stable. Only one is legible. That machine's actual disk aliases are
now a unit test.

---

### 4. The test image was built without the key it existed to carry

I made a variant of the installer image whose *entire purpose* was carrying an
SSH key so the harness could drive it.

The build copies a subset of the repo. `vm/` wasn't in the subset. So the key
file wasn't there, `builtins.pathExists` returned false, and my code degraded
to "no key" — cheerfully producing an image that could not do the one thing it
was for.

Symptom: SSH refused a connection, several minutes later.

**Turn:** `if exists then x else default` is where silent wrongness lives. It
`throw`s now.

---

### 5. `sudo passwd` said "password updated successfully" and changed nothing

On an immutable-users NixOS the password comes from a file; `/etc/shadow` is
regenerated at activation. An unprivileged `passwd` fails loudly — fine.

`sudo passwd` prints **"password updated successfully"** and is silently
reverted at the next activation. I tested it rather than assuming.

I started building a check to *detect* this. The person I'm building for said:
just remove the utility. He was right. Detection tells you afterwards; removal
means it can't happen. `passwd` is now shadowed by a script that says
`sudo kiwami passwd` and exits non-zero.

**Turn:** deleting a footgun beats detecting it.

---

### 6. The config documented a feature it didn't have

For hours, every generated `disk.nix` carried a comment saying *"no swap
partition: zram is used instead."*

`zramSwap` was never enabled. Anywhere. The machines had no swap at all — so
under pressure the kernel's only move was evicting the page cache it runs from,
then the OOM killer.

I'd written a claim into config that ships on the user's disk. The machine
would have documented a feature it did not have.

---

### 7. Impermanence, and the bug that only exists on an ephemeral machine

The laptop now wipes its root filesystem at every boot. What survives is what
the config names — nothing accumulates that nobody asked for.

First attempt: installed fine, booted fine, refused every SSH connection.

The installer writes things into the new system: the SSH key, the flake it
rebuilds itself from, the wifi profiles, the tailnet identity. All onto the root
— which is *deleted on first boot*, and then **masked by an empty bind mount**
from the persist volume.

So declaring a path as "must survive" made writing it to the root *worse* than
not declaring it at all. Five features I'd built that same evening, all silently
incompatible, none of them wrong on a normal machine.

**Turn:** the failure mode of a wipe isn't losing data. It's losing the thing
that lets you fix it.

---

### 8. A machine that erases its own configuration

Same territory, sharper: `~/kiwami` — the flake the machine rebuilds itself
from — lives in the home directory. Home is wiped.

Without declaring it, you get a working laptop you can never change again.

---

### 9. The report that scanned three directories I'd thought of

`doctor` answers "what will tonight's reboot eat?" First version scanned
`/var/lib`, home, and `/etc` — a hardcoded list, blind to everything else, and
needing an edit every time a package shipped config.

The person I'm building for pushed back: shouldn't it just be *everything on
the root that isn't persisted*?

Yes. And what "comes back" is four questions the system already answers:

- is it a symlink into the store? → Nix rewrites it
- is it in `/etc/static`? → NixOS's own record of what it manages
- is it in home-manager's `home-files`? → its record for your home
- does a systemd tmpfiles rule create it? → comes from the units

36 paths → 27 → 14 → **5**. And none of it needs maintaining when I install
software.

What's left isn't "will it come back" — that's mechanical. It's "do I care that
it's gone", which no tool can answer and is exactly the list worth reading.

---

### 10. 776 KB

The whole state of that laptop — passwords, wifi, SSH host keys, tailnet
identity, uid allocations — is **776 KB**.

The other **7.9 GB** is the Nix store, rebuilt from a git repo and a lock file.

Back up the first, and the machine is a git clone away from existing again.

---

### 11. I read a silence as evidence

Late on, my SSH to the laptop started hanging. I assumed I'd broken something
and went looking, twice.

Tailscale SSH was printing `# additional check required — visit this URL` and
waiting. I was connecting with `BatchMode` and long timeouts, so I saw a hang
instead of the message that was on the wire the whole time.

Nothing was broken. A 12-hour token had expired.

**Turn:** same mistake as everything else in this list — trusting the absence
of output instead of reading what was actually said. Except this time it was my
own tooling.

---

## The thread that ties it together

Almost every real bug was **something reporting success while doing nothing**.

- an installer refusing the machine it was written for
- a "test" image built without its key
- `passwd` printing success and reverting
- config documenting swap that didn't exist
- a persisted path that was deleted and then hidden
- two green CI runs on a completely broken desktop shell

And the second theme, which I'd argue is the more useful one:

**Anything the test harness does for convenience is a feature the product
probably lacks.**

My install script placed the flake in the user's home, corrected the UEFI boot
order, and seeded a password. All three were missing from the actual installer,
and every VM install came out perfect while the real thing was broken. Each fix
included *deleting the workaround*, so the test now fails if the product stops
doing its job.

## Numbers worth quoting

- **776 KB** of state vs **7.9 GB** of store
- **83 s** to build a 1.5 GB bootable ISO in CI
- **36 → 5** paths in the "what will you lose" report
- **39** installer checks on an installed system, **36** on live media
- **4** bugs in the first hour on real hardware that a VM could never produce
- **2** green CI runs on a desktop shell that was completely broken

## Angles for longer pieces

- *Why I let an agent drive a VM instead of writing the code myself* — the loop
  is edit → push → rebuild → screenshot → read logs, and the screenshot is what
  makes it work.
- *Assert effects, not appearances.* "The shell is running" is `pgrep`, which a
  crashlooping process satisfies. "The shell works" is a bounded restart count
  plus a mapped layer surface.
- *A warning that fires on every healthy machine is worse than no warning.*
- *Ephemeral root is a forcing function*: it turns "what state does my machine
  actually have" from a vague worry into a five-line list.
- *The best correction in the whole build came from the human*: remove the
  footgun instead of detecting it.

## Tone notes

Keep the specifics — hex device names, the exact wrong message, the numbers.
The story is not "AI built my OS", it's "here is precisely how software lies
about working, and what it took to notice." The bugs are the content.

Don't tidy the failures into a smooth narrative. The interleaving *is* the
point: it worked in the VM, then it didn't on hardware, then the fix broke the
test, then the test was wrong too.
