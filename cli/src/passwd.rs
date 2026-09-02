//! `kiwami passwd` - set a password that survives a wipe.
//!
//! On a machine with an ephemeral root, /etc/shadow is discarded at every
//! boot, so the ordinary `passwd` reports success and changes nothing that
//! lasts. The hash lives in a file under /persist instead, read at
//! activation.
//!
//! This exists because the obvious action is the wrong one, silently. A
//! command that does the right thing is worth more than a note in a README
//! explaining why `passwd` lied.

use std::io::{self, Write};
use std::path::PathBuf;
use std::process::Command;

use crate::install;

pub fn run(user: Option<String>) -> Result<(), String> {
    if !install::is_root() {
        return Err("must run as root (try: sudo kiwami passwd)".into());
    }

    let user = user
        .or_else(|| std::env::var("SUDO_USER").ok())
        .ok_or("cannot tell whose password to set; pass a username")?;

    let dir = password_dir()?;
    let target = dir.join(&user);

    let first = prompt_secret(&format!("New password for {user}: "))?;
    if first.is_empty() {
        return Err("empty password".into());
    }
    let again = prompt_secret("Again: ")?;
    if first != again {
        // Worth being strict about: the failure lands at a login prompt, on a
        // machine whose root was just wiped.
        return Err("passwords do not match; nothing was written".into());
    }

    let hash = hash(&first)?;
    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    std::fs::write(&target, format!("{hash}\n")).map_err(|e| e.to_string())?;

    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(&target, std::fs::Permissions::from_mode(0o600))
        .map_err(|e| e.to_string())?;
    println!("wrote {}", target.display());

    // The file is read at activation, so writing it is not enough - without
    // this the password changes at the next rebuild or reboot rather than
    // now, which is its own small surprise.
    //
    // Re-applying the running system rather than `nixos-rebuild switch`: it
    // needs no flake reference, cannot pull in unrelated changes somebody
    // committed, and re-runs exactly the step that reads this file.
    println!("==> applying");
    let activate = "/run/current-system/bin/switch-to-configuration";
    match Command::new(activate).arg("switch").status() {
        Ok(s) if s.success() => println!("done"),
        _ => println!("could not activate; the password applies at the next rebuild or boot"),
    }
    Ok(())
}

/// Where the hashes live, read from the machine's own generated config rather
/// than a constant repeated here - the Nix option is the contract, and a
/// second copy of the path in Rust is a second thing to keep in step.
fn password_dir() -> Result<PathBuf, String> {
    let generated = std::fs::read_to_string("/etc/kiwami/password-dir")
        .map_err(|_| "this machine has no kiwami.passwordFile - it does not use an \
                      ephemeral root, so ordinary passwd works and survives")?;
    Ok(PathBuf::from(generated.trim()))
}

fn hash(password: &str) -> Result<String, String> {
    use std::process::Stdio;

    let mut child = Command::new("mkpasswd")
        .args(["-m", "sha-512", "-s"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .map_err(|e| format!("mkpasswd: {e}"))?;

    // take(), not as_mut(): the handle has to be dropped so mkpasswd sees EOF.
    // Holding it open and then reading stdout is a deadlock - it waits for the
    // rest of its input, we wait for its output, and the command simply hangs
    // with no error to show for it.
    {
        let mut stdin = child.stdin.take().ok_or("no stdin for mkpasswd")?;
        stdin.write_all(password.as_bytes()).map_err(|e| e.to_string())?;
    }

    let out = child.wait_with_output().map_err(|e| e.to_string())?;
    if !out.status.success() {
        return Err("mkpasswd failed".into());
    }
    let hash = String::from_utf8_lossy(&out.stdout).trim().to_string();
    if hash.is_empty() {
        return Err("mkpasswd produced no hash".into());
    }
    Ok(hash)
}

fn prompt_secret(msg: &str) -> Result<String, String> {
    print!("{msg}");
    io::stdout().flush().ok();
    let hidden = Command::new("stty").arg("-echo").status().is_ok();
    let mut line = String::new();
    let read = io::stdin().read_line(&mut line);
    if hidden {
        let _ = Command::new("stty").arg("echo").status();
        println!();
    }
    read.map_err(|e| e.to_string())?;
    Ok(line.trim_end_matches(['\n', '\r']).to_string())
}
