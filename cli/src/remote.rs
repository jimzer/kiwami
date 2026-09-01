//! `kiwami remote` - make this machine reachable for debugging an install.
//!
//! The installer has only ever run against QEMU, and every bug found so far
//! came from the VM being quietly easier than real hardware: device ids that
//! did not exist, a guard that refused the real media, an image built without
//! the key it was supposed to carry. Reaching a real machine during an install
//! is the only way to close that gap.
//!
//! No auth key is baked in anywhere. `tailscale up` prints a URL that gets
//! approved from a browser on another device, so nothing secret ships in the
//! repository or the image.

use std::io::{BufRead, BufReader};
use std::process::{Command, Stdio};

use crate::net;

pub fn run(down: bool) -> Result<(), String> {
    // Everything below is privileged: starting the daemon, and tailscale up.
    // Without this the systemctl call lands in a polkit password prompt for a
    // password the installer user does not have, times out, and reports three
    // failures all pointing at tailscaled - none of them the actual cause.
    if !crate::install::is_root() {
        return Err("must run as root (try: sudo kiwami remote)".into());
    }

    if !have("tailscale") {
        return Err("tailscale is not installed here.\n\
                    It ships on the Kiwami installer image; on an installed \
                    system enable services.tailscale."
            .into());
    }

    if down {
        run_cmd("tailscale", &["down"])?;
        println!("disconnected");
        return Ok(());
    }

    // Tailscale needs plain connectivity before it can do anything.
    if !net::online() {
        println!("==> no network yet");
        net::ensure(true)?;
    }

    if let Some(name) = current_host() {
        println!("already connected as {name}");
        println!("\n  ssh {name}");
        return Ok(());
    }

    println!("\nThis gives anyone on your tailnet a root shell on this machine,");
    println!("for as long as it stays connected. Run `kiwami remote --down`");
    println!("when you are finished, and note that a machine being installed is");
    println!("about to be erased anyway.\n");

    // --ssh authenticates over tailnet identity, so there is no key to seed on
    // live media - the exact problem that cost a rebuild when the installer
    // image shipped without its harness key.
    println!("==> starting tailscale");
    // The daemon is installed but not enabled at boot: joining a tailnet is an
    // explicit act, not something live media should do on its own.
    let _ = run_cmd("systemctl", &["start", "tailscaled"]);
    let mut child = Command::new("tailscale")
        .args(["up", "--ssh", "--accept-risk=all"])
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| format!("tailscale: {e}"))?;

    // The login URL arrives on stderr and must be shown as it appears, not
    // after the command finishes - the command does not finish until it has
    // been visited.
    if let Some(err) = child.stderr.take() {
        for line in BufReader::new(err).lines().map_while(Result::ok) {
            println!("    {line}");
        }
    }

    let status = child.wait().map_err(|e| e.to_string())?;
    if !status.success() {
        return Err("tailscale up failed".into());
    }

    match current_host() {
        Some(name) => {
            println!("\nconnected as {name}");
            println!("\n  ssh {name}");
            Ok(())
        }
        None => Err("tailscale reported success but the machine is not up".into()),
    }
}

/// This machine's tailnet name, or None if it is not connected.
fn current_host() -> Option<String> {
    let out = Command::new("tailscale").args(["status", "--json"]).output().ok()?;
    if !out.status.success() {
        return None;
    }
    let v: serde_json::Value = serde_json::from_slice(&out.stdout).ok()?;
    if v.get("BackendState")?.as_str()? != "Running" {
        return None;
    }
    let name = v.get("Self")?.get("DNSName")?.as_str()?;
    Some(name.trim_end_matches('.').to_string())
}

fn have(cmd: &str) -> bool {
    Command::new(cmd)
        .arg("--version")
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

fn run_cmd(cmd: &str, args: &[&str]) -> Result<(), String> {
    let status =
        Command::new(cmd).args(args).status().map_err(|e| format!("{cmd}: {e}"))?;
    if status.success() {
        Ok(())
    } else {
        Err(format!("{cmd} {} failed", args.join(" ")))
    }
}
