//! `kiwami doctor` - find what drifted, and check that what is declared works.
//!
//! On NixOS packages are declared by construction, so this is not a package
//! diff. It looks for the escape hatches someone used, and for the failures
//! that are silent: a unit that restarts forever still shows up in pgrep, a
//! target that never activates just means nothing bound to it ever starts.

use std::fmt;
use std::fs;
use std::process::Command;

use crate::paths;

#[derive(PartialEq, Clone, Copy)]
pub enum Level {
    Ok,
    Warn,
    Fail,
    /// Not applicable here - e.g. a session check run over SSH. Skipped is not
    /// a failure; reporting it as one trains people to ignore the output.
    Skip,
}

pub struct Finding {
    level: Level,
    title: String,
    detail: Option<String>,
    remedy: Option<String>,
}

impl Finding {
    fn new(level: Level, title: impl Into<String>) -> Self {
        Finding { level, title: title.into(), detail: None, remedy: None }
    }
    fn detail(mut self, d: impl Into<String>) -> Self {
        self.detail = Some(d.into());
        self
    }
    fn remedy(mut self, r: impl Into<String>) -> Self {
        self.remedy = Some(r.into());
        self
    }
}

impl fmt::Display for Finding {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let (mark, colour) = match self.level {
            Level::Ok => ("✔", "\x1b[32m"),
            Level::Warn => ("⚠", "\x1b[33m"),
            Level::Fail => ("✘", "\x1b[31m"),
            Level::Skip => ("–", "\x1b[90m"),
        };
        write!(f, "  {colour}{mark}\x1b[0m {}", self.title)?;
        if let Some(d) = &self.detail {
            for line in d.lines() {
                write!(f, "\n      \x1b[90m{line}\x1b[0m")?;
            }
        }
        if let Some(r) = &self.remedy {
            write!(f, "\n      \x1b[36m→ {r}\x1b[0m")?;
        }
        Ok(())
    }
}

/// Run a command, returning stdout on success. None if it is not installed or
/// failed - a missing tool is not a finding, it is simply nothing to check.
fn output(cmd: &str, args: &[&str]) -> Option<String> {
    let out = Command::new(cmd).args(args).output().ok()?;
    out.status
        .success()
        .then(|| String::from_utf8_lossy(&out.stdout).to_string())
}

fn have(cmd: &str) -> bool {
    Command::new("sh")
        .args(["-c", &format!("command -v {cmd}")])
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false)
}

fn user_systemctl(args: &[&str]) -> Option<String> {
    let mut full = vec!["--user"];
    full.extend_from_slice(args);
    let out = Command::new("systemctl")
        .args(&full)
        .env("XDG_RUNTIME_DIR", format!("/run/user/{}", uid()))
        .output()
        .ok()?;
    Some(String::from_utf8_lossy(&out.stdout).to_string())
}

fn uid() -> u32 {
    fs::read_to_string("/proc/self/status")
        .ok()
        .and_then(|s| {
            s.lines()
                .find(|l| l.starts_with("Uid:"))?
                .split_whitespace()
                .nth(1)?
                .parse()
                .ok()
        })
        .unwrap_or(1000)
}

// --- drift ---------------------------------------------------------------

fn nix_profile() -> Finding {
    match output("nix", &["profile", "list"]) {
        None => Finding::new(Level::Skip, "nix profile unavailable"),
        Some(out) if out.trim().is_empty() => {
            Finding::new(Level::Ok, "no imperative nix profile installs")
        }
        Some(out) => {
            let n = out.lines().filter(|l| !l.trim().is_empty()).count();
            Finding::new(Level::Fail, format!("{n} package(s) installed imperatively"))
                .detail(out.trim().to_string())
                .remedy("declare them in the flake, then: nix profile remove --all")
        }
    }
}

fn nix_env() -> Finding {
    match output("nix-env", &["-q"]) {
        None => Finding::new(Level::Skip, "nix-env unavailable"),
        Some(out) if out.trim().is_empty() => Finding::new(Level::Ok, "nix-env profile empty"),
        Some(out) => Finding::new(Level::Fail, "packages installed with nix-env")
            .detail(out.trim().to_string())
            .remedy("nix-env -e '*' once they are in the flake"),
    }
}

