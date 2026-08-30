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

pub fn themes_dir() -> PathBuf {
    repo().join("config/themes")
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
