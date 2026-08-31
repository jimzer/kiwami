use std::path::PathBuf;

/// Where the working tree lives on the target machine. Themes are edited in
/// place there, which is what makes a colour change a reload rather than a
/// rebuild.
pub fn repo() -> PathBuf {
    if let Some(explicit) = std::env::var_os("KIWAMI_REPO") {
        return PathBuf::from(explicit);
    }
    let here = home().join("kiwami");
    if here.exists() {
        return here;
    }
    // Under sudo, HOME is root's, so the checkout in the invoking user's home
    // is invisible - and doctor's hardware and flake.lock checks both need
    // root. Silently reporting "no checkout here" while one sits in
    // /home/you/kiwami is worse than not having the check.
    std::env::var_os("SUDO_USER")
        .map(|u| PathBuf::from("/home").join(u).join("kiwami"))
        .filter(|p| p.exists())
        .unwrap_or(here)
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
    home().join(".local/state/kiwami")
}

/// The stable path every themed application points at. Switching themes
/// changes what is here; no application config is ever rewritten.
pub fn current_theme() -> PathBuf {
    state().join("current/theme")
}

pub fn current_theme_name_file() -> PathBuf {
    state().join("current/theme.name")
}
