//! The Kiwami installer.
//!
//! Runs from the live ISO. Everything here is destructive, so the ordering is
//! deliberate: detect, then select, then confirm, and only then touch a disk.
//! Nothing before the confirmation writes anything.

use std::fmt;
use std::fs;
use std::io::{self, BufRead, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use crate::net;

/// Give generated files back to whoever owns the checkout.
///
/// The installer runs as root, so anything it writes into your repository is
/// root-owned - you would need sudo to edit your own machine's config, and
/// tools that rewrite the tree (rsync, git checkout) fail outright.
fn chown_to_repo(repo: &Path, target: &Path) -> Result<(), String> {
    use std::os::unix::fs::MetadataExt;
    let Ok(meta) = fs::metadata(repo) else { return Ok(()) };
    let (uid, gid) = (meta.uid(), meta.gid());

    let mut stack = vec![target.to_path_buf()];
    while let Some(p) = stack.pop() {
        let _ = std::os::unix::fs::chown(&p, Some(uid), Some(gid));
        if p.is_dir() {
            if let Ok(entries) = fs::read_dir(&p) {
                stack.extend(entries.filter_map(|e| e.ok()).map(|e| e.path()));
            }
        }
    }
    Ok(())
}

/// Refuse anything smaller than this. Below it the install fails partway
/// through, which is worse than refusing up front.
const MIN_BYTES: u64 = 20 * 1024 * 1024 * 1024;

#[derive(Clone)]
pub struct Disk {
    pub name: String,
    pub path: PathBuf,
    pub bytes: u64,
    pub model: String,
    pub removable: bool,
    /// Existing partitions. Non-empty means we are about to destroy something.
    pub partitions: Vec<String>,
    /// A filesystem from this disk is mounted right now. On the ISO that is
    /// normal for the USB stick; on a running system it is your root.
    pub in_use: bool,
}

impl Disk {
    pub fn is_empty(&self) -> bool {
        self.partitions.is_empty()
    }
    fn gib(&self) -> f64 {
        self.bytes as f64 / (1024.0 * 1024.0 * 1024.0)
    }
}

impl fmt::Display for Disk {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{:<12} {:>8.1} GiB  {}", self.path.display(), self.gib(), self.model)?;
        if self.removable {
            write!(f, " [removable]")?;
        }
        if !self.is_empty() {
            write!(f, "  ** {} existing partition(s) **", self.partitions.len())?;
        }
        if self.in_use {
            write!(f, "  ** IN USE - mounted right now **")?;
        }
        Ok(())
    }
}

/// Enumerate real block devices. Skips loop/ram/zram devices and optical
/// drives, which are never install targets and would only pad the menu.
pub fn disks() -> io::Result<Vec<Disk>> {
    let mounted = mounted_devices();
    let mut out = Vec::new();
    for entry in fs::read_dir("/sys/block")? {
        let entry = entry?;
        let name = entry.file_name().to_string_lossy().to_string();
        if name.starts_with("loop")
            || name.starts_with("ram")
            || name.starts_with("zram")
            || name.starts_with("sr")
            || name.starts_with("fd")
            || name.starts_with("dm-")
        {
            continue;
        }
        // NVMe exposes a controller-scoped alias of every namespace as
        // nvme<N>c<M>n<K>, pointing at the same storage as nvme<N>n<K>.
        // Listing both offers the same disk twice under two names.
        if is_nvme_controller_alias(&name) {
            continue;
        }
        let base = entry.path();

        // /sys reports size in 512-byte sectors regardless of physical sector size.
        let sectors: u64 = fs::read_to_string(base.join("size"))
            .ok()
            .and_then(|s| s.trim().parse().ok())
            .unwrap_or(0);
        if sectors == 0 {
            continue;
        }

        let model = fs::read_to_string(base.join("device/model"))
            .map(|s| s.trim().to_string())
            .unwrap_or_else(|_| "unknown".into());
        let removable = fs::read_to_string(base.join("removable"))
            .map(|s| s.trim() == "1")
            .unwrap_or(false);

        // A partition appears as a subdirectory carrying its own `partition` file.
        let mut partitions: Vec<String> = fs::read_dir(&base)?
            .filter_map(|e| e.ok())
            .filter(|e| e.path().join("partition").exists())
            .map(|e| e.file_name().to_string_lossy().to_string())
            .collect();
        partitions.sort();

        let in_use = mounted.iter().any(|m| m == &name || partitions.contains(m));

        out.push(Disk {
            path: PathBuf::from(format!("/dev/{name}")),
            name,
            bytes: sectors * 512,
            model,
            removable,
            partitions,
            in_use,
        });
    }
    out.sort_by(|a, b| a.name.cmp(&b.name));
    Ok(out)
}

