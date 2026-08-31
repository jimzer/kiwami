use crate::theme;
use serde::Serialize;

/// An action the launcher can offer alongside .desktop applications, so the
/// shell is drivable without opening a terminal.
#[derive(Serialize)]
pub struct Entry {
    pub name: String,
    pub description: String,
    /// Argv, not a shell string: the shell execs it directly.
    pub exec: Vec<String>,
}

pub fn all() -> Vec<Entry> {
    let mut out = Vec::new();
    let current = theme::current();

    for name in theme::list().unwrap_or_default() {
        let active = current.as_deref() == Some(name.as_str());
        out.push(Entry {
            name: format!("Theme: {name}"),
            description: if active {
                "Reapply the active theme".into()
            } else {
                format!("Switch to the {name} theme")
            },
            exec: vec!["kiwami".into(), "theme".into(), "set".into(), name],
        });
    }

    // Also reachable from the power menu (SUPER+SHIFT+P); offered here so the
    // launcher is a single place to reach anything.
    for (label, argv) in [
        ("Lock", vec!["hyprlock"]),
        ("Suspend", vec!["systemctl", "suspend"]),
        ("Log out", vec!["hyprctl", "dispatch", "exit"]),
        ("Reboot", vec!["systemctl", "reboot"]),
        ("Shut down", vec!["systemctl", "poweroff"]),
    ] {
        out.push(Entry {
            name: format!("Power: {label}"),
            description: String::new(),
            exec: argv.into_iter().map(String::from).collect(),
        });
    }

    out.push(Entry {
        name: "System: doctor".into(),
        description: "Check for drift and desktop health".into(),
        exec: vec!["ghostty".into(), "-e".into(), "sh".into(), "-c".into(),
                   "kiwami doctor; read -p 'press enter'".into()],
    });

    out.push(Entry {
        name: "Shell: restart".into(),
        description: "Restart the Kiwami shell".into(),
        exec: vec![
            "systemctl".into(), "--user".into(), "restart".into(),
            "kiwami-shell.service".into(),
        ],
    });

    out
}