fn stray_binaries() -> Finding {
    let home = paths::home();
    let dirs = [home.join(".local/bin"), home.join("bin")];
    let mut found = Vec::new();

    for dir in dirs.iter().filter(|d| d.is_dir()) {
        let Ok(entries) = fs::read_dir(dir) else { continue };
        for e in entries.flatten() {
            let p = e.path();
            // A symlink into the store is Nix-managed; a real file here is not.
            if p.is_symlink() {
                if let Ok(t) = fs::read_link(&p) {
                    if t.starts_with("/nix/store") {
                        continue;
                    }
                }
            }
            found.push(format!("{}", p.display()));
        }
    }

    if found.is_empty() {
        Finding::new(Level::Ok, "no stray executables in ~/.local/bin or ~/bin")
    } else {
        Finding::new(Level::Fail, format!("{} executable(s) not managed by nix", found.len()))
            .detail(found.join("\n"))
            .remedy("package them in the flake, or delete them")
    }
}

fn language_managers() -> Vec<Finding> {
    let checks: [(&str, &[&str], &str); 3] = [
        ("npm", &["ls", "-g", "--depth=0", "--parseable"], "npm -g"),
        ("cargo", &["install", "--list"], "cargo install"),
        ("pipx", &["list", "--short"], "pipx"),
    ];

    checks
        .iter()
        .filter(|(bin, _, _)| have(bin))
        .map(|(bin, args, label)| match output(bin, args) {
            Some(out) => {
                // npm always prints its own prefix line; ignore it.
                let items: Vec<&str> = out
                    .lines()
                    .filter(|l| !l.trim().is_empty() && !l.ends_with("/lib"))
                    .collect();
                if items.is_empty() {
                    Finding::new(Level::Ok, format!("no {label} installs"))
                } else {
                    Finding::new(Level::Warn, format!("{} {label} install(s)", items.len()))
                        .detail(items.join("\n"))
                        .remedy("fine for throwaway tools; package anything you rely on")
                }
            }
            None => Finding::new(Level::Skip, format!("{label} not queryable")),
        })
        .collect()
}

// --- health --------------------------------------------------------------

fn failed_units() -> Finding {
    match output("systemctl", &["--failed", "--no-legend", "--plain"]) {
        None => Finding::new(Level::Skip, "systemctl unavailable"),
        Some(out) if out.trim().is_empty() => Finding::new(Level::Ok, "no failed system units"),
        Some(out) => Finding::new(Level::Fail, "failed system units")
            .detail(out.trim().to_string())
            .remedy("systemctl status <unit>"),
    }
}

fn failed_user_units() -> Finding {
    match user_systemctl(&["--failed", "--no-legend", "--plain"]) {
        None => Finding::new(Level::Skip, "user manager unavailable"),
        Some(out) if out.trim().is_empty() => Finding::new(Level::Ok, "no failed user units"),
        Some(out) => Finding::new(Level::Fail, "failed user units")
            .detail(out.trim().to_string())
            .remedy("systemctl --user status <unit>"),
    }
}

fn graphical_session() -> Finding {
    let active = user_systemctl(&["is-active", "graphical-session.target"])
        .map(|s| s.trim() == "active")
        .unwrap_or(false);

    if active {
        Finding::new(Level::Ok, "graphical-session.target active")
    } else if std::env::var("WAYLAND_DISPLAY").is_err() && !session_env_has_wayland() {
        // Run over SSH with no desktop: nothing is wrong.
        Finding::new(Level::Skip, "no graphical session here")
    } else {
        Finding::new(Level::Fail, "graphical-session.target inactive")
            .detail("units bound to it never start, silently")
            .remedy("check that the session launches via uwsm")
    }
}

fn session_env_has_wayland() -> bool {
    user_systemctl(&["show-environment"])
        .map(|s| s.contains("WAYLAND_DISPLAY="))
        .unwrap_or(false)
}