/// `nvme0c0n1` is the controller alias for `nvme0n1` - same device, second
/// name. Matches nvme<digits>c<digits>n<digits>.
fn is_nvme_controller_alias(name: &str) -> bool {
    let Some(rest) = name.strip_prefix("nvme") else { return false };
    let Some((ctrl, rest)) = rest.split_once('c') else { return false };
    let Some((inst, ns)) = rest.split_once('n') else { return false };
    !ctrl.is_empty()
        && !inst.is_empty()
        && !ns.is_empty()
        && ctrl.chars().all(|c| c.is_ascii_digit())
        && inst.chars().all(|c| c.is_ascii_digit())
        && ns.chars().all(|c| c.is_ascii_digit())
}


/// Read one answer.
///
/// End of input is an error, not an empty answer. Every menu here loops until
/// it gets something valid, so returning "" on EOF makes each of them spin
/// forever printing its retry message - which is exactly what a closed stdin
/// looks like to a piped test or an unattended run.
fn prompt(question: &str) -> io::Result<String> {
    print!("{question}");
    io::stdout().flush()?;
    let mut line = String::new();
    if io::stdin().lock().read_line(&mut line)? == 0 {
        return Err(io::Error::new(io::ErrorKind::UnexpectedEof, "no more input"));
    }
    Ok(line.trim().to_string())
}

fn run(cmd: &str, args: &[&str]) -> Result<(), String> {
    let status = Command::new(cmd)
        .args(args)
        .status()
        .map_err(|e| format!("{cmd}: {e}"))?;
    if status.success() {
        Ok(())
    } else {
        Err(format!("{cmd} {} failed ({status})", args.join(" ")))
    }
}

pub struct Options {
    pub disk: Option<String>,
    /// Host attribute to install. Resolved against the flake, and prompted
    /// for when omitted - there is no sensible default, and guessing one
    /// means discovering it was wrong after the disk is already erased.
    pub host: Option<String>,
    pub flake: String,
    pub assume_yes: bool,
    pub force: bool,
    /// Create hosts/<name>/ if the flake does not define it yet.
    pub new_host: bool,
    /// Rewrite hardware.nix even if one is already committed.
    pub regen_hardware: bool,
}

