//! Network setup, for the installer and for anyone stuck at a console.
//!
//! The installer needs to download a few gigabytes from the binary cache, so
//! "am I online" has to be answered before a disk is touched - failing on
//! network after erasing the disk leaves you with neither a system nor a way
//! to get one.
//!
//! Everything here goes through NetworkManager, which the installer ISO
//! enables by default (nixos/modules/profiles/installation-device.nix).

use std::io::{self, BufRead, Write};
use std::process::{Command, Stdio};

/// A small, always-present file on the binary cache. Fetching it proves the
/// thing we actually care about: that `nixos-install` can reach substituters.
const PROBE: &str = "https://cache.nixos.org/nix-cache-info";

/// Deliberately not "is there a default route". A captive portal hands out a
/// lease, a gateway and DNS, then serves a login page for every request - by
/// every local measure you are online, and the install still fails. Asking
/// for a real file over TLS is the only honest test.
pub fn online() -> bool {
    Command::new("curl")
        .args(["-sf", "--max-time", "8", "-o", "/dev/null", PROBE])
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

/// Ensure there is a working connection, prompting for wifi if needed.
///
/// `interactive` is false under `--yes`: an unattended run must fail loudly
/// rather than block forever on a password prompt nobody will answer.
pub fn ensure(interactive: bool) -> Result<(), String> {
    if online() {
        return Ok(());
    }

    // Connecting a device or joining a network is privileged, and finding
    // that out from a polkit timeout several steps in is worse than being
    // told now.
    if !crate::install::is_root() {
        return Err("no network, and fixing that needs root (try: sudo kiwami net)".into());
    }

    if !have_nmcli() {
        return Err("no network, and NetworkManager is not available to set one up.\n\
                    Connect manually, then run this again."
            .into());
    }

    // Ethernet that is plugged in but idle is the cheap case: NetworkManager
    // brings it up with no questions asked.
    if let Some(dev) = idle_ethernet()? {
        println!("    trying ethernet on {dev}");
        let _ = nmcli(&["device", "connect", &dev]);
        if settle() {
            return Ok(());
        }
    }

    if !interactive {
        return Err("no network. Connect first (kiwami net), or plug in ethernet.".into());
    }

    connect_wifi()
}

/// Print what we can see. Changes nothing.
pub fn status() -> Result<(), String> {
    println!("cache.nixos.org: {}", if online() { "reachable" } else { "UNREACHABLE" });
    if !have_nmcli() {
        println!("NetworkManager:  not available (nmcli is not on PATH)");
        return Ok(());
    }
    println!("NetworkManager:  available");
    println!("\nDevices:");
    for d in devices()? {
        println!("  {:<12} {:<10} {}", d.name, d.kind, d.state);
    }
    Ok(())
}

// --- wifi ----------------------------------------------------------------

struct Network {
    ssid: String,
    signal: u8,
    secured: bool,
}

fn connect_wifi() -> Result<(), String> {
    if !devices()?.iter().any(|d| d.kind == "wifi") {
        return Err("no network, and no wifi device found.\n\
                    If this machine has wifi, the firmware may be missing."
            .into());
    }

    loop {
        println!("    scanning");
        // A rescan on a device that just came up often reports "not allowed"
        // while the first scan is still running; the list below is what
        // matters, so a failure here is not fatal.
        let _ = nmcli(&["device", "wifi", "rescan"]);
        let networks = scan()?;

        if networks.is_empty() {
            return Err("no wifi networks found. Move closer, or use `nmtui` for a hidden SSID.".into());
        }

        println!("\nNetworks:\n");
        for (i, n) in networks.iter().enumerate() {
            println!(
                "  {}) {:<32} {:>3}%  {}",
                i + 1,
                n.ssid,
                n.signal,
                if n.secured { "locked" } else { "open" }
            );
        }
        println!("\n  r) rescan");

        let answer = prompt(&format!("\nWhich network? [1-{}] ", networks.len()))?;
        if answer.eq_ignore_ascii_case("r") {
            continue;
        }
        let chosen = match answer.parse::<usize>() {
            Ok(n) if n >= 1 && n <= networks.len() => &networks[n - 1],
            _ => {
                println!("Enter a number between 1 and {}, or r to rescan.", networks.len());
                continue;
            }
        };

        // No shell is involved, so the SSID and password go through as single
        // argv entries; spaces and quotes in either are not our problem.
        let mut args = vec!["device", "wifi", "connect", &chosen.ssid];
        let password;
        if chosen.secured {
            password = prompt_secret(&format!("Password for {}: ", chosen.ssid))?;
            args.push("password");
            args.push(&password);
        }

        match nmcli(&args) {
            Ok(_) => {
                if settle() {
                    println!("    connected to {}", chosen.ssid);
                    return Ok(());
                }
                // Associated but no route out: usually a captive portal, or a
                // lease that has not arrived yet.
                println!("    joined {} but cannot reach the internet", chosen.ssid);
            }
            Err(e) => println!("    {e}"),
        }

        if !prompt("\nTry another network? [y/N] ")?.eq_ignore_ascii_case("y") {
            return Err("no network".into());
        }
    }
}

fn scan() -> Result<Vec<Network>, String> {
    let out = nmcli(&["-t", "-f", "SSID,SIGNAL,SECURITY", "device", "wifi", "list"])?;

    let mut seen: Vec<Network> = Vec::new();
    for line in out.lines() {
        let f = split_terse(line);
        if f.len() < 3 {
            continue;
        }
        // An empty SSID is a hidden network. It cannot be joined by name, so
        // listing it as a blank menu entry only invites a wasted attempt.
        let ssid = f[0].trim().to_string();
        if ssid.is_empty() {
            continue;
        }
        let signal: u8 = f[1].trim().parse().unwrap_or(0);
        let secured = !f[2].trim().is_empty() && f[2].trim() != "--";

        // One SSID, several access points: keep the strongest.
        match seen.iter_mut().find(|n| n.ssid == ssid) {
            Some(existing) if existing.signal < signal => existing.signal = signal,
            Some(_) => {}
            None => seen.push(Network { ssid, signal, secured }),
        }
    }
    seen.sort_by(|a, b| b.signal.cmp(&a.signal));
    Ok(seen)
}

// --- devices -------------------------------------------------------------

struct Device {
    name: String,
    kind: String,
    state: String,
}

fn devices() -> Result<Vec<Device>, String> {
    Ok(nmcli(&["-t", "-f", "DEVICE,TYPE,STATE", "device"])?
        .lines()
        .filter_map(|l| {
            let f = split_terse(l);
            (f.len() >= 3).then(|| Device {
                name: f[0].clone(),
                kind: f[1].clone(),
                state: f[2].clone(),
            })
        })
        .collect())
}

/// An ethernet device that exists but is not carrying traffic. "unavailable"
/// means no carrier - no cable - so there is nothing to try there.
fn idle_ethernet() -> Result<Option<String>, String> {
    Ok(devices()?
        .into_iter()
        .find(|d| d.kind == "ethernet" && d.state != "connected" && d.state != "unavailable")
        .map(|d| d.name))
}

// --- plumbing ------------------------------------------------------------

fn have_nmcli() -> bool {
    Command::new("nmcli")
        .arg("--version")
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

fn nmcli(args: &[&str]) -> Result<String, String> {
    let out = Command::new("nmcli")
        .args(args)
        .output()
        .map_err(|e| format!("nmcli: {e}"))?;
    if !out.status.success() {
        return Err(String::from_utf8_lossy(&out.stderr).trim().to_string());
    }
    Ok(String::from_utf8_lossy(&out.stdout).to_string())
}

/// DHCP and DNS do not finish the instant nmcli returns, so a single probe
/// straight after connecting reports failure on a link that is about to work.
fn settle() -> bool {
    for _ in 0..6 {
        if online() {
            return true;
        }
        std::thread::sleep(std::time::Duration::from_secs(2));
    }
    false
}

/// `nmcli -t` separates fields with ':' and backslash-escapes any ':' or '\'
/// inside a value. SSIDs containing a colon are unusual but legal, and a
/// naive split() on them silently produces a wrong menu.
fn split_terse(line: &str) -> Vec<String> {
    let mut fields = vec![String::new()];
    let mut chars = line.chars();
    while let Some(c) = chars.next() {
        match c {
            '\\' => {
                if let Some(escaped) = chars.next() {
                    fields.last_mut().unwrap().push(escaped);
                }
            }
            ':' => fields.push(String::new()),
            _ => fields.last_mut().unwrap().push(c),
        }
    }
    fields
}

fn prompt(msg: &str) -> Result<String, String> {
    print!("{msg}");
    io::stdout().flush().ok();
    let mut line = String::new();
    io::stdin().lock().read_line(&mut line).map_err(|e| e.to_string())?;
    Ok(line.trim().to_string())
}

/// Turning the echo off via stty rather than pulling in a crate for it: the
/// installer already runs on a real tty and shells out for everything else.
fn prompt_secret(msg: &str) -> Result<String, String> {
    print!("{msg}");
    io::stdout().flush().ok();
    let hidden = Command::new("stty").arg("-echo").status().is_ok();
    let mut line = String::new();
    let read = io::stdin().lock().read_line(&mut line);
    if hidden {
        let _ = Command::new("stty").arg("echo").status();
        println!();
    }
    read.map_err(|e| e.to_string())?;
    Ok(line.trim_end_matches(['\n', '\r']).to_string())
}
