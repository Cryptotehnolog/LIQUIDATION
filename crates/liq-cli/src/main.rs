//! LIQUIDATION operator CLI.

use anyhow::Context;
use clap::{Parser, Subcommand};
use liq_collector::{
    CollectorRunSettings, CollectorSettings, CollectorSource, SourceProbe, run_live_collector,
    run_live_probe,
};
use liq_recorder::{migrations, schema};
use liq_replay::{DryRunRequest, validate_dry_run};
use sqlx::postgres::PgPoolOptions;
use std::time::Duration;
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
    /// Live collector commands.
    Collector {
        #[command(subcommand)]
        command: CollectorCommand,
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

#[derive(Debug, Subcommand)]
enum CollectorCommand {
    /// Run a bounded live WebSocket probe and persist observed liquidation events.
    Probe {
        /// Postgres connection URL. Defaults to `DATABASE_URL`.
        #[arg(long, env = "DATABASE_URL")]
        database_url: String,
        /// Source id: bybit or binance.
        #[arg(long)]
        source: String,
        /// Exchange symbol, e.g. BTCUSDT.
        #[arg(long)]
        symbol: String,
        /// Stop after this many raw WebSocket messages.
        #[arg(long, default_value_t = 1)]
        max_messages: usize,
        /// Require at least this many raw WebSocket messages before timeout can be treated as success.
        #[arg(long, default_value_t = 0)]
        min_messages: usize,
        /// Bounded recorder channel capacity.
        #[arg(long, default_value_t = 128)]
        channel_capacity: usize,
        /// Per-message read timeout in seconds.
        #[arg(long, default_value_t = 30)]
        read_timeout_seconds: u64,
    },
    /// Run a long-running collector until Ctrl+C or configured run limits.
    Run {
        /// Postgres connection URL. Defaults to `DATABASE_URL`.
        #[arg(long, env = "DATABASE_URL")]
        database_url: String,
        /// Source id: bybit or binance.
        #[arg(long)]
        source: String,
        /// Exchange symbol, e.g. BTCUSDT.
        #[arg(long)]
        symbol: String,
        /// Bounded recorder channel capacity.
        #[arg(long, default_value_t = 1024)]
        channel_capacity: usize,
        /// Per-message read timeout in seconds.
        #[arg(long, default_value_t = 30)]
        read_timeout_seconds: u64,
        /// Raw/canonical insert batch size.
        #[arg(long, default_value_t = 256)]
        batch_size: usize,
        /// Flush partial batches after this many seconds.
        #[arg(long, default_value_t = 2)]
        batch_flush_interval_seconds: u64,
        /// Write collector health rows every this many seconds.
        #[arg(long, default_value_t = 30)]
        health_interval_seconds: u64,
        /// Optional message limit for bounded validation runs.
        #[arg(long)]
        max_messages: Option<usize>,
        /// Optional runtime limit in seconds for bounded validation runs.
        #[arg(long)]
        max_runtime_seconds: Option<u64>,
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
        Command::Db { command } => handle_db_command(command).await?,
        Command::Replay { command } => handle_replay_command(command)?,
        Command::Collector { command } => handle_collector_command(command).await?,
    }

    Ok(())
}

async fn handle_db_command(command: DbCommand) -> anyhow::Result<()> {
    match command {
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
    }
    Ok(())
}

fn handle_replay_command(command: ReplayCommand) -> anyhow::Result<()> {
    match command {
        ReplayCommand::DryRun {
            source,
            start_unix_ms,
            end_unix_ms,
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

async fn handle_collector_command(command: CollectorCommand) -> anyhow::Result<()> {
    match command {
        CollectorCommand::Probe {
            database_url,
            source,
            symbol,
            max_messages,
            min_messages,
            channel_capacity,
            read_timeout_seconds,
        } => {
            run_collector_probe(
                database_url,
                source,
                symbol,
                max_messages,
                min_messages,
                channel_capacity,
                read_timeout_seconds,
            )
            .await?;
        }
        CollectorCommand::Run {
            database_url,
            source,
            symbol,
            channel_capacity,
            read_timeout_seconds,
            batch_size,
            batch_flush_interval_seconds,
            health_interval_seconds,
            max_messages,
            max_runtime_seconds,
        } => {
            run_collector_service(CollectorRunArgs {
                database_url,
                source,
                symbol,
                channel_capacity,
                read_timeout_seconds,
                batch_size,
                batch_flush_interval_seconds,
                health_interval_seconds,
                max_messages,
                max_runtime_seconds,
            })
            .await?;
        }
    }
    Ok(())
}

async fn run_collector_probe(
    database_url: String,
    source: String,
    symbol: String,
    max_messages: usize,
    min_messages: usize,
    channel_capacity: usize,
    read_timeout_seconds: u64,
) -> anyhow::Result<()> {
    let source = parse_collector_source(&source)?;
    let pool = connect(&database_url).await?;
    let settings = CollectorSettings {
        channel_capacity,
        max_messages,
        min_messages,
        read_timeout: Duration::from_secs(read_timeout_seconds),
        ..CollectorSettings::default()
    };
    let stats = run_live_probe(pool, SourceProbe::new(source, symbol), settings)
        .await
        .context("collector probe failed")?;
    println!(
        "collector probe ok: received_messages={} normalized_events={} raw_inserted={} canonical_inserted={} reconnects={}",
        stats.received_messages,
        stats.normalized_events,
        stats.raw_inserted,
        stats.canonical_inserted,
        stats.reconnects
    );
    Ok(())
}

struct CollectorRunArgs {
    database_url: String,
    source: String,
    symbol: String,
    channel_capacity: usize,
    read_timeout_seconds: u64,
    batch_size: usize,
    batch_flush_interval_seconds: u64,
    health_interval_seconds: u64,
    max_messages: Option<usize>,
    max_runtime_seconds: Option<u64>,
}

async fn run_collector_service(args: CollectorRunArgs) -> anyhow::Result<()> {
    let source = parse_collector_source(&args.source)?;
    let pool = connect(&args.database_url).await?;
    let settings = CollectorRunSettings {
        channel_capacity: args.channel_capacity,
        read_timeout: Duration::from_secs(args.read_timeout_seconds),
        batch_size: args.batch_size,
        batch_flush_interval: Duration::from_secs(args.batch_flush_interval_seconds),
        health_interval: Duration::from_secs(args.health_interval_seconds),
        max_messages: args.max_messages,
        max_runtime: args.max_runtime_seconds.map(Duration::from_secs),
        ..CollectorRunSettings::default()
    };
    let (shutdown_sender, shutdown_receiver) = tokio::sync::watch::channel(false);
    tokio::spawn(async move {
        if tokio::signal::ctrl_c().await.is_ok() {
            let _ = shutdown_sender.send(true);
        }
    });

    let stats = run_live_collector(
        pool,
        SourceProbe::new(source, args.symbol),
        settings,
        shutdown_receiver,
    )
    .await
    .context("collector run failed")?;
    println!(
        "collector run stopped: received_messages={} normalized_events={} raw_inserted={} canonical_inserted={} reconnects={}",
        stats.received_messages,
        stats.normalized_events,
        stats.raw_inserted,
        stats.canonical_inserted,
        stats.reconnects
    );
    Ok(())
}

fn parse_collector_source(source: &str) -> anyhow::Result<CollectorSource> {
    CollectorSource::parse(source)
        .with_context(|| format!("unsupported collector source: {source}"))
}

async fn connect(database_url: &str) -> anyhow::Result<sqlx::PgPool> {
    PgPoolOptions::new()
        .max_connections(5)
        .connect(database_url)
        .await
        .context("failed to connect to database")
}