pub fn run_install(opts: Options) -> Result<(), String> {
    // Refuse to run on a machine that is already installed.
    //
    // This used to test for /etc/NIXOS, on the belief that only an installed
    // system has it. The live ISO has it too, so the guard fired on the one
    // place the installer is meant to run. Nothing caught it because the
    // automated install passes --force.
    if !on_installer_media() && !opts.force {
        return Err("this looks like an installed NixOS system, not the installer ISO.\n\
                    Refusing to continue. Pass --force if you really mean it."
            .into());
    }

    // Check this before anything else. Discovering it after the user has
    // confirmed a destructive action means failing halfway through
    // partitioning, which is the worst possible moment.
    if !is_root() {
        return Err("must run as root (try: sudo kiwami install)".into());
    }

    // The install downloads its whole closure from the binary cache, so this
    // has to pass before anything else. `--yes` implies unattended, and an
    // unattended run must not sit on a wifi password prompt.
    println!("==> checking network");
    net::ensure(!opts.assume_yes)?;

    // Resolve the host now, while the disk is still intact. This costs one
    // cheap eval - `builtins.attrNames` does not force the configurations -
    // and it is the difference between "unknown host" and "unknown host,
    // reported after your disk was erased".
    println!("==> resolving {}", opts.flake);
    let checkout = local_checkout(&opts.flake);
    let host = resolve_host(
        &opts.flake,
        opts.host.clone(),
        opts.assume_yes,
        opts.new_host,
        checkout.is_some(),
    )?;
    println!("    host: {}", host.name);
    if host.create {
        println!("    will scaffold hosts/{}", host.name);
    }

    let disks = disks().map_err(|e| format!("cannot enumerate disks: {e}"))?;
    if disks.is_empty() {
        return Err("no disks found".into());
    }
    // select_disk consumes the list; the wizard still needs the others to
    // offer as a /home target.
    let disks_snapshot = disks.clone();

    // An existing host already declares its disks, so that is the target.
    let declared = if host.create { Vec::new() } else { host_disks(&opts.flake, &host.name)? };

    let mut targets: Vec<Disk> = if declared.is_empty() {
        // No declaration yet - a new host, whose disk.nix is written from
        // this choice.
        let target = match &opts.disk {
            Some(want) => {
                let want =
                    if want.starts_with("/dev/") { want.clone() } else { format!("/dev/{want}") };
                disks
                    .into_iter()
                    .find(|d| d.path.to_string_lossy() == want)
                    .ok_or_else(|| format!("no such disk: {want}"))?
            }
            None => select_disk(disks)?,
        };
        vec![target]
    } else {
        if let Some(want) = &opts.disk {
            let want =
                if want.starts_with("/dev/") { want.clone() } else { format!("/dev/{want}") };
            if !declared.iter().any(|d| d.to_string_lossy() == want) {
                return Err(format!(
                    "--disk {want} is not what {} declares.\n\
                     Its disk.nix names: {}\n\
                     Edit disk.nix instead - the layout is what formats, not this flag.",
                    host.name,
                    declared.iter().map(|d| d.display().to_string()).collect::<Vec<_>>().join(", ")
                ));
            }
        }
        let mut found = Vec::new();
        for dev in &declared {
            let d = disks.iter().find(|d| &d.path == dev).ok_or_else(|| {
                format!("{} is declared by {} but not present here", dev.display(), host.name)
            })?;
            found.push(d.clone());
        }
        found
    };

    for t in &targets {
        if t.in_use && !opts.force {
            return Err(format!(
                "{} is mounted right now - this looks like the system you are running.\n\
                 Refusing to erase it. Pass --force if you really mean it.",
                t.path.display()
            ));
        }
        if t.bytes < MIN_BYTES {
            return Err(format!(
                "{} is {:.1} GiB; Kiwami needs at least {} GiB",
                t.path.display(),
                t.gib(),
                MIN_BYTES / (1024 * 1024 * 1024)
            ));
        }
    }

    // A host with no declaration gets one now, from four questions - and it
    // is written and reviewed before anything is erased, so the last thing
    // seen before the point of no return is the actual layout.
    if declared.is_empty() {
        let Some(repo) = &checkout else {
            return Err(format!(
                "{} is not a local checkout, so a disk layout cannot be written into it.\n\
                 Clone the flake first, then install from that path.",
                opts.flake
            ));
        };
        let layout = ask_layout(&disks_snapshot, &targets[0])?;
        let host_dir = repo.join("hosts").join(&host.name);
        // Whether this directory is ours to remove again if the review is
        // abandoned. Leaving a half-written host behind is not harmless: the
        // next run finds it already declared and skips the wizard entirely.
        let ours = !host_dir.exists();
        fs::create_dir_all(&host_dir).map_err(|e| e.to_string())?;
        let path = host_dir.join("disk.nix");
        fs::write(&path, render_disk_nix(&layout)?).map_err(|e| e.to_string())?;

        // The rest of the host has to exist now too. disko's script is built
        // from this host, so a directory holding only disk.nix cannot be
        // formatted from - and a half-written host would break evaluation of
        // every other machine in the flake.
        if !host_dir.join("default.nix").exists() {
            scaffold_host(&host_dir, &host.name)?;
        }
        placeholder_hardware(&host_dir)?;
        chown_to_repo(repo, &host_dir)?;

        // Staged only once the layout is accepted - the flake must not be
        // left carrying a host nobody agreed to.
        if let Err(e) = review_layout(&path, opts.assume_yes) {
            if ours {
                let _ = fs::remove_dir_all(&host_dir);
            }
            return Err(e);
        }
        if repo.join(".git").exists() {
            git_add(repo, &host_dir)?;
        }

        // Every disk the layout touches, not just the one picked first.
        let mut wanted = vec![layout.system.clone()];
        wanted.extend(layout.home.clone());
        for dev in &wanted {
            if let Some(d) = disks_snapshot.iter().find(|d| &d.path == dev) {
                if d.in_use && !opts.force {
                    return Err(format!(
                        "{} is mounted right now. Refusing to erase it.",
                        d.path.display()
                    ));
                }
            }
        }
        targets = wanted
            .iter()
            .filter_map(|dev| disks_snapshot.iter().find(|d| &d.path == dev).cloned())
            .collect();
    }

    // Everything above this line is read-only.
    confirm(&targets, opts.assume_yes)?;

    // One step, from the host's own disk.nix: disko wipes, partitions,
    // formats and mounts. The layout is not restated here, which is the point
    // - it used to live twice, as parted calls in this file and as a
    // fileSystems module, agreeing only by comment.
    println!("\n==> partitioning and formatting from {}#{}", opts.flake, host.name);
    run_disko(&opts.flake, &host.name)?;

    // Only now is /mnt populated, which is what nixos-generate-config reads.
    if let Some(repo) = &checkout {
        let host_dir = repo.join("hosts").join(&host.name);
        let hardware = host_dir.join("hardware.nix");

        if host.create && !host_dir.join("default.nix").exists() {
            println!("==> scaffolding hosts/{}", host.name);
            scaffold_host(&host_dir, &host.name)?;
        }

        // A committed hardware.nix may have been tuned by hand; replacing it
        // silently on a reinstall is not ours to do. `kiwami doctor` reports
        // when it has drifted from what the machine actually reports.
        if opts.regen_hardware || host.create || !hardware.exists() {
            println!("==> detecting hardware");
            generate_hardware(&host_dir)?;
        } else {
            println!("==> keeping the committed hardware.nix (--regen-hardware to replace)");
        }

        chown_to_repo(repo, &host_dir)?;

        // Only when the checkout is a git repo. A plain directory flake
        // copies everything, so there is nothing to stage.
        if repo.join(".git").exists() {
            git_add(repo, &host_dir)?;
        }
    } else if host.create || opts.regen_hardware {
        return Err(format!(
            "{} is not a local checkout, so nothing can be written into it.\n\
             Clone the flake first, then install from that path.",
            opts.flake
        ));
    }

    println!("==> installing {} (this takes a while)", opts.flake);
    let flake_ref = format!("{}#{}", opts.flake, host.name);
    run("nixos-install", &["--flake", &flake_ref, "--no-root-passwd"])?;

    println!("\n==> done. Reboot into the installed system.");
    Ok(())
}

