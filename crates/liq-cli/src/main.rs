//! LIQUIDATION operator CLI.

use anyhow::Context;
use clap::{Parser, Subcommand};
use liq_recorder::{migrations, schema};
use liq_replay::{DryRunRequest, validate_dry_run};
use sqlx::postgres::PgPoolOptions;
use tracing::info;

#[derive(Debug, Parser)]
#[command(name = "liq")]
#[command(about = "LIQUIDATION operator CLI")]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Debug, Subcommand)]
enum Command {
    /// Database commands.
    Db {
        #[command(subcommand)]
        command: DbCommand,
    },
    /// Replay commands.
    Replay {
        #[command(subcommand)]
        command: ReplayCommand,
    },
}

#[derive(Debug, Subcommand)]
enum DbCommand {
    /// Run embedded database migrations.
    Migrate {
        /// Postgres connection URL. Defaults to `DATABASE_URL`.
        #[arg(long, env = "DATABASE_URL")]
        database_url: String,
    },
    /// Validate schema-domain contract after migrations.
    CheckSchema {
        /// Postgres connection URL. Defaults to `DATABASE_URL`.
        #[arg(long, env = "DATABASE_URL")]
        database_url: String,
    },
}

#[derive(Debug, Subcommand)]
enum ReplayCommand {
    /// Validate replay inputs without executing strategy transitions.
    DryRun {
        /// Source id. Repeat for multiple sources.
        #[arg(long = "source")]
        source: Vec<String>,
        /// Inclusive start timestamp in milliseconds.
        #[arg(long)]
        start_unix_ms: i64,
        /// Exclusive end timestamp in milliseconds.
        #[arg(long)]
        end_unix_ms: i64,
    },
}

fn main() -> anyhow::Result<()> {
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
        .context("failed to build tokio runtime")?;

    runtime.block_on(run())
}

async fn run() -> anyhow::Result<()> {
    tracing_subscriber::fmt().with_env_filter("info").init();
    let cli = Cli::parse();

    match cli.command {
        Command::Db { command } => match command {
            DbCommand::Migrate { database_url } => {
                let pool = connect(&database_url).await?;
                migrations::run(&pool)
                    .await
                    .context("database migration failed")?;
                println!("migrations ok");
            }
            DbCommand::CheckSchema { database_url } => {
                let pool = connect(&database_url).await?;
                let violations = schema::assert_schema_contract(&pool)
                    .await
                    .context("schema contract check failed")?;
                if violations.is_empty() {
                    println!("schema ok");
                } else {
                    for violation in &violations {
                        eprintln!(
                            "{}.{}: {}",
                            violation.table, violation.column, violation.problem
                        );
                    }
                    anyhow::bail!("schema contract has {} violation(s)", violations.len());
                }
            }
        },
        Command::Replay {
            command:
                ReplayCommand::DryRun {
                    source,
                    start_unix_ms,
                    end_unix_ms,
                },
        } => {
            let request = DryRunRequest {
                sources: source,
                start_unix_ms,
                end_unix_ms,
            };
            validate_dry_run(&request).context("replay dry-run validation failed")?;
            info!("replay dry-run validation passed");
            println!("dry-run ok");
        }
    }

    Ok(())
}

async fn connect(database_url: &str) -> anyhow::Result<sqlx::PgPool> {
    PgPoolOptions::new()
        .max_connections(5)
        .connect(database_url)
        .await
        .context("failed to connect to database")
}
