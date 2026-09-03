//! `kiwami snapshot` - /persist, in a bucket, encrypted.
//!
//! The machine is declarative, so the only irreplaceable state is what
//! kiwami.persist declares. That makes /persist the whole target and means
//! there are no per-directory policies to drift out of date: one list answers
//! "what survives a reboot", "what survives the disk dying", and "what is
//! `kiwami doctor` checking for gaps".
//!
//! restic over an S3-compatible bucket, because it encrypts client-side - the
//! provider stores ciphertext - deduplicates, and restores from any machine
//! with the passphrase.
//!
//! The design constraint that shaped everything here: the credentials must
//! survive the thing the backup protects against. A passphrase that lives only
//! on the machine is worthless the moment you need it. So `setup` generates a
//! passphrase you can memorise rather than a random string you cannot, and
//! prints it once, loudly, for you to put somewhere that is not this disk.

use std::fs;
use std::io::Write;
use std::os::unix::fs::PermissionsExt;
use std::path::Path;
use std::process::{Command, Stdio};

/// EFF's short wordlist: 1296 words chosen to be easy to type and to
/// remember. Eight of them is about 82 bits, which is stronger than the
/// 32-character random string it replaces and can be said out loud.
const WORDS: &str = include_str!("../data/wordlist.txt");

const CRED_DEFAULT: &str = "/var/lib/kiwami/backup/env";

/// Plain lowercase words only. EFF's list contains "yo-yo", which would be
/// ambiguous once the words are joined with hyphens - a passphrase you cannot
/// unambiguously read back to yourself is a bad passphrase, however many bits
/// it has.
fn wordlist() -> Vec<&'static str> {
    WORDS
        .lines()
        .map(str::trim)
        .filter(|w| !w.is_empty() && w.chars().all(|c| c.is_ascii_lowercase()))
        .collect()
}

pub fn setup(repository: Option<String>) -> Result<(), String> {
    require_root()?;
    have("restic")?;

    let cred = CRED_DEFAULT;
    if Path::new(cred).exists() {
        println!("{cred} already exists.");
        println!("Delete it first if you mean to point this machine somewhere else.");
        return Ok(());
    }

    let repo = match repository {
        Some(r) => r,
        None => prompt("Repository (e.g. s3:https://<account>.r2.cloudflarestorage.com/bucket/prefix): ")?,
    };
    if repo.trim().is_empty() {
        return Err("a repository is required".into());
    }

    println!("\nThe bucket's access keys. On Cloudflare R2 these come from");
    println!("R2 > Manage R2 API tokens > Create API token, with Object Read & Write.");
    let key = prompt("Access key ID: ")?;
    let secret = prompt("Secret access key: ")?;

    // Whether this is a first backup or a machine joining an existing
    // repository decides everything below: one needs a new passphrase, the
    // other needs the passphrase that already opens it. Asking the repository
    // is more reliable than asking the person.
    let existing = repo_exists(&repo, &key, &secret)?;
    let password = if existing {
        println!("\nThere is already a repository here.");
        println!("Enter its passphrase - a new one cannot open it.");
        read_secret("Passphrase: ")?
    } else {
        println!("\nNothing here yet, so this will be a new repository.");
        offer_generated_passphrase()?
    };

    write_credentials(cred, &repo, &key, &secret, &password)?;

    if !existing {
        println!("\n==> creating the repository");
        restic(cred, &["init"])?;
    }

    // A backup that has never been restored is a backup that reports success
    // while doing nothing. This is the cheapest moment to find that out.
    println!("\n==> checking a backup can be written and read back");
    canary(cred)?;

    println!("\n\x1b[32mready\x1b[0m");
    println!("  sudo kiwami snapshot backup     take one now");
    println!("  systemctl status kiwami-backup  the daily timer");
    Ok(())
}

