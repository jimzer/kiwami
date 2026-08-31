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

/// Refuse anything smaller than this. Below it the install fails partway
/// through, which is worse than refusing up front.
const MIN_BYTES: u64 = 20 * 1024 * 1024 * 1024;

const ESP_MIB: u64 = 1024;

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

/// Partitions are `nvme0n1p1` on NVMe and `sda1` on SCSI/virtio.
fn partition_path(disk: &Path, n: u32) -> PathBuf {
    let s = disk.to_string_lossy();
    let last = s.chars().last().unwrap_or(' ');
    if last.is_ascii_digit() {
        PathBuf::from(format!("{s}p{n}"))
    } else {
        PathBuf::from(format!("{s}{n}"))
    }
}

fn prompt(question: &str) -> io::Result<String> {
    print!("{question}");
    io::stdout().flush()?;
    let mut line = String::new();
    io::stdin().lock().read_line(&mut line)?;
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
    // A live ISO has no /etc/NIXOS; an installed system does. Without this,
    // running `kiwami install` on your own machine out of curiosity wipes it.
    if Path::new("/etc/NIXOS").exists() && !opts.force {
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

    let target = match &opts.disk {
        Some(want) => {
            let want = if want.starts_with("/dev/") { want.clone() } else { format!("/dev/{want}") };
            disks
                .into_iter()
                .find(|d| d.path.to_string_lossy() == want)
                .ok_or_else(|| format!("no such disk: {want}"))?
        }
        None => select_disk(disks)?,
    };

    if target.in_use && !opts.force {
        return Err(format!(
            "{} is mounted right now - this looks like the system you are running.\n\
             Refusing to erase it. Pass --force if you really mean it.",
            target.path.display()
        ));
    }

    if target.bytes < MIN_BYTES {
        return Err(format!(
            "{} is {:.1} GiB; Kiwami needs at least {} GiB",
            target.path.display(),
            target.gib(),
            MIN_BYTES / (1024 * 1024 * 1024)
        ));
    }

    // Everything above this line is read-only.
    confirm(&target, opts.assume_yes)?;

    println!("\n==> partitioning {}", target.path.display());
    partition(&target.path)?;

    println!("==> formatting");
    format_disk(&target.path)?;

    println!("==> mounting");
    mount(&target.path)?;

    // Only now is /mnt populated, which is what nixos-generate-config reads.
    if let Some(repo) = &checkout {
        let host_dir = repo.join("hosts").join(&host.name);
        let hardware = host_dir.join("hardware.nix");

        if host.create {
            println!("==> scaffolding hosts/{}", host.name);
            scaffold_host(&host_dir, &host.name)?;
        }

        // A committed hardware.nix may have been tuned by hand; replacing it
        // silently on a reinstall is not ours to do. `kiwami doctor` reports
        // when it has drifted from what the machine actually reports.
        if opts.regen_hardware || !hardware.exists() {
            println!("==> detecting hardware");
            generate_hardware(&host_dir)?;
        } else {
            println!("==> keeping the committed hardware.nix (--regen-hardware to replace)");
        }

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

fn confirm(target: &Disk, assume_yes: bool) -> Result<(), String> {
    println!("\nAbout to install to {}", target.path.display());
    if !target.is_empty() {
        println!(
            "\n  WARNING: {} already has {} partition(s): {}",
            target.path.display(),
            target.partitions.len(),
            target.partitions.join(", ")
        );
        println!("  Everything on it will be destroyed.");
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

fn partition(disk: &Path) -> Result<(), String> {
    let d = disk.to_string_lossy().to_string();
    run("parted", &[
        "-s", &d, "--",
        "mklabel", "gpt",
        "mkpart", "ESP", "fat32", "1MiB", &format!("{ESP_MIB}MiB"),
        "set", "1", "esp", "on",
        "mkpart", "root", "ext4", &format!("{ESP_MIB}MiB"), "100%",
    ])?;
    // mkfs and mount both look devices up by label; udev has not necessarily
    // created the nodes by the time parted returns.
    run("udevadm", &["settle", "--timeout=30"])
}

fn format_disk(disk: &Path) -> Result<(), String> {
    let esp = partition_path(disk, 1);
    let root = partition_path(disk, 2);
    // The labels are a contract: hosts/*/hardware-configuration.nix mounts by
    // label so a reinstall does not invalidate the config with fresh UUIDs.
    run("mkfs.fat", &["-F", "32", "-n", "boot", &esp.to_string_lossy()])?;
    run("mkfs.ext4", &["-q", "-F", "-L", "nixos", &root.to_string_lossy()])?;
    run("udevadm", &["settle", "--timeout=30"])
}

fn mount(disk: &Path) -> Result<(), String> {
    let esp = partition_path(disk, 1);
    let root = partition_path(disk, 2);
    run("mount", &[&root.to_string_lossy(), "/mnt"])?;
    fs::create_dir_all("/mnt/boot").map_err(|e| e.to_string())?;
    run("mount", &["-o", "umask=077", &esp.to_string_lossy(), "/mnt/boot"])
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
/// modules/disk-layout.nix instead. Generated mounts are pinned by UUID and
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
# UUIDs: the mounts live in modules/disk-layout.nix and survive a reformat.
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
    ./hardware.nix
    # The two partitions `kiwami install` created. Drop this import if you
    # ever repartition by hand.
    ../../modules/disk-layout.nix
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