fn shell_unit() -> Finding {
    let state = user_systemctl(&["is-active", "kiwami-shell.service"])
        .map(|s| s.trim().to_string())
        .unwrap_or_default();

    if state.is_empty() || state == "inactive" {
        if !session_env_has_wayland() {
            return Finding::new(Level::Skip, "shell not running (no graphical session)");
        }
        return Finding::new(Level::Fail, "kiwami-shell is not running")
            .remedy("systemctl --user start kiwami-shell");
    }

    let restarts: u32 = user_systemctl(&["show", "-p", "NRestarts", "--value", "kiwami-shell.service"])
        .and_then(|s| s.trim().parse().ok())
        .unwrap_or(0);

    // A flapping unit is active often enough to look fine. This is the check
    // that would have caught the shell being broken in CI for two green runs.
    if restarts > 5 {
        Finding::new(Level::Fail, format!("kiwami-shell has restarted {restarts} times"))
            .detail("it is running, but crashing and being restarted")
            .remedy("journalctl --user -u kiwami-shell -n 50")
    } else if state == "active" {
        Finding::new(Level::Ok, format!("kiwami-shell active ({restarts} restarts)"))
    } else {
        Finding::new(Level::Warn, format!("kiwami-shell is {state}"))
    }
}

fn theme_applied() -> Finding {
    match crate::theme::current() {
        Some(name) => {
            let colors = paths::current_theme().join("colors.json");
            if colors.is_file() {
                Finding::new(Level::Ok, format!("theme '{name}' applied"))
            } else {
                Finding::new(Level::Fail, format!("theme '{name}' recorded but not generated"))
                    .remedy("kiwami theme set")
            }
        }
        None => Finding::new(Level::Fail, "no theme applied")
            .detail("everything renders on fallback colours")
            .remedy("kiwami theme set kiwami"),
    }
}

// --- hygiene -------------------------------------------------------------

fn generations() -> Finding {
    let count = output("nix-env", &["--list-generations", "-p", "/nix/var/nix/profiles/system"])
        .map(|s| s.lines().filter(|l| !l.trim().is_empty()).count())
        .unwrap_or(0);

    if count == 0 {
        return Finding::new(Level::Skip, "generations not readable (needs root)");
    }
    if count > 10 {
        Finding::new(Level::Warn, format!("{count} system generations"))
            .remedy("sudo nix-collect-garbage --delete-older-than 14d")
    } else {
        Finding::new(Level::Ok, format!("{count} system generations"))
    }
}

fn lock_age() -> Finding {
    let lock = paths::repo().join("flake.lock");
    let Ok(meta) = fs::metadata(&lock) else {
        return Finding::new(Level::Skip, "no flake.lock here");
    };
    let Ok(modified) = meta.modified() else {
        return Finding::new(Level::Skip, "flake.lock timestamp unreadable");
    };
    let days = modified
        .elapsed()
        .map(|d| d.as_secs() / 86_400)
        .unwrap_or(0);

    if days > 30 {
        Finding::new(Level::Warn, format!("flake.lock is {days} days old"))
            .remedy("nix flake update")
    } else {
        Finding::new(Level::Ok, format!("flake.lock is {days} days old"))
    }
}