fn select_disk(disks: Vec<Disk>) -> Result<Disk, String> {
    println!("Disks:\n");
    for (i, d) in disks.iter().enumerate() {
        println!("  {}) {d}", i + 1);
    }
    println!();

    // A single disk still gets shown and confirmed rather than auto-picked:
    // "it only found one" is exactly when a wrong guess goes unnoticed.
    loop {
        let answer = prompt(&format!("Install to which disk? [1-{}] ", disks.len()))
            .map_err(|e| e.to_string())?;
        match answer.parse::<usize>() {
            Ok(n) if n >= 1 && n <= disks.len() => {
                return Ok(disks.into_iter().nth(n - 1).unwrap())
            }
            _ => println!("Enter a number between 1 and {}.", disks.len()),
        }
    }
}

fn confirm(targets: &[Disk], assume_yes: bool) -> Result<(), String> {
    println!();
    for t in targets {
        println!("About to install to {}", t.path.display());
        if !t.is_empty() {
            println!(
                "\n  WARNING: {} already has {} partition(s): {}",
                t.path.display(),
                t.partitions.len(),
                t.partitions.join(", ")
            );
            println!("  Everything on it will be destroyed.");
        }
    }

    if assume_yes {
        println!("\n--yes given, continuing.");
        return Ok(());
    }

    // Typing the whole word, not "y". This is the last chance to stop.
    let answer = prompt("\nType 'yes' to erase this disk and install: ")
        .map_err(|e| e.to_string())?;
    if answer != "yes" {
        return Err("cancelled; nothing was written".into());
    }
    Ok(())
}




/// Base names of block devices backing a current mount, e.g. ["vda1", "vda2"].
fn mounted_devices() -> Vec<String> {
    fs::read_to_string("/proc/mounts")
        .unwrap_or_default()
        .lines()
        .filter_map(|l| l.split_whitespace().next())
        .filter_map(|dev| dev.strip_prefix("/dev/"))
        .map(|d| d.to_string())
        .collect()
}

fn is_root() -> bool {
    // No libc dependency for one number: the kernel reports it in /proc.
    fs::read_to_string("/proc/self/status")
        .ok()
        .and_then(|s| {
            s.lines()
                .find(|l| l.starts_with("Uid:"))
                .and_then(|l| l.split_whitespace().nth(1).map(str::to_string))
        })
        .map(|uid| uid == "0")
        .unwrap_or(false)
}

/// The hosts this flake can install, straight from the flake itself.
///
/// `--extra-experimental-features` is passed explicitly because the stock
/// installer ISO does not enable flakes, and the failure without it is an
/// unhelpful "experimental feature not enabled" from a command the user
/// never typed.
fn flake_hosts(flake: &str) -> Result<Vec<String>, String> {
    let out = Command::new("nix")
        .args([
            "--extra-experimental-features",
            "nix-command flakes",
            "eval",
            "--json",
            &format!("{flake}#nixosConfigurations"),
            "--apply",
            "builtins.attrNames",
        ])
        .output()
        .map_err(|e| format!("cannot run nix: {e}"))?;

    if !out.status.success() {
        return Err(format!(
            "cannot read hosts from {flake}:\n{}",
            String::from_utf8_lossy(&out.stderr).trim()
        ));
    }

    serde_json::from_slice(&out.stdout).map_err(|e| format!("unexpected output from nix: {e}"))
}

pub struct HostPlan {
    pub name: String,
    /// The flake does not define this host yet; scaffold it after mounting.
    pub create: bool,
}

fn resolve_host(
    flake: &str,
    want: Option<String>,
    assume_yes: bool,
    new_host: bool,
    writable: bool,
) -> Result<HostPlan, String> {
    let hosts = flake_hosts(flake)?;

    if let Some(want) = want {
        if hosts.contains(&want) {
            return Ok(HostPlan { name: want, create: false });
        }
        if !writable {
            return Err(format!(
                "no such host: {want}\nAvailable: {}\n\
                 {flake} is fetched read-only, so a new host cannot be added to it.",
                hosts.join(", ")
            ));
        }
        // Creating a machine is not something to infer from a typo.
        if !new_host {
            return Err(format!(
                "no such host: {want}\nAvailable: {}\n\
                 Pass --new to scaffold hosts/{want} instead.",
                hosts.join(", ")
            ));
        }
        validate_host_name(&want)?;
        return Ok(HostPlan { name: want, create: true });
    }

    if hosts.is_empty() {
        return Err(format!("{flake} defines no hosts. Pass --host <name> --new."));
    }
    if assume_yes {
        return Err(format!(
            "--yes needs an explicit --host.\nAvailable: {}",
            hosts.join(", ")
        ));
    }

    println!("\nHosts:\n");
    for (i, h) in hosts.iter().enumerate() {
        println!("  {}) {h}", i + 1);
    }
    loop {
        let answer = prompt(&format!("\nInstall which host? [1-{}] ", hosts.len()))
            .map_err(|e| e.to_string())?;
        match answer.parse::<usize>() {
            Ok(n) if n >= 1 && n <= hosts.len() => {
                return Ok(HostPlan { name: hosts[n - 1].clone(), create: false })
            }
            _ => println!("Enter a number between 1 and {}.", hosts.len()),
        }
    }
}

