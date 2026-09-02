use std::path::PathBuf;

/// Where the working tree lives on the target machine. Themes are edited in
/// place there, which is what makes a colour change a reload rather than a
/// rebuild.
pub fn repo() -> PathBuf {
    if let Some(explicit) = std::env::var_os("KIWAMI_REPO") {
        return PathBuf::from(explicit);
    }
    user_home().join("kiwami")
}

/// The home of whoever invoked us, not root's.
///
/// Under sudo, HOME is /root. Everything the desktop keeps lives in the real
/// user's home, so a check run with sudo - which is how `kiwami doctor` is
/// meant to be run - looks in the wrong place and reports a machine as
/// unthemed while it is sitting there themed.
pub fn user_home() -> PathBuf {
    let here = home();
    if let Some(user) = std::env::var_os("SUDO_USER") {
        let p = PathBuf::from("/home").join(user);
        if p.is_dir() {
            return p;
        }
    }
    here
}

pub fn home() -> PathBuf {
    std::env::var_os("HOME").map(PathBuf::from).expect("HOME unset")
}

/// Where to look for themes. Generated into /etc from kiwami.theme.themes.
pub fn theme_search_paths() -> Vec<PathBuf> {
    // Themes come from the flake. The only other entry is the checkout, so a
    // developer sees their edits without a rebuild.
    let mut paths = Vec::new();
    if let Some(sys) = std::env::var_os("KIWAMI_THEMES") {
        paths.push(PathBuf::from(sys));
    }
    paths.push(PathBuf::from("/etc/kiwami/themes"));
    paths
}

/// First search path that actually contains this theme.
pub fn find_theme(name: &str) -> Option<PathBuf> {
    theme_search_paths()
        .into_iter()
        .map(|p| p.join(name))
        .find(|p| p.join("colors.json").is_file())
}

pub fn state() -> PathBuf {
    user_home().join(".local/state/kiwami")
}

/// The stable path every themed application points at. Switching themes
/// changes what is here; no application config is ever rewritten.
pub fn current_theme() -> PathBuf {
    state().join("current/theme")
}

pub fn current_theme_name_file() -> PathBuf {
    state().join("current/theme.name")
}
