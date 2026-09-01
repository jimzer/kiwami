//! A very small Nix value builder.
//!
//! The disk layout is a nested structure - encryption wraps the root content,
//! LVM nests inside that, a second disk repeats the whole shape - and building
//! it by splicing formatted strings means managing indentation and matching
//! braces by hand for every combination. Text templating has the same problem;
//! the difficulty is the nesting, not the layout.
//!
//! Building a value and printing it once gets both right by construction, so
//! adding a case is composing data rather than counting spaces.

use std::fmt::Write;

pub enum Nix {
    /// A quoted string.
    Str(String),
    /// An expression emitted verbatim - `true`, `[ "a" ]`, a path.
    Raw(String),
    List(Vec<Nix>),
    Attrs(Vec<Field>),
}

pub struct Field {
    pub comment: Option<String>,
    pub key: String,
    pub value: Nix,
}

pub fn field(key: &str, value: Nix) -> Field {
    Field { comment: None, key: key.into(), value }
}

/// A field carrying a comment. Generated config gets read by people, and the
/// reason for a line is worth more than the line.
pub fn noted(key: &str, comment: &str, value: Nix) -> Field {
    Field { comment: Some(comment.into()), key: key.into(), value }
}

pub fn s(v: &str) -> Nix {
    Nix::Str(v.into())
}
pub fn raw(v: &str) -> Nix {
    Nix::Raw(v.into())
}
pub fn attrs(fields: Vec<Field>) -> Nix {
    Nix::Attrs(fields)
}

impl Nix {
    pub fn render(&self, indent: usize) -> String {
        let pad = "  ".repeat(indent);
        let inner = "  ".repeat(indent + 1);
        match self {
            Nix::Str(v) => format!("\"{}\"", v.replace('\\', "\\\\").replace('"', "\\\"")),
            Nix::Raw(v) => v.clone(),
            Nix::List(items) => {
                if items.is_empty() {
                    return "[ ]".into();
                }
                let body: Vec<String> =
                    items.iter().map(|i| format!("{inner}{}", i.render(indent + 1))).collect();
                format!("[\n{}\n{pad}]", body.join("\n"))
            }
            Nix::Attrs(fields) => {
                if fields.is_empty() {
                    return "{ }".into();
                }
                let mut out = String::from("{\n");
                for f in fields {
                    if let Some(c) = &f.comment {
                        for line in c.lines() {
                            let _ = writeln!(out, "{inner}# {line}");
                        }
                    }
                    let _ = writeln!(out, "{inner}{} = {};", f.key, f.value.render(indent + 1));
                }
                let _ = write!(out, "{pad}}}");
                out
            }
        }
    }
}