/// The name becomes a directory and a flake attribute, so anything exotic
/// either breaks the path or silently produces an unreachable attribute.
fn validate_host_name(name: &str) -> Result<(), String> {
    if name.is_empty()
        || !name.chars().all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
    {
        return Err(format!(
            "bad host name: {name}\nUse letters, digits, dashes and underscores."
        ));
    }
    Ok(())
}

/// Write `hosts/<name>/hardware.nix` by asking the machine about itself.
///
/// `--show-hardware-config` prints to stdout instead of writing into
/// /etc/nixos. That matters: the tool otherwise also drops a starter
/// `configuration.nix`, a second description of the machine competing with
/// the flake, which is exactly what this design removed.
///
/// `--no-filesystems` omits the mounts, which come from
/// the host's disk.nix instead. Generated mounts are pinned by UUID and
/// mkfs mints new ones on every reinstall, so the generated file would go
/// stale and hang boot; without them it stays correct across reformats.
fn generate_hardware(host_dir: &Path) -> Result<(), String> {
    let out = Command::new("nixos-generate-config")
        .args(["--root", "/mnt", "--show-hardware-config", "--no-filesystems"])
        .output()
        .map_err(|e| format!("nixos-generate-config: {e}"))?;

    if !out.status.success() {
        return Err(format!(
            "cannot detect hardware:\n{}",
            String::from_utf8_lossy(&out.stderr).trim()
        ));
    }

    // The tool's own header says to make changes in
    // /etc/nixos/configuration.nix - the one file this design deliberately
    // does not have. Leaving it in place would point every future reader at
    // the wrong place, so replace it with where things actually live.
    let body = String::from_utf8_lossy(&out.stdout);
    let body = body
        .lines()
        .skip_while(|l| l.trim_start().starts_with('#'))
        .collect::<Vec<_>>()
        .join("\n");

    let header = "\
# Hardware facts for this machine, detected by `kiwami install`.
#
# Generated with --show-hardware-config --no-filesystems, so it carries no
# UUIDs: the mounts are derived from disk.nix and survive a reformat.
#
# Do not edit by hand. `kiwami doctor` compares this against what the machine
# currently reports; regenerate with `kiwami install --regen-hardware`, or:
#   nixos-generate-config --show-hardware-config --no-filesystems
#
# Choices - hostname, users, monitors - belong in default.nix beside this.
";

    fs::create_dir_all(host_dir).map_err(|e| e.to_string())?;
    fs::write(host_dir.join("hardware.nix"), format!("{header}{body}\n"))
        .map_err(|e| e.to_string())
}

/// The choices half of a machine: the things no probe can answer.
fn scaffold_host(host_dir: &Path, name: &str) -> Result<(), String> {
    let body = format!(
        r#"# {name}
#
# Scaffolded by `kiwami install`. Everything here is a choice, not a fact -
# edit it freely, then `nixos-rebuild switch --flake .#{name}`.
#
# hardware.nix beside this file is the facts half, detected at install time.
# Regenerate it with `kiwami doctor` if this machine's hardware changes.
{{ ... }}:

{{
  imports = [
    # Detected at install time. Do not edit; `kiwami doctor` diffs it against
    # what this machine currently reports.
    ./hardware.nix
    # The layout you chose. disko formats from it and fileSystems is derived
    # from it, so the two cannot drift apart.
    ./disk.nix
  ];

  networking.hostName = "{name}";

  boot.loader.systemd-boot.enable = true;
  # Without this systemd-boot never registers an NVRAM entry and the firmware
  # boots something else, or nothing.
  boot.loader.efi.canTouchEfiVariables = true;

  # Replace with your own account. `kiwami install --no-root-passwd` leaves
  # root locked, so set a password here or you cannot log in.
  users.users.{user} = {{
    isNormalUser = true;
    extraGroups = [ "wheel" "networkmanager" "video" ];
    initialPassword = "kiwami";
  }};

  home-manager.users.{user} = {{
    imports = [
      ../../modules/home/configs.nix
      ../../modules/home/shell.nix
    ];
    home.stateVersion = "26.05";
  }};

  system.stateVersion = "26.05";
}}
"#,
        name = name,
        user = "kiwami",
    );
    fs::create_dir_all(host_dir).map_err(|e| e.to_string())?;
    fs::write(host_dir.join("default.nix"), body).map_err(|e| e.to_string())
}

/// Nix builds from what git knows about, not from what is in the directory.
/// A brand new file is invisible to the flake even though `ls` shows it, and
/// the resulting "path does not exist in Git repository" names a file that is
/// plainly there. Staging is enough - no commit required.
fn git_add(repo: &Path, what: &Path) -> Result<(), String> {
    let status = Command::new("git")
        .args(["-C", &repo.to_string_lossy(), "add", "--", &what.to_string_lossy()])
        .status()
        .map_err(|e| format!("git: {e}"))?;
    if !status.success() {
        return Err(format!(
            "git add failed for {}. The flake cannot see untracked files, so \n             the install would fail on a file that is sitting right there.",
            what.display()
        ));
    }
    Ok(())
}

