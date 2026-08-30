use std::path::PathBuf;

/// Where the working tree lives on the target machine. Themes are edited in
/// place there, which is what makes a colour change a reload rather than a
/// rebuild.
pub fn repo() -> PathBuf {
    std::env::var_os("KIWAMI_REPO")
        .map(PathBuf::from)
        .unwrap_or_else(|| home().join("kiwami"))
}

pub fn home() -> PathBuf {
    std::env::var_os("HOME").map(PathBuf::from).expect("HOME unset")
}

/// Where to look for themes, most specific first.
///
/// The working tree wins so a theme can be edited live, but it must not be
/// *required*: an installed machine has no checkout, and CI found this by
/// failing with "cannot read ~/kiwami/config/themes". The system copy is
/// installed by modules/desktop.nix from the same directory.
pub fn theme_search_paths() -> Vec<PathBuf> {
    let mut paths = vec![repo().join("config/themes")];
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
