//! `kiwami shell` - inspect and override the desktop shell's QML.
//!
//! The shell loads a merged tree: what ships (or a developer's checkout)
//! first, then ~/.config/kiwami/shell overwriting by filename. So overriding
//! one widget means putting one file in the user directory - everything else
//! keeps updating with the distro.

use std::collections::BTreeMap;
use std::fs;
use std::hash::{DefaultHasher, Hash, Hasher};
use std::path::PathBuf;

use crate::paths;

fn system_tree() -> PathBuf {
    // A checkout wins, matching what the launcher does, so `clone` in a dev
    // environment copies the file actually being loaded.
    let dev = paths::repo().join("shell");
    if dev.join("shell.qml").is_file() {
        dev
    } else {
        PathBuf::from("/etc/kiwami/shell")
    }
}

fn user_tree() -> PathBuf {
    paths::home().join(".config/kiwami/shell")
}

/// Relative paths of every QML file in a tree.
fn qml_files(root: &PathBuf) -> Vec<String> {
    fn walk(dir: &PathBuf, base: &PathBuf, out: &mut Vec<String>) {
        let Ok(entries) = fs::read_dir(dir) else { return };
        for e in entries.flatten() {
            let p = e.path();
            if p.is_dir() {
                walk(&p, base, out);
            } else if p.extension().map(|x| x == "qml").unwrap_or(false) {
                if let Ok(rel) = p.strip_prefix(base) {
                    out.push(rel.to_string_lossy().to_string());
                }
            }
        }
    }
    let mut out = Vec::new();
    walk(root, root, &mut out);
    out.sort();
    out
}

/// Records what a clone was copied from, so we can tell later whether the
/// shipped version has moved on. A stale override is the real hazard of
/// shadowing: it keeps loading, referencing things that no longer exist, and
/// the failure looks like a shell bug rather than an old copy.
fn origins_path() -> PathBuf {
    user_tree().join(".origins.json")
}

fn digest(path: &PathBuf) -> Option<String> {
    let bytes = fs::read(path).ok()?;
    let mut h = DefaultHasher::new();
    bytes.hash(&mut h);
    Some(format!("{:x}", h.finish()))
}

fn read_origins() -> BTreeMap<String, String> {
    fs::read_to_string(origins_path())
        .ok()
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or_default()
}

fn write_origins(map: &BTreeMap<String, String>) -> Result<(), String> {
    let path = origins_path();
    if let Some(p) = path.parent() {
        fs::create_dir_all(p).map_err(|e| e.to_string())?;
    }
    fs::write(&path, serde_json::to_string_pretty(map).unwrap()).map_err(|e| e.to_string())
}

pub fn list() -> Result<(), String> {
    let sys = system_tree();
    let mine = user_tree();
    let shipped = qml_files(&sys);
    let overridden = qml_files(&mine);

    if shipped.is_empty() {
        return Err(format!("no shell found at {}", sys.display()));
    }

    let origins = read_origins();

    println!("shipped  ({})", sys.display());
    for f in &shipped {
        let marker = if !overridden.contains(f) {
            String::new()
        } else {
            // If what ships no longer matches what was cloned, the override
            // was written against an older version and may reference things
            // that have since moved.
            match (origins.get(f), digest(&sys.join(f))) {
                (Some(was), Some(now)) if *was != now =>
                    "\x1b[31m overridden - SHIPPED VERSION HAS CHANGED\x1b[0m".to_string(),
                (None, _) => "\x1b[33m overridden (origin unknown)\x1b[0m".to_string(),
                _ => "\x1b[33m overridden\x1b[0m".to_string(),
            }
        };
        println!("  {f}{marker}");
    }

    // Files only in the user tree are additions, not overrides - a new widget.
    let extra: Vec<&String> = overridden.iter().filter(|f| !shipped.contains(f)).collect();
    if !extra.is_empty() {
        println!("\nyours    ({})", mine.display());
        for f in extra {
            println!("  {f}  \x1b[32madded\x1b[0m");
        }
    }
    Ok(())
}

pub fn clone(name: &str) -> Result<(), String> {
    let sys = system_tree();
    let shipped = qml_files(&sys);

    // Accept "clock", "Clock", "Clock.qml" or "widgets/Clock.qml".
    let wanted = shipped
        .iter()
        .find(|f| {
            let stem = f.rsplit('/').next().unwrap_or(f).trim_end_matches(".qml");
            f.as_str() == name
                || stem == name
                || stem.eq_ignore_ascii_case(name)
                || format!("{stem}.qml") == name
        })
        .ok_or_else(|| {
            format!(
                "no such component: {name}\n  available: {}",
                shipped
                    .iter()
                    .map(|f| f.rsplit('/').next().unwrap_or(f).trim_end_matches(".qml"))
                    .collect::<Vec<_>>()
                    .join(", ")
            )
        })?;

    let src = sys.join(wanted);
    let dest = user_tree().join(wanted);

    if dest.exists() {
        return Err(format!("already overridden: {}", dest.display()));
    }

    if let Some(parent) = dest.parent() {
        fs::create_dir_all(parent).map_err(|e| e.to_string())?;
    }
    fs::copy(&src, &dest).map_err(|e| e.to_string())?;

    // Store files are 444 and copy preserves the mode, so without this the
    // user cannot edit the file they just asked for a copy of.
    let mut perms = fs::metadata(&dest).map_err(|e| e.to_string())?.permissions();
    #[allow(clippy::permissions_set_readonly_false)]
    perms.set_readonly(false);
    fs::set_permissions(&dest, perms).map_err(|e| e.to_string())?;

    let mut origins = read_origins();
    if let Some(d) = digest(&src) {
        origins.insert(wanted.clone(), d);
        write_origins(&origins)?;
    }

    println!("{}", dest.display());
    println!("edit it, then: systemctl --user restart kiwami-shell");
    Ok(())
}