/// A local path we can write into, or nothing. `github:...` and friends are
/// fetched read-only into the store, so a generated file cannot be added to
/// them - that is why installing a new machine needs a clone.
fn local_checkout(flake: &str) -> Option<PathBuf> {
    let path = flake.strip_prefix("path:").unwrap_or(flake);
    if path.contains(':') {
        return None;
    }
    let p = PathBuf::from(path);
    p.join("flake.nix").exists().then_some(p)
}

/// The disks a host's disk.nix declares, resolved to kernel devices.
///
/// Once disko owns the layout, the target is whatever disk.nix names - not
/// whatever a menu selected. A confirmation naming a disk other than the one
/// about to be erased is worse than no confirmation at all.
fn host_disks(flake: &str, host: &str) -> Result<Vec<PathBuf>, String> {
    let out = Command::new("nix")
        .args([
            "--extra-experimental-features",
            "nix-command flakes",
            "eval",
            "--json",
            &format!("{flake}#nixosConfigurations.{host}.config.disko.devices.disk"),
            "--apply",
            "ds: map (d: d.device) (builtins.attrValues ds)",
        ])
        .output()
        .map_err(|e| format!("cannot run nix: {e}"))?;
    if !out.status.success() {
        // A host with no disko declaration is not an error; it just means the
        // layout is being chosen here instead.
        return Ok(Vec::new());
    }
    let declared: Vec<String> =
        serde_json::from_slice(&out.stdout).map_err(|e| format!("unexpected output: {e}"))?;

    declared
        .into_iter()
        .map(|d| {
            // by-id paths are symlinks; the safety checks and /proc/mounts
            // both speak kernel names.
            fs::canonicalize(&d)
                .map_err(|e| format!("{host} declares {d}, absent on this machine ({e})"))
        })
        .collect()
}

/// Wipe, partition, format and mount, all from the host's disk.nix.
///
/// Built from the flake rather than fetched: the script that runs is the one
/// this flake's pinned disko produced for this exact host, so it cannot
/// disagree with the fileSystems the same declaration generates.
fn run_disko(flake: &str, host: &str) -> Result<(), String> {
    let attr = format!("{flake}#nixosConfigurations.{host}.config.system.build.diskoScript");
    let out = Command::new("nix")
        .args([
            "--extra-experimental-features",
            "nix-command flakes",
            "build",
            "--no-link",
            "--print-out-paths",
            &attr,
        ])
        .output()
        .map_err(|e| format!("cannot run nix: {e}"))?;
    if !out.status.success() {
        return Err(format!(
            "cannot build the disk layout:\n{}",
            String::from_utf8_lossy(&out.stderr).trim()
        ));
    }
    let script = String::from_utf8_lossy(&out.stdout).trim().to_string();
    if script.is_empty() {
        return Err("disko produced no script".into());
    }
    run(&script, &[])
}

/// Are we running from installer media?
///
/// NixOS stamps VARIANT_ID=installer into /etc/os-release on its installation
/// images, which is the explicit signal. The root filesystem being a tmpfs or
/// overlay is the corroborating one - installed systems boot from a real
/// block device - and covers media that never set the variant.
fn on_installer_media() -> bool {
    let stamped = fs::read_to_string("/etc/os-release")
        .map(|s| s.lines().any(|l| l.trim() == "VARIANT_ID=installer"))
        .unwrap_or(false);

    let ephemeral_root = fs::read_to_string("/proc/mounts")
        .unwrap_or_default()
        .lines()
        .find_map(|l| {
            let mut f = l.split_whitespace();
            let src = f.next()?;
            let target = f.next()?;
            let fstype = f.next()?;
            (target == "/").then(|| (src.to_string(), fstype.to_string()))
        })
        .map(|(_, fstype)| fstype == "tmpfs" || fstype == "overlay")
        .unwrap_or(false);

    stamped || ephemeral_root
}


// --- disk layout wizard --------------------------------------------------

pub struct Layout {
    system: PathBuf,
    home: Option<PathBuf>,
    encrypt: bool,
    hibernate: bool,
}