/// Take one now, through the same systemd unit the timer uses.
///
/// Not by shelling out to restic directly: the excludes and the retention
/// policy are declared in the flake, and a second copy of them here would be
/// a second thing to keep in step. Running the unit means a manual backup and
/// a scheduled one cannot differ.
pub fn backup() -> Result<(), String> {
    require_root()?;
    if !Path::new(CRED_DEFAULT).exists() {
        return Err(format!(
            "no credentials at {CRED_DEFAULT} - run: sudo kiwami snapshot setup"
        ));
    }
    println!("==> running kiwami-backup.service");
    let status = Command::new("systemctl")
        .args(["start", "--wait", "kiwami-backup.service"])
        .status()
        .map_err(|e| format!("systemctl: {e}"))?;
    let _ = Command::new("journalctl")
        .args(["-u", "kiwami-backup.service", "-n", "12", "--no-pager", "-o", "cat"])
        .status();
    if status.success() {
        Ok(())
    } else {
        Err("the backup failed - see the log above".into())
    }
}

/// What is in the repository, newest last.
pub fn status() -> Result<(), String> {
    require_root()?;
    if !Path::new(CRED_DEFAULT).exists() {
        println!("no backups configured (sudo kiwami snapshot setup)");
        return Ok(());
    }
    restic(CRED_DEFAULT, &["snapshots", "--tag", "kiwami"])
}

