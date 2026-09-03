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

## Why this is worth building (the actual pitch)

The failures below are the entertaining part. This is the part that makes the
failures worth having.

### The machine is a git repo

Not "configured by" a git repo — *is* one. `hosts/xps/` is three files: what the
hardware is, what I chose, how the disk is laid out. Everything else is shared
with every other Kiwami machine. Reinstall from that commit and you get the same
machine, byte for byte, because the lock file pins every input.

Which means: **rebuild is a normal operation, not a disaster.** Wrong kernel?
Reboot into the previous generation from the boot menu. Bad experiment? Revert
the commit. Nothing is a one-way door.

### Nothing accumulates

The root filesystem is **deleted and recreated blank at every boot.** What
survives is a list you wrote: passwords, wifi, SSH host keys, your files, the
flake itself.

The usual Linux experience is a machine that drifts — a config you edited in
2023, a service you removed whose state is still in `/var/lib`, a `~/.config`
full of things you can't account for. Here that's structurally impossible.
Anything you didn't name is gone by morning.

The payoff is a question you can suddenly answer: **what state does my computer
actually have?** Mine: five paths, three of which are caches.

### 776 KB

That's the entire state of the laptop. Passwords, wifi profiles, SSH host keys,
tailnet identity, uid allocations. The other 7.9 GB is the Nix store, which is
*derivable* — a function of the repo and the lock file.

Back up 776 KB and a git remote, and the machine is reconstructible. Not
"restorable from an image" — reconstructible from a description.

New laptop? Install, restore state, done. Dead SSD? Same. The difference between
those two cases is one exclude list — whether the new machine inherits the old
one's *identity* (SSH host keys, tailnet node) or gets its own.

### The installer is one command and four questions

Boot the image, it starts by itself:

- get on the network (wifi menu if needed)
- want someone to be able to help? → joins your tailnet, no key baked anywhere
- which machine is this — pick one, or name a new one
- which disk, separate `/home`?, encrypt?

Then it shows you the disk layout it wrote, lets you edit it, and waits for you
to type `yes`. Afterwards it detects your hardware, writes it into the repo,
sets the boot order, carries your wifi and tailnet identity onto the new system,
and leaves the flake in your home directory.

Nothing to remember. Nothing typed twice.

### It can be worked on remotely

`kiwami remote` puts the machine on your tailnet with no key baked into the
image and no secret in the repo — it prints a URL you approve from your phone.
From there the whole loop works over the network: edit the shell's QML, push,
rebuild on the laptop, trigger the launcher, screenshot it, look.

That's how the desktop got debugged on real Intel graphics from a Mac in another
room.

### The machine tells you when it's drifting

`kiwami doctor`:

- packages installed imperatively instead of declared
- stray binaries in `~/.local/bin`, global npm/cargo installs
- failed units, a shell that's crash-looping rather than running
- whether the root actually got wiped this boot
- whether your password is still the install default
- what exists that nothing declared — i.e. what tonight's reboot will eat

The rule it follows: **assert effects, not appearances.** "The shell is running"
is `pgrep`, which a crashlooping process satisfies. "The shell works" is a
bounded restart count plus a mapped layer surface.

### Themes switch without a rebuild

Colours are typed options in Nix — a malformed hex value fails at evaluation,
not at render — but switching is a runtime operation. `kiwami theme set
midnight` retints the bar, the terminal and the compositor live. Declared like
everything else; instant like nothing else.

### And it's all one opinion

No "two modes" anywhere. Every machine is ephemeral. Every user is immutable.
There's one way to set a password, and `passwd` isn't it — it's been replaced by
a script that tells you the right command.

Every time I offered a choice, it produced a class of bug that only existed on
one side of it. So the answer became: don't offer the choice.

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

### 12. The test passed against a binary that never contained the fix

I wrote a test for the guided installer, ran it, and got a real failure: the
installer declared the machine had no wifi hardware and quit. That was the
same bug that had cost a real reinstall weeks earlier, now reproduced in a VM
in two minutes.

I fixed it. Reran. Same failure. Diagnosed deeper, fixed again. Same failure.

Then I looked at the top of the log instead of the bottom:

    tar: Write error
    error: recipe `push` failed with exit code 255

The ISO had never been rebuilt. The build pushes the source into a VM - macOS
cannot build Linux - and that VM was not running, because the test I had just
run had killed it. So the build failed, and I did not notice, because I had
written:

    just build-iso 2>&1 | tail -2 && just guided-test

A pipeline's exit status is the *last* command's. `tail` always succeeds. So
`&&` ran the test regardless, against the previous image, twice, and I
diagnosed the product from a binary that never contained my fix.

Every bug in this list is some version of "it reported success while doing
nothing". This is the first one I built myself, in the tool I was using to
find the others.

### 13. The installer ran perfectly where nobody could see it

The same test, first run: the serial console showed a login prompt and a
shell. No installer. It is supposed to start on its own.

It was running - `pgrep` found it, pid 959, doing its job. On tty1. The
virtual console of a headless VM, which nothing renders and nobody watches,
while the serial line the operator is actually attached to sat idle.

The autostart was gated on `/dev/tty1`, which is right for a laptop and
useless for a headless machine. It now asks the kernel which console it is
using. A bug that only exists when nobody is looking at the screen is
difficult to see, for reasons that are almost too neat.

### 14. My own test matched the wrong string and went green

Same test again. Before finding that, it *passed* the assertion "the guided
installer starts with no keystroke".

It waited for the text `Kiwami installer`. That string appears in the
installer's banner - and also in the getty help text printed above the login
prompt. So the test went green against a console that was sitting at a shell,
having started nothing at all.

The fix is one word: wait for `==> checking network`, which only the installer
itself prints. But the lesson is the one this whole project keeps teaching -
a test that can pass for the wrong reason is worse than no test, because it
converts an absence into a green tick.

### 15. Ten minutes of a rented server that was never installed

Renting a bare-metal builder, the API said `status: ready`, so the script
sshed in. Permission denied. Then the host key changed. Then the machine went
dark entirely.

`status: ready` means the hardware is allocated. The OS install has a
*different* field, `install.status`, and it was still `installing`. The box I
had been talking to was the installer environment, which is why the key
changed underneath me when the real system finally booted.

Same shape as the flake in a shallow clone, the wifi query before
NetworkManager was up, the brightness marker with no file to watch: the thing
answered, it just was not the thing I thought I was asking.

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

- *A laptop with 776 KB of state* — what it means to back up a description
  instead of an image, and why "reinstall" stops being frightening.
- *Ephemeral root as a forcing function* — you cannot argue with a machine that
  deletes everything you didn't declare.
- *One opinion, no modes* — every either/or in this build produced a bug that
  lived on exactly one branch of it.

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