/// The four questions, and only these four. Each one is irreversible: every
/// other knob - filesystem, swap file, zram - is a rebuild away, and a
/// question you can answer later does not belong in an installer.
fn ask_layout(all: &[Disk], system: &Disk) -> Result<Layout, String> {
    let others: Vec<&Disk> = all.iter().filter(|d| d.path != system.path).collect();

    let home = if others.is_empty() {
        None
    } else if prompt("\nPut /home on a separate disk? [y/N] ").map_err(|e| e.to_string())?.eq_ignore_ascii_case("y") {
        println!();
        for (i, d) in others.iter().enumerate() {
            println!("  {}) {d}", i + 1);
        }
        loop {
            let a = prompt(&format!("\nWhich disk for /home? [1-{}] ", others.len()))
                .map_err(|e| e.to_string())?;
            match a.parse::<usize>() {
                Ok(n) if n >= 1 && n <= others.len() => break Some(others[n - 1].path.clone()),
                _ => println!("Enter a number between 1 and {}.", others.len()),
            }
        }
    } else {
        None
    };

    // The one choice that cannot be added later without reinstalling.
    let encrypt = prompt("\nEncrypt the disk? [y/N] ").map_err(|e| e.to_string())?.eq_ignore_ascii_case("y");

    // Swap size only matters for hibernation. Without it, zram is better and
    // is pure configuration - no partition, changeable whenever.
    let hibernate = prompt(
        "\nHibernate (suspend to disk)?\n\
         Needs a swap partition the size of RAM, decided now.\n\
         Without it you get zram, which is changeable later. [y/N] ",
    )
    .map_err(|e| e.to_string())?
    .eq_ignore_ascii_case("y");

    if encrypt && hibernate {
        return Err("encryption plus hibernation needs the swap area inside the encrypted\n\
                    volume (LVM in LUKS), which this does not generate yet - an unencrypted\n\
                    swap partition would write your RAM to disk in the clear.\n\
                    Pick one, or write disk.nix by hand."
            .into());
    }

    Ok(Layout { system: system.path.clone(), home, encrypt, hibernate })
}

/// A name built from the drive's own model and serial, not from the order the
/// kernel happened to find it in. /dev/sdb is a position in a queue: add a
/// disk and it can mean a different drive tomorrow, which is not something to
/// write into a file whose job is deciding what gets erased.
fn stable_device(dev: &Path) -> Result<String, String> {
    let dir = Path::new("/dev/disk/by-id");
    let mut names: Vec<String> = fs::read_dir(dir)
        .map_err(|e| format!("cannot read {}: {e}", dir.display()))?
        .filter_map(|e| e.ok())
        .filter(|e| fs::canonicalize(e.path()).ok().as_deref() == Some(dev))
        .filter_map(|e| e.file_name().into_string().ok())
        // Partition aliases point at slices, not at the whole disk.
        .filter(|n| !n.contains("-part"))
        .collect();

    if names.is_empty() {
        return Err(format!(
            "{} has no /dev/disk/by-id entry, so there is no stable name to write.\n\
             Kernel names like {} can point at a different drive after adding one.",
            dev.display(),
            dev.display()
        ));
    }

    // Several aliases usually exist for one drive. Prefer the readable
    // model_serial form over wwn- and raw hex nvme- ids, and the shorter of
    // what remains - QEMU, for one, offers the same disk with a _1 suffix.
    names.sort_by_key(|n| {
        let opaque = n.starts_with("wwn-") || n.starts_with("nvme-nvme.");
        (opaque, n.len(), n.clone())
    });
    Ok(format!("/dev/disk/by-id/{}", names[0]))
}

fn ram_gib() -> Result<u64, String> {
    let meminfo = fs::read_to_string("/proc/meminfo").map_err(|e| e.to_string())?;
    let kb: u64 = meminfo
        .lines()
        .find(|l| l.starts_with("MemTotal:"))
        .and_then(|l| l.split_whitespace().nth(1))
        .and_then(|n| n.parse().ok())
        .ok_or("cannot read MemTotal")?;
    // Round up: a swap area smaller than RAM cannot hold the hibernation image.
    Ok(kb.div_ceil(1024 * 1024).max(1))
}

/// Indent a rendered block to sit correctly inside its parent. Generated Nix
/// gets committed and read by people, so it has to look like it was written
/// by one.
fn indent(block: &str, spaces: usize) -> String {
    let pad = " ".repeat(spaces);
    block
        .lines()
        .enumerate()
        .map(|(i, l)| if i == 0 || l.is_empty() { l.to_string() } else { format!("{pad}{l}") })
        .collect::<Vec<_>>()
        .join("\n")
}

fn filesystem(mountpoint: &str) -> String {
    format!(
        "{{\n  type = \"filesystem\";\n  format = \"ext4\";\n  mountpoint = \"{mountpoint}\";\n}}"
    )
}

fn encrypted(name: &str, mountpoint: &str) -> String {
    format!(
        "{{\n  type = \"luks\";\n  name = \"{name}\";\n  settings.allowDiscards = true;\n  content = {};\n}}",
        indent(&filesystem(mountpoint), 2)
    )
}