/// Put /persist back.
///
/// Two phases by default, and the split is not a policy exception: at install
/// time what you need is identity - wifi, ssh keys, the tailnet node, the gh
/// token - which is tens of megabytes and gets the machine online as itself.
/// Everything else, ~/Projects included, can arrive afterwards over a
/// connection that now exists.
pub fn restore(target: String, identity_only: bool, yes: bool) -> Result<(), String> {
    require_root()?;
    if !Path::new(CRED_DEFAULT).exists() {
        return Err(format!(
            "no credentials at {CRED_DEFAULT} - run: sudo kiwami snapshot setup"
        ));
    }

    if !yes {
        println!("This writes the newest snapshot into {target}.");
        println!("Files that exist there already are overwritten.");
        let answer = prompt("
Type 'yes' to restore: ")?;
        if answer != "yes" {
            return Err("nothing restored".into());
        }
    }

    let mut args: Vec<String> =
        ["restore", "latest", "--tag", "kiwami", "--target", &target]
            .iter()
            .map(|s| s.to_string())
            .collect();

    if identity_only {
        // The paths that decide whether the machine comes up as itself. Kept
        // deliberately short: anything not here is recoverable later, once
        // there is a network and a shell to recover it from.
        for p in [
            "/persist/etc",
            "/persist/var/lib/NetworkManager",
            "/persist/var/lib/tailscale",
            "/persist/var/lib/kiwami",
            "/persist/home/*/.ssh",
            "/persist/home/*/.config/gh",
        ] {
            args.push("--include".into());
            args.push(p.into());
        }
    }

    let refs: Vec<&str> = args.iter().map(String::as_str).collect();
    restic(CRED_DEFAULT, &refs)?;
    println!("
restored into {target}");
    if identity_only {
        println!("Identity only. The rest is still in the repository:");
        println!("  sudo kiwami snapshot restore");
    }
    Ok(())
}

/// Write a file, back it up, restore it elsewhere, compare, remove it.
///
/// Not "the credentials look valid": an actual round trip. Every failure this
/// project has produced was something reporting success while doing nothing,
/// and a backup is the worst possible place for that habit.
fn canary(cred: &str) -> Result<(), String> {
    let dir = "/var/lib/kiwami/backup/canary";
    let marker = format!("{dir}/canary");
    let token = format!("kiwami-canary-{}", std::process::id());
    fs::create_dir_all(dir).map_err(|e| format!("{dir}: {e}"))?;
    fs::write(&marker, &token).map_err(|e| format!("{marker}: {e}"))?;

    restic(cred, &["backup", "--tag", "canary", dir])?;

    let restored = "/var/lib/kiwami/backup/canary-restored";
    let _ = fs::remove_dir_all(restored);
    restic(cred, &["restore", "latest", "--tag", "canary", "--target", restored])?;

    let back = fs::read_to_string(format!("{restored}{marker}"))
        .map_err(|e| format!("the canary did not come back: {e}"))?;
    if back.trim() != token {
        return Err("the canary came back different from what was written".into());
    }
    println!("    wrote a file, read it back from the bucket, contents match");

    // By id, not by tag. `restic forget --tag canary` removes nothing at all -
    // forget refuses to act without a retention policy and says so as a Fatal
    // that the exit code then hides behind an ignored result, so the canary
    // quietly stayed in the repository.
    for id in snapshot_ids(cred, "canary")? {
        let _ = restic(cred, &["forget", &id, "--prune"]);
    }
    let _ = fs::remove_dir_all(dir);
    let _ = fs::remove_dir_all(restored);
    Ok(())
}

fn offer_generated_passphrase() -> Result<String, String> {
    let answer = prompt("\nGenerate a passphrase? [Y/n] ")?;
    if answer.eq_ignore_ascii_case("n") {
        let a = read_secret("Passphrase: ")?;
        let b = read_secret("Again: ")?;
        if a != b {
            return Err("they did not match".into());
        }
        if a.trim().is_empty() {
            return Err("an empty passphrase is not a passphrase".into());
        }
        return Ok(a);
    }

    let phrase = generate_passphrase(8)?;
    println!("\n\x1b[1m  {phrase}\x1b[0m\n");
    println!("Write this down somewhere that is not this machine - a password");
    println!("manager, or paper. It is the only thing that can decrypt the");
    println!("backups, and it is not recoverable: lose it and they are gone.");
    println!("\nIt is words rather than random characters on purpose: you will");
    println!("type it during an install, from memory, on a machine that has");
    println!("nothing else on it yet.");
    let seen = prompt("\nType 'saved' once it is somewhere safe: ")?;
    if seen.trim() != "saved" {
        return Err("stopping, since the passphrase is not saved anywhere".into());
    }
    Ok(phrase)
}

/// Words from /dev/urandom, rejecting the tail of the range so every word is
/// equally likely - taking the modulo of a raw 16-bit value would quietly
/// favour the first 496 words of a 1296-word list.
fn generate_passphrase(words: usize) -> Result<String, String> {
    let list = wordlist();
    let n = list.len() as u32;
    let limit = u32::MAX - (u32::MAX % n);

    let mut bytes = fs::File::open("/dev/urandom").map_err(|e| format!("/dev/urandom: {e}"))?;
    let mut out = Vec::with_capacity(words);
    while out.len() < words {
        let mut buf = [0u8; 4];
        use std::io::Read;
        bytes.read_exact(&mut buf).map_err(|e| e.to_string())?;
        let v = u32::from_le_bytes(buf);
        if v >= limit {
            continue;
        }
        out.push(list[(v % n) as usize]);
    }
    Ok(out.join("-"))
}

fn repo_exists(repo: &str, key: &str, secret: &str) -> Result<bool, String> {
    let out = Command::new("restic")
        .args(["cat", "config"])
        .env("RESTIC_REPOSITORY", repo)
        .env("AWS_ACCESS_KEY_ID", key)
        .env("AWS_SECRET_ACCESS_KEY", secret)
        // A wrong password and an absent repository are different answers;
        // this only asks whether anything is there.
        .env("RESTIC_PASSWORD", "")
        .output()
        .map_err(|e| format!("restic: {e}"))?;
    let err = String::from_utf8_lossy(&out.stderr);
    Ok(!err.contains("unable to open config file") && !err.contains("does not exist"))
}

fn write_credentials(
    path: &str,
    repo: &str,
    key: &str,
    secret: &str,
    password: &str,
) -> Result<(), String> {
    let dir = Path::new(path).parent().ok_or("bad credentials path")?;
    fs::create_dir_all(dir).map_err(|e| format!("{}: {e}", dir.display()))?;
    let body = format!(
        "# Written by `kiwami snapshot setup`. Root-readable only.\n\
         #\n\
         # Not encrypted on purpose: whatever could decrypt it at runtime is\n\
         # what an attacker would be running as. At-rest exposure is what disk\n\
         # encryption is for, and a bucket lock is what stops a compromised\n\
         # machine deleting the backups it can write.\n\
         RESTIC_REPOSITORY={repo}\n\
         RESTIC_PASSWORD='{password}'\n\
         AWS_ACCESS_KEY_ID={key}\n\
         AWS_SECRET_ACCESS_KEY={secret}\n"
    );
    fs::write(path, body).map_err(|e| format!("{path}: {e}"))?;
    fs::set_permissions(path, fs::Permissions::from_mode(0o600))
        .map_err(|e| format!("{path}: {e}"))?;
    println!("\nwrote {path}");
    Ok(())
}

/// Snapshot ids carrying a tag, newest first.
fn snapshot_ids(cred: &str, tag: &str) -> Result<Vec<String>, String> {
    let out = Command::new("bash")
        .arg("-c")
        .arg(format!(
            "set -a; . {cred}; set +a; exec restic snapshots --tag '{tag}' --json"
        ))
        .output()
        .map_err(|e| format!("restic: {e}"))?;
    if !out.status.success() {
        return Ok(Vec::new());
    }
    let v: serde_json::Value =
        serde_json::from_slice(&out.stdout).map_err(|e| format!("restic snapshots: {e}"))?;
    Ok(v.as_array()
        .map(|a| {
            a.iter()
                .filter_map(|s| s.get("short_id").and_then(|i| i.as_str()).map(String::from))
                .collect()
        })
        .unwrap_or_default())
}

fn restic(cred: &str, args: &[&str]) -> Result<(), String> {
    let status = Command::new("bash")
        .arg("-c")
        .arg(format!(
            "set -a; . {}; set +a; exec restic {}",
            cred,
            args.iter()
                .map(|a| format!("'{}'", a.replace('\'', "'\\''")))
                .collect::<Vec<_>>()
                .join(" ")
        ))
        .status()
        .map_err(|e| format!("restic: {e}"))?;
    if status.success() {
        Ok(())
    } else {
        Err(format!("restic {} failed", args.join(" ")))
    }
}

fn require_root() -> Result<(), String> {
    if crate::install::is_root() {
        Ok(())
    } else {
        Err("must run as root (try: sudo kiwami snapshot setup)".into())
    }
}

fn have(cmd: &str) -> Result<(), String> {
    Command::new(cmd)
        .arg("version")
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .map(|_| ())
        .map_err(|_| format!("{cmd} is not installed - set kiwami.backup.enable = true"))
}

fn prompt(q: &str) -> Result<String, String> {
    print!("{q}");
    std::io::stdout().flush().ok();
    let mut s = String::new();
    std::io::stdin().read_line(&mut s).map_err(|e| e.to_string())?;
    Ok(s.trim().to_string())
}

/// No echo, so a passphrase does not end up on the screen behind you or in a
/// scrollback buffer.
fn read_secret(q: &str) -> Result<String, String> {
    let saved = Command::new("stty").arg("-g").output().ok();
    let _ = Command::new("stty").arg("-echo").status();
    let value = prompt(q);
    if let Some(s) = saved {
        let _ = Command::new("stty")
            .arg(String::from_utf8_lossy(&s.stdout).trim())
            .status();
    }
    println!();
    value
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_wordlist_is_what_we_think_it_is() {
        // EFF's short list is 1296 words; one of them ("yo-yo") is dropped
        // because a hyphen is the separator. If this ever changes size, the
        // entropy claim changes with it - 1295 words is 10.34 bits each, so
        // eight words is ~82 bits. Asserted rather than assumed.
        let words = wordlist();
        assert_eq!(words.len(), 1295);
        assert!(words.iter().all(|w| w.chars().all(|c| c.is_ascii_lowercase())));
    }

    #[test]
    fn a_generated_passphrase_has_the_shape_we_promise() {
        let p = generate_passphrase(8).unwrap();
        assert_eq!(p.split('-').count(), 8);
        // Eight words from 1296 is ~82 bits. Two runs matching would mean the
        // sampling is broken.
        assert_ne!(p, generate_passphrase(8).unwrap());
    }
}
