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