fn render_disk_nix(l: &Layout) -> Result<String, String> {
    let system = stable_device(&l.system)?;

    let root_content = if l.encrypt {
        encrypted("cryptroot", "/")
    } else {
        filesystem("/")
    };

    let swap = if l.hibernate {
        format!(
            r#"          swap = {{
            size = "{}G";
            content = {{
              type = "swap";
              # Hibernation resumes from here, so the kernel has to be told
              # which device holds the image.
              resumeDevice = true;
            }};
          }};
"#,
            ram_gib()?
        )
    } else {
        String::new()
    };

    let home = match &l.home {
        None => String::new(),
        Some(dev) => {
            let home_dev = stable_device(dev)?;
            let content = if l.encrypt {
                encrypted("crypthome", "/home")
            } else {
                filesystem("/home")
            };
            format!(
                r#"
    home = {{
      type = "disk";
      device = "{home_dev}";
      content = {{
        type = "gpt";
        partitions.home = {{
          size = "100%";
          content = {};
        }};
      }};
    }};
"#,
                indent(&content, 10)
            )
        }
    };

    let notes = if l.encrypt && l.home.is_some() {
        "#\n# Two encrypted volumes means two passphrase prompts at every boot. A\n\
         # keyfile on the decrypted root can unlock /home instead; that is not\n\
         # generated yet.\n"
    } else {
        ""
    };

    let zram = if l.hibernate {
        ""
    } else {
        "#\n# No swap partition: zram is used instead - compressed swap in RAM. It\n\
         # costs no disk, and can be turned off or joined by a swapfile with a\n\
         # rebuild, unlike this file.\n"
    };

    Ok(format!(
        r#"# Disk layout for this machine, written by `kiwami install`.
#
# One declaration, two uses: disko formats from it, and fileSystems is derived
# from the same tree - so what gets erased and what gets mounted cannot drift
# apart.
#
# Devices are named by id, not /dev/sdX: kernel names follow the order disks
# are found in, so adding a drive can silently repoint this at another one.
{notes}{zram}#
# Editing this after installing does not repartition anything. It describes a
# disk that already exists.
{{ ... }}:

{{
  disko.devices.disk = {{
    system = {{
      type = "disk";
      device = "{system}";
      content = {{
        type = "gpt";
        partitions = {{
          ESP = {{
            size = "1G";
            type = "EF00";
            content = {{
              type = "filesystem";
              format = "vfat";
              mountpoint = "/boot";
              mountOptions = [ "umask=0077" ];
            }};
          }};
{swap}          root = {{
            size = "100%";
            content = {};
          }};
        }};
      }};
    }};
{home}  }};
}}
"#,
        indent(&root_content, 12)
    ))
}

/// Show the generated layout and let it be edited before anything is erased.
///
/// This is what keeps the four questions from ever needing to become forty:
/// LUKS variants, btrfs subvolumes, RAID and separate /var stay documented
/// disko config that you edit, rather than menus that have to be designed,
/// tested and trusted.
fn review_layout(path: &Path, assume_yes: bool) -> Result<(), String> {
    let shown = fs::read_to_string(path).map_err(|e| e.to_string())?;
    println!("\nWrote {}:\n", path.display());
    for line in shown.lines().filter(|l| !l.trim_start().starts_with('#')) {
        println!("  {line}");
    }

    if assume_yes {
        return Ok(());
    }

    loop {
        let choice = prompt("\n[i] install with this   [e] edit first   [a] abort: ")
            .map_err(|e| e.to_string())?;
        match choice.as_str() {
            "i" | "I" => return Ok(()),
            "a" | "A" => return Err("aborted; nothing was written to any disk".into()),
            "e" | "E" => {
                let editor = std::env::var("EDITOR").unwrap_or_else(|_| "nano".into());
                let status = Command::new(&editor)
                    .arg(path)
                    .status()
                    .map_err(|e| format!("{editor}: {e}"))?;
                if !status.success() {
                    println!("    {editor} exited non-zero; file left as it was");
                }
                return review_layout(path, assume_yes);
            }
            _ => println!("Enter i, e or a."),
        }
    }
}

/// A hardware.nix that is enough to evaluate, and nothing more.
///
/// The real one is generated after mounting, but the flake has to evaluate
/// *before* that: disko's script is built from this very host, so a directory
/// containing only disk.nix cannot be formatted from. It also means an
/// install abandoned midway leaves a host that still evaluates rather than
/// breaking the whole flake.
fn placeholder_hardware(host_dir: &Path) -> Result<(), String> {
    let system = match std::env::consts::ARCH {
        "aarch64" => "aarch64-linux",
        "x86_64" => "x86_64-linux",
        other => return Err(format!("unsupported architecture: {other}")),
    };
    fs::write(
        host_dir.join("hardware.nix"),
        format!(
            "# Placeholder. `kiwami install` replaces this with detected hardware\n             # once the target is mounted; if you are reading it after a finished\n             # install, that step did not run.\n             {{ lib, ... }}:\n\n{{\n  nixpkgs.hostPlatform = lib.mkDefault \"{system}\";\n}}\n"
        ),
    )
    .map_err(|e| e.to_string())
}

/// Print the detected disks and exit. Used by tests and by anyone wondering
/// what the installer can see.
pub fn list_disks() -> Result<(), String> {
    let disks = disks().map_err(|e| e.to_string())?;
    if disks.is_empty() {
        println!("(no disks found)");
        return Ok(());
    }
    for d in disks {
        println!("{d}");
    }
    Ok(())
}

#[allow(dead_code)]
fn _unused(_: Stdio) {}
