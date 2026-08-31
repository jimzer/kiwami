mod commands;
mod doctor;
mod install;
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
    /// Install Kiwami to a disk. Intended to run from the live ISO.
    Install {
        /// Target disk, e.g. /dev/nvme0n1. Prompts if omitted.
        #[arg(long)]
        disk: Option<String>,
        /// Host attribute in the flake to install
        #[arg(long, default_value = "desktop")]
        host: String,
        /// Flake to install from
        #[arg(long, default_value = "github:jimzer/kiwami")]
        flake: String,
        /// Skip the confirmation prompt
        #[arg(long)]
        yes: bool,
        /// Allow running on an already-installed system
        #[arg(long)]
        force: bool,
    },
    /// List disks the installer can see, and exit
    Disks,
    /// Report drift from the declared config, and check the desktop is healthy
    Doctor,
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
                    Ok(_) => eprintln!("no themes found in any of {:?}", paths::theme_search_paths()),
                    Err(e) => {
                        eprintln!("cannot read themes: {e}");
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
        Cmd::Install { disk, host, flake, yes, force } => {
            let opts = install::Options {
                disk,
                host,
                flake,
                assume_yes: yes,
                force,
            };
            if let Err(e) = install::run_install(opts) {
                eprintln!("\ninstall: {e}");
                return std::process::ExitCode::FAILURE;
            }
        }
        Cmd::Doctor => {
            if doctor::run().is_err() {
                return std::process::ExitCode::FAILURE;
            }
        }
        Cmd::Disks => {
            if let Err(e) = install::list_disks() {
                eprintln!("{e}");
                return std::process::ExitCode::FAILURE;
            }
        }
        Cmd::Commands { .. } => {
            let entries = commands::all();
            println!("{}", serde_json::to_string_pretty(&entries).unwrap());
        }
    }

    std::process::ExitCode::SUCCESS
}