/// The committed hardware facts are a snapshot of install day, not a live
/// query. Move the disk to another machine, swap the wifi card, and the file
/// keeps describing the old one - which fails at the worst moment, in the
/// initrd, with no shell to debug from. So re-ask the machine and diff.
fn hardware_drift() -> Finding {
    let repo = paths::repo();
    if !repo.join("flake.nix").exists() {
        return Finding::new(Level::Skip, "no checkout here to compare hardware against");
    }
    if !have("nixos-generate-config") {
        return Finding::new(Level::Skip, "nixos-generate-config not available");
    }

    let Some(host) = fs::read_to_string("/etc/hostname").ok().map(|s| s.trim().to_string())
    else {
        return Finding::new(Level::Skip, "hostname unreadable");
    };

    // The directory is named for the flake attribute, which need not match
    // networking.hostName. Fall back to a single unambiguous match.
    let Some(dir) = host_dir(&repo, &host) else {
        return Finding::new(Level::Skip, format!("no hosts/ entry matching {host}"));
    };

    let committed = match fs::read_to_string(dir.join("hardware.nix")) {
        Ok(c) => c,
        Err(_) => {
            return Finding::new(Level::Warn, format!("{} has no hardware.nix", dir.display()))
                .remedy("kiwami install --regen-hardware, or generate it by hand")
        }
    };

    // No --root here: the tool rejects `--root /` outright ("no need to
    // specify / with --root, it is the default"). At install time the target
    // is /mnt and the flag is required.
    let Some(fresh) = output(
        "nixos-generate-config",
        &["--show-hardware-config", "--no-filesystems"],
    ) else {
        return Finding::new(Level::Skip, "hardware detection failed (needs root)");
    };

    // Compare the settings, not the bytes: comments and blank lines differ
    // between nixpkgs revisions and would report drift on every bump.
    let a = significant(&committed);
    let b = significant(&fresh);
    if a == b {
        return Finding::new(Level::Ok, "hardware.nix matches this machine");
    }

    let added: Vec<_> = b.iter().filter(|l| !a.contains(l)).cloned().collect();
    let gone: Vec<_> = a.iter().filter(|l| !b.contains(l)).cloned().collect();
    let mut detail = String::new();
    for l in gone.iter().take(4) {
        detail.push_str(&format!("- {l}\n"));
    }
    for l in added.iter().take(4) {
        detail.push_str(&format!("+ {l}\n"));
    }

    Finding::new(Level::Warn, "hardware.nix no longer matches this machine")
        .detail(detail.trim_end())
        .remedy("nixos-generate-config --show-hardware-config --no-filesystems > \
                 hosts/<name>/hardware.nix")
}

/// Which hosts/ directory describes this machine. The directory name is a
/// flake attribute and need not equal networking.hostName - hosts/vm-aarch64
/// is called kiwami-vm - so fall back to whichever host declares this
/// hostname, and finally to the only one there is.
fn host_dir(repo: &std::path::Path, hostname: &str) -> Option<std::path::PathBuf> {
    let by_name = repo.join("hosts").join(hostname);
    if by_name.is_dir() {
        return Some(by_name);
    }

    let mut dirs: Vec<_> = fs::read_dir(repo.join("hosts"))
        .ok()?
        .filter_map(|e| e.ok())
        .map(|e| e.path())
        .filter(|p| p.is_dir())
        .collect();
    dirs.sort();

    let declares = format!("hostName = \"{hostname}\"");
    let mut matched = dirs
        .iter()
        .filter(|d| {
            fs::read_to_string(d.join("default.nix"))
                .map(|c| c.contains(&declares))
                .unwrap_or(false)
        })
        .cloned();
    if let (Some(one), None) = (matched.next(), matched.next()) {
        return Some(one);
    }

    (dirs.len() == 1).then(|| dirs.remove(0))
}

/// Lines that carry meaning: no comments, no blank lines, whitespace
/// collapsed so reindentation is not drift.
fn significant(nix: &str) -> Vec<String> {
    nix.lines()
        .map(str::trim)
        .filter(|l| !l.is_empty() && !l.starts_with('#'))
        .map(|l| l.split_whitespace().collect::<Vec<_>>().join(" "))
        .collect()
}

// --- driver --------------------------------------------------------------

pub fn run() -> Result<(), ()> {
    let sections: [(&str, Vec<Finding>); 3] = [
        ("drift", {
            let mut v = vec![nix_profile(), nix_env(), stray_binaries()];
            v.extend(language_managers());
            v
        }),
        ("health", vec![
            failed_units(),
            failed_user_units(),
            graphical_session(),
            shell_unit(),
            theme_applied(),
        ]),
        ("hygiene", vec![generations(), lock_age(), hardware_drift()]),
    ];

    let mut fails = 0;
    let mut warns = 0;

    for (name, findings) in sections.iter() {
        println!("\n\x1b[1m{name}\x1b[0m");
        for f in findings {
            println!("{f}");
            match f.level {
                Level::Fail => fails += 1,
                Level::Warn => warns += 1,
                _ => {}
            }
        }
    }

    println!();
    if fails == 0 && warns == 0 {
        println!("\x1b[32mno problems\x1b[0m");
        Ok(())
    } else {
        println!("{fails} problem(s), {warns} warning(s)");
        if fails > 0 { Err(()) } else { Ok(()) }
    }
}
