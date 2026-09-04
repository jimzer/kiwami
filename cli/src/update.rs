//! `kiwami update` - rebuild this machine from the flake, which lives on
//! GitHub and nowhere else.
//!
//! The machine deliberately keeps no checkout of its own configuration. Every
//! bug in this area came from having one: a copy that could be older than
//! GitHub, older than the disk it describes, or restored from a backup taken
//! before a layout change - each one able to revert the machine's config
//! silently at the next rebuild. None of that is possible if the copy does not
//! exist.
//!
//! What that costs: changing the machine needs a network. Running it does not
//! - the built system is in /nix/store and boots without ever reading a flake.
//!
//! Hacking on the config locally is still ordinary: clone anywhere and
//! `nixos-rebuild switch --flake /path#host`. It is simply not the default, so
//! an uncommitted edit cannot quietly become what the machine is.

use std::fs;
use std::process::Command;

const FLAKE: &str = "github:jimzer/kiwami";

/// Where the commit this system was built from is recorded. Under
/// /var/lib/kiwami because that path is persisted, so the answer survives the
/// root being wiped.
const STAMP: &str = "/var/lib/kiwami/commit";

pub fn run(commit: Option<String>, dry: bool) -> Result<(), String> {
    if !crate::install::is_root() {
        return Err("must run as root (try: sudo kiwami update)".into());
    }

    let host = hostname()?;

    // Resolved to a commit before anything is built.
    //
    // Two reasons. The output can then say exactly what you are running rather
    // than "main", which is a moving target; and two machines updated a minute
    // apart get the same system instead of whatever main happened to be.
    let rev = match commit {
        Some(c) => c,
        None => resolve_head()?,
    };
    let flake = format!("{FLAKE}/{rev}");

    println!("==> {host} from {rev}");
    if !host_exists(&flake, &host)? {
        return Err(format!(
            "{FLAKE} does not describe a machine called {host}.\n\
             Its configuration has not been pushed yet:\n\n  \
             sudo kiwami host push\n\n\
             A machine whose config is not in the flake cannot be rebuilt from it."
        ));
    }

    let action = if dry { "build" } else { "switch" };
    let status = Command::new("nixos-rebuild")
        .args([action, "--flake", &format!("{flake}#{host}")])
        .status()
        .map_err(|e| format!("nixos-rebuild: {e}"))?;
    if !status.success() {
        return Err("nixos-rebuild failed".into());
    }

    if dry {
        println!("\nbuilt, not switched");
        return Ok(());
    }

    // Recorded so `kiwami doctor` can answer "is this machine current?"
    // without a checkout to compare against - the question the checkout used
    // to answer, minus the copy that could lie about it.
    if let Some(dir) = std::path::Path::new(STAMP).parent() {
        let _ = fs::create_dir_all(dir);
    }
    let _ = fs::write(STAMP, format!("{rev}\n"));

    println!("\nnow running {rev}");
    Ok(())
}

/// The commit main points at right now.
///
/// --refresh because github: flakes are cached for an hour by default, which
/// twice today served a commit older than the fix being tested. Baked in here
/// so it can never be the explanation for "but I pushed that".
fn resolve_head() -> Result<String, String> {
    let out = Command::new("nix")
        .args([
            "--extra-experimental-features",
            "nix-command flakes",
            "flake",
            "metadata",
            FLAKE,
            "--refresh",
            "--json",
        ])
        .output()
        .map_err(|e| format!("nix flake metadata: {e}"))?;
    if !out.status.success() {
        return Err(format!(
            "cannot reach {FLAKE}: {}",
            String::from_utf8_lossy(&out.stderr).trim()
        ));
    }
    let v: serde_json::Value =
        serde_json::from_slice(&out.stdout).map_err(|e| format!("nix flake metadata: {e}"))?;
    v.get("revision")
        .and_then(|r| r.as_str())
        .map(String::from)
        .ok_or_else(|| "no revision in flake metadata".into())
}

fn host_exists(flake: &str, host: &str) -> Result<bool, String> {
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
        .map_err(|e| format!("nix eval: {e}"))?;
    if !out.status.success() {
        return Err(format!(
            "cannot evaluate {flake}: {}",
            String::from_utf8_lossy(&out.stderr).trim()
        ));
    }
    let names: Vec<String> = serde_json::from_slice(&out.stdout).unwrap_or_default();
    Ok(names.iter().any(|n| n == host))
}

/// What this machine calls itself, which is also the host it builds.
///
/// Not a flag: a flag is a way to build another machine's configuration onto
/// this one, and there is no good reason to want that.
fn hostname() -> Result<String, String> {
    fs::read_to_string("/etc/hostname")
        .map(|s| s.trim().to_string())
        .map_err(|e| format!("cannot read /etc/hostname: {e}"))
        .and_then(|h| if h.is_empty() { Err("empty hostname".into()) } else { Ok(h) })
}

/// The commit this system was last built from, if it was built by us.
pub fn current_commit() -> Option<String> {
    fs::read_to_string(STAMP).ok().map(|s| s.trim().to_string()).filter(|s| !s.is_empty())
}
