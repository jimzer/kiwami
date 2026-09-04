//! `kiwami auth` - which tools still need a credential, and log in to them.
//!
//! A reinstall reformats /persist along with everything else, so every
//! credential on the machine goes with it: the tailnet node identity, the gh
//! token, the wifi passwords. They come back one at a time, from memory, and
//! the one that gets forgotten is the one nothing complains about until it is
//! needed - which on this machine has twice been "the laptop is unreachable".
//!
//! So the list is the product, not the logging in. `kiwami auth` answers "what
//! is not set up yet" in one place; `--login` walks the gaps.
//!
//! Providers are skipped when their tool is absent rather than reported as
//! missing. What is installed follows from the flake, so a machine that does
//! not ship gh should not be told it has an unauthenticated gh - the same
//! reason `kiwami doctor` stopped carrying a hardcoded list of paths to scan.

use std::process::{Command, Stdio};

pub enum State {
    /// Authenticated, with whatever identity the tool reports.
    Ok(String),
    /// Installed, but no credential yet.
    Missing(String),
}

pub struct Provider {
    pub name: &'static str,
    /// What is lost without it, in the user's terms - shown next to a gap so
    /// the list can be triaged without knowing what each tool does.
    pub what: &'static str,
    pub state: State,
    /// The command that fixes it, run with the terminal attached: these are
    /// browser approvals and prompts, not things to capture and summarise.
    pub login: Vec<String>,
}

/// Everything present on this machine that takes a credential.
pub fn providers() -> Vec<Provider> {
    let mut out = Vec::new();

    if have("tailscale") {
        out.push(Provider {
            name: "tailscale",
            what: "remote access to this machine",
            state: match tailscale_identity() {
                Some(name) => State::Ok(name),
                None => State::Missing("not joined to a tailnet".into()),
            },
            // Not `kiwami remote`: that is the installer's front door and
            // prints its own warning about handing out a root shell. Here the
            // machine is already installed and the node just needs to log in.
            login: sudo_if_needed(&["tailscale", "up", "--ssh"]),
        });
    }

    if have("gh") {
        out.push(Provider {
            name: "gh",
            what: "pushing this machine's config to GitHub",
            state: match gh_identity() {
                Some(name) => State::Ok(name),
                None => State::Missing("not logged in".into()),
            },
            login: as_user(&["gh", "auth", "login"]),
        });
    }

    out
}

pub fn run(login: bool) -> Result<(), String> {
    let list = providers();
    if list.is_empty() {
        println!("nothing here takes a credential");
        return Ok(());
    }

    let width = list.iter().map(|p| p.name.len()).max().unwrap_or(0);
    let mut missing = Vec::new();

    for p in &list {
        match &p.state {
            State::Ok(who) => println!("  ok      {:width$}  {who}", p.name),
            State::Missing(why) => {
                println!("  MISSING {:width$}  {why} - {}", p.name, p.what);
                missing.push(p);
            }
        }
    }

    if missing.is_empty() {
        println!("\neverything is authenticated");
        return Ok(());
    }

    if !login {
        println!("\n{} to set up. Run `kiwami auth login` to do them now.", missing.len());
        // Non-zero so this is usable as a check, the same way `doctor` is.
        return Err(String::new());
    }

    for p in &missing {
        println!("\n==> {} ({})", p.name, p.what);
        println!("    {}", p.login.join(" "));
        let status = Command::new(&p.login[0])
            .args(&p.login[1..])
            .status()
            .map_err(|e| format!("{}: {e}", p.login[0]))?;
        // Judged on the outcome, not the exit code.
        //
        // `gh auth login` succeeds, then tries to write git_protocol into a
        // config.yml the flake owns read-only, and exits non-zero. Believing
        // that told you the login had failed while you were, in fact, logged
        // in. Asking the tool what its state is now costs one call and cannot
        // be wrong in that direction.
        let now = providers()
            .into_iter()
            .find(|q| q.name == p.name)
            .map(|q| matches!(q.state, State::Ok(_)))
            .unwrap_or(false);
        if now {
            if !status.success() {
                println!("    {} is authenticated (it exited non-zero anyway)", p.name);
            }
        } else {
            // One failure does not stop the walk. The point of the command is
            // to get through the list, and a tailnet login that was cancelled
            // should not hide that gh is still unauthenticated.
            println!("    {} did not complete - rerun `kiwami auth login`", p.name);
        }
    }

    println!("\n==> now");
    run_status_only()
}

fn run_status_only() -> Result<(), String> {
    for p in providers() {
        match p.state {
            State::Ok(who) => println!("  ok      {}  {who}", p.name),
            State::Missing(why) => println!("  MISSING {}  {why}", p.name),
        }
    }
    Ok(())
}

/// How many providers still need a credential. Used by `kiwami doctor`, which
/// reports but never prompts.
pub fn missing_count() -> usize {
    providers().iter().filter(|p| matches!(p.state, State::Missing(_))).count()
}

fn tailscale_identity() -> Option<String> {
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

fn gh_identity() -> Option<String> {
    // `gh auth status` exits non-zero when logged out, and prints the account
    // on a line like "Logged in to github.com account jimzer (...)". Reading
    // the token file instead would mean parsing hosts.yml, which is the file
    // gh owns.
    //
    // HOME is overridden because `kiwami doctor` is meant to be run with sudo,
    // where HOME is /root: gh would look in root's config, find no token, and
    // report a logged-out machine that is logged in. The same mistake once had
    // doctor calling a themed machine unthemed.
    let out = Command::new("gh")
        .args(["auth", "status"])
        .env("HOME", crate::paths::user_home())
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    let text = String::from_utf8_lossy(&out.stdout) + String::from_utf8_lossy(&out.stderr);
    for line in text.lines() {
        if let Some(rest) = line.split(" account ").nth(1) {
            let name = rest.split_whitespace().next()?;
            return Some(name.to_string());
        }
    }
    Some("logged in".into())
}

/// tailscale up needs root, so ask for it when we do not have it.
fn sudo_if_needed(argv: &[&str]) -> Vec<String> {
    let mut v: Vec<String> = argv.iter().map(|s| s.to_string()).collect();
    if !crate::install::is_root() {
        v.insert(0, "sudo".into());
    }
    v
}

/// gh is the opposite case: run as root it writes its token into /root, and
/// the user's own shell still reports logged out - having done the browser
/// approval and been told it worked. So drop back to the invoking user when
/// this was reached through sudo.
fn as_user(argv: &[&str]) -> Vec<String> {
    let mut v: Vec<String> = argv.iter().map(|s| s.to_string()).collect();
    if crate::install::is_root() {
        if let Some(user) = std::env::var_os("SUDO_USER") {
            let mut prefixed = vec!["sudo".to_string(), "-u".to_string(), user.to_string_lossy().into_owned()];
            prefixed.append(&mut v);
            return prefixed;
        }
    }
    v
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
