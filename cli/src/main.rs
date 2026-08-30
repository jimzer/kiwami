mod commands;
mod paths;
mod theme;

use clap::{Parser, Subcommand};

#[derive(Parser)]
#[command(name = "kiwami", version, about = "Kiwami desktop control")]
struct Cli {
    #[command(subcommand)]
    command: Cmd,
}

#[derive(Subcommand)]
enum Cmd {
    /// Manage the active theme
    Theme {
        #[command(subcommand)]
        action: ThemeCmd,
    },
    /// Emit the actions the launcher should offer, as JSON
    Commands {
        /// Currently the only supported format; present so the shape is explicit.
        #[arg(long, default_value_t = true)]
        json: bool,
    },
}

#[derive(Subcommand)]
enum ThemeCmd {
    /// List available themes
    List,
    /// Print the active theme
    Current,
    /// Apply a theme (defaults to reapplying the active one)
    Set { name: Option<String> },
}

fn main() -> std::process::ExitCode {
    let cli = Cli::parse();

    match cli.command {
        Cmd::Theme { action } => match action {
            ThemeCmd::List => {
                let current = theme::current();
                match theme::list() {
                    Ok(names) if !names.is_empty() => {
                        for n in names {
                            let marker = if current.as_deref() == Some(n.as_str()) { "*" } else { " " };
                            println!("{marker} {n}");
                        }
                    }
                    Ok(_) => eprintln!("no themes found in {}", paths::themes_dir().display()),
                    Err(e) => {
                        eprintln!("cannot read {}: {e}", paths::themes_dir().display());
                        return std::process::ExitCode::FAILURE;
                    }
                }
            }
            ThemeCmd::Current => match theme::current() {
                Some(n) => println!("{n}"),
                None => {
                    eprintln!("no theme applied yet");
                    return std::process::ExitCode::FAILURE;
                }
            },
            ThemeCmd::Set { name } => match theme::set(name) {
                Ok(n) => println!("theme: {n}"),
                Err(e) => {
                    eprintln!("{e}");
                    return std::process::ExitCode::FAILURE;
                }
            },
        },
        Cmd::Commands { .. } => {
            let entries = commands::all();
            println!("{}", serde_json::to_string_pretty(&entries).unwrap());
        }
    }

    std::process::ExitCode::SUCCESS
}
