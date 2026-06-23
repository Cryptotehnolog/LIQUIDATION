//! LIQUIDATION operator CLI.

mod dashboard;

use anyhow::Context;
use clap::{Parser, Subcommand};
use dashboard::DashboardArgs;
use liq_collector::{
    CollectorRunSettings, CollectorSettings, CollectorSource, SourceProbe, run_live_collector,
    run_live_collectors, run_live_probe,
};
use liq_connectors::okx::OkxInstrumentCache;
use liq_recorder::{migrations, repository, schema};
use liq_replay::{DryRunRequest, StrategyReadinessReport, validate_dry_run};
use sqlx::postgres::PgPoolOptions;
use std::path::PathBuf;
use std::time::Duration;
use time::{OffsetDateTime, format_description::well_known::Rfc3339};
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
    /// Strategy readiness and safety commands.
    Strategy {
        #[command(subcommand)]
        command: StrategyCommand,
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
        /// Source id: bybit, binance, or okx.
        #[arg(long)]
        source: String,
        /// Exchange symbol, e.g. BTCUSDT.
        #[arg(long)]
        symbol: String,
        /// Optional OKX instruments response JSON used to enable canonical OKX normalization.
        #[arg(long)]
        okx_instruments_path: Option<PathBuf>,
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
        /// Source id: bybit, binance, or okx. Repeat for multi-source runs.
        #[arg(long = "source", required = true)]
        source: Vec<String>,
        /// Exchange symbol, e.g. BTCUSDT.
        #[arg(long)]
        symbol: String,
        /// Optional OKX instruments response JSON used to enable canonical OKX normalization.
        #[arg(long)]
        okx_instruments_path: Option<PathBuf>,
        /// Bounded recorder channel capacity.
        #[arg(long, default_value_t = 1024)]
        channel_capacity: usize,
        /// Per-message read timeout in seconds.
        #[arg(long, default_value_t = 30)]
        read_timeout_seconds: u64,
        /// Maximum time to wait when recorder channel is full.
        #[arg(long, default_value_t = 5)]
        channel_send_timeout_seconds: u64,
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
    /// Print recent collector health rows.
    Health {
        /// Postgres connection URL. Defaults to `DATABASE_URL`.
        #[arg(long, env = "DATABASE_URL")]
        database_url: String,
        /// Optional source id: bybit, binance, or okx.
        #[arg(long)]
        source: Option<String>,
        /// Maximum rows to print.
        #[arg(long, default_value_t = 20)]
        limit: i64,
    },
    /// Print compact collector status rows.
    Status {
        /// Postgres connection URL. Defaults to `DATABASE_URL`.
        #[arg(long, env = "DATABASE_URL")]
        database_url: String,
        /// Optional source id: bybit, binance, or okx.
        #[arg(long)]
        source: Option<String>,
        /// Maximum rows to print in table mode. Ignored with `--json`.
        #[arg(long, default_value_t = 10)]
        limit: i64,
        /// Emit dashboard-ready JSON metrics instead of table rows.
        #[arg(long)]
        json: bool,
        /// Metrics aggregation window in minutes for JSON output.
        #[arg(long, default_value_t = 60)]
        window_minutes: i64,
    },
    /// Print source coverage overlap report for one primary and one diagnostic source.
    OverlapReport {
        /// Postgres connection URL. Defaults to `DATABASE_URL`.
        #[arg(long, env = "DATABASE_URL")]
        database_url: String,
        /// Primary source used for strategy signals.
        #[arg(long, default_value = "bybit")]
        primary_source: String,
        /// Diagnostic source compared against the primary source.
        #[arg(long, default_value = "okx")]
        diagnostic_source: String,
        /// Metrics aggregation window in minutes.
        #[arg(long, default_value_t = 60)]
        window_minutes: i64,
        /// Bucket size in seconds.
        #[arg(long, default_value_t = 60)]
        bucket_seconds: i64,
    },
    /// Serve a read-only collector dashboard backed by the status JSON contract.
    Dashboard {
        /// Bind address for the local dashboard server.
        #[arg(long, default_value = "127.0.0.1:18080")]
        bind: String,
        /// Postgres connection URL. Defaults to `DATABASE_URL`.
        #[arg(long, env = "DATABASE_URL")]
        database_url: Option<String>,
        /// Metrics aggregation window in minutes.
        #[arg(long, default_value_t = 60)]
        window_minutes: i64,
        /// Browser polling interval in seconds.
        #[arg(long, default_value_t = 5)]
        poll_seconds: u64,
        /// Development-only fixture path used by smoke tests.
        #[arg(long)]
        fixture_path: Option<PathBuf>,
    },
}

#[derive(Debug, Subcommand)]
enum StrategyCommand {
    /// Print fail-closed strategy readiness report.
    Readiness {
        /// Emit machine-readable JSON.
        #[arg(long)]
        json: bool,
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
        Command::Strategy { command } => handle_strategy_command(&command)?,
    }

    Ok(())
}

fn handle_strategy_command(command: &StrategyCommand) -> anyhow::Result<()> {
    match command {
        StrategyCommand::Readiness { json } => {
            let report = StrategyReadinessReport::current_foundation();
            if *json {
                println!(
                    "{}",
                    serde_json::to_string_pretty(&report)
                        .context("failed to serialize strategy readiness report")?
                );
            } else {
                println!("ready_for_strategy: {}", report.ready_for_strategy);
                println!("capabilities:");
                for item in &report.capabilities {
                    println!("- {}: {} ({})", item.id, item.status, item.note);
                }
                println!("blockers:");
                for item in &report.blockers {
                    println!("- {}: {} ({})", item.id, item.status, item.note);
                }
            }
        }
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
            okx_instruments_path,
            max_messages,
            min_messages,
            channel_capacity,
            read_timeout_seconds,
        } => {
            run_collector_probe(CollectorProbeArgs {
                database_url,
                source,
                symbol,
                okx_instruments_path,
                max_messages,
                min_messages,
                channel_capacity,
                read_timeout_seconds,
            })
            .await?;
        }
        CollectorCommand::Run {
            database_url,
            source,
            symbol,
            okx_instruments_path,
            channel_capacity,
            read_timeout_seconds,
            channel_send_timeout_seconds,
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
                okx_instruments_path,
                channel_capacity,
                read_timeout_seconds,
                channel_send_timeout_seconds,
                batch_size,
                batch_flush_interval_seconds,
                health_interval_seconds,
                max_messages,
                max_runtime_seconds,
            })
            .await?;
        }
        command => handle_collector_inspection_command(command).await?,
    }
    Ok(())
}

async fn handle_collector_inspection_command(command: CollectorCommand) -> anyhow::Result<()> {
    match command {
        CollectorCommand::Health {
            database_url,
            source,
            limit,
        }
        | CollectorCommand::Status {
            database_url,
            source,
            limit,
            json: false,
            window_minutes: _,
        } => {
            print_collector_health(database_url, source, limit).await?;
        }
        CollectorCommand::Status {
            database_url,
            source,
            limit,
            json: true,
            window_minutes,
        } => {
            print_collector_status_json(database_url, source, limit, window_minutes).await?;
        }
        CollectorCommand::OverlapReport {
            database_url,
            primary_source,
            diagnostic_source,
            window_minutes,
            bucket_seconds,
        } => {
            print_collector_overlap_report(
                database_url,
                primary_source,
                diagnostic_source,
                window_minutes,
                bucket_seconds,
            )
            .await?;
        }
        CollectorCommand::Dashboard {
            bind,
            database_url,
            window_minutes,
            poll_seconds,
            fixture_path,
        } => {
            dashboard::serve_dashboard(DashboardArgs {
                bind,
                database_url,
                window_minutes,
                poll_seconds,
                fixture_path,
            })
            .await?;
        }
        CollectorCommand::Probe { .. } | CollectorCommand::Run { .. } => {
            anyhow::bail!("collector runtime command reached inspection handler");
        }
    }
    Ok(())
}

struct CollectorProbeArgs {
    database_url: String,
    source: String,
    symbol: String,
    okx_instruments_path: Option<PathBuf>,
    max_messages: usize,
    min_messages: usize,
    channel_capacity: usize,
    read_timeout_seconds: u64,
}

async fn run_collector_probe(args: CollectorProbeArgs) -> anyhow::Result<()> {
    let source = parse_collector_source(&args.source)?;
    let okx_instrument_cache = load_okx_instrument_cache(args.okx_instruments_path.as_ref())?;
    let pool = connect(&args.database_url).await?;
    let settings = CollectorSettings {
        channel_capacity: args.channel_capacity,
        max_messages: args.max_messages,
        min_messages: args.min_messages,
        read_timeout: Duration::from_secs(args.read_timeout_seconds),
        ..CollectorSettings::default()
    };
    let stats = run_live_probe(
        pool,
        source_probe(source, args.symbol, okx_instrument_cache.as_ref()),
        settings,
    )
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
    source: Vec<String>,
    symbol: String,
    okx_instruments_path: Option<PathBuf>,
    channel_capacity: usize,
    read_timeout_seconds: u64,
    channel_send_timeout_seconds: u64,
    batch_size: usize,
    batch_flush_interval_seconds: u64,
    health_interval_seconds: u64,
    max_messages: Option<usize>,
    max_runtime_seconds: Option<u64>,
}

async fn run_collector_service(args: CollectorRunArgs) -> anyhow::Result<()> {
    let sources = parse_collector_sources(&args.source)?;
    let okx_instrument_cache = load_okx_instrument_cache(args.okx_instruments_path.as_ref())?;
    let pool = connect(&args.database_url).await?;
    let settings = CollectorRunSettings {
        channel_capacity: args.channel_capacity,
        read_timeout: Duration::from_secs(args.read_timeout_seconds),
        channel_send_timeout: Duration::from_secs(args.channel_send_timeout_seconds),
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

    let probes = sources
        .into_iter()
        .map(|source| source_probe(source, args.symbol.clone(), okx_instrument_cache.as_ref()))
        .collect::<Vec<_>>();
    let reports = if probes.len() == 1 {
        let probe = probes
            .into_iter()
            .next()
            .context("collector source list unexpectedly empty")?;
        let source = probe.source().domain_source().as_str().to_owned();
        let symbol = probe.symbol().to_owned();
        let stats = run_live_collector(pool, probe, settings, shutdown_receiver)
            .await
            .context("collector run failed")?;
        vec![liq_collector::CollectorRunReport {
            source,
            symbol,
            status: "ok".to_owned(),
            stats,
            error: None,
        }]
    } else {
        run_live_collectors(pool, probes, settings, shutdown_receiver)
            .await
            .context("multi-source collector run failed")?
    };

    for report in &reports {
        println!(
            "collector run stopped: source={} symbol={} status={} received_messages={} normalized_events={} raw_inserted={} canonical_inserted={} reconnects={}{}",
            report.source,
            report.symbol,
            report.status,
            report.stats.received_messages,
            report.stats.normalized_events,
            report.stats.raw_inserted,
            report.stats.canonical_inserted,
            report.stats.reconnects,
            report
                .error
                .as_ref()
                .map_or_else(String::new, |error| format!(" error={error}"))
        );
    }
    Ok(())
}

fn parse_collector_source(source: &str) -> anyhow::Result<CollectorSource> {
    CollectorSource::parse(source)
        .with_context(|| format!("unsupported collector source: {source}"))
}

fn parse_collector_sources(sources: &[String]) -> anyhow::Result<Vec<CollectorSource>> {
    if sources.is_empty() {
        anyhow::bail!("at least one collector source is required");
    }
    sources
        .iter()
        .map(|source| parse_collector_source(source))
        .collect()
}

fn source_probe(
    source: CollectorSource,
    symbol: impl Into<String>,
    okx_instrument_cache: Option<&OkxInstrumentCache>,
) -> SourceProbe {
    let probe = SourceProbe::new(source, symbol);
    if source == CollectorSource::Okx
        && let Some(cache) = okx_instrument_cache
    {
        return probe.with_okx_instrument_cache(cache.clone());
    }

    probe
}

fn load_okx_instrument_cache(path: Option<&PathBuf>) -> anyhow::Result<Option<OkxInstrumentCache>> {
    let Some(path) = path else {
        return Ok(None);
    };
    let payload = std::fs::read_to_string(path)
        .with_context(|| format!("failed to read OKX instruments file: {}", path.display()))?;
    let cache = OkxInstrumentCache::from_instruments_response(&payload)
        .context("failed to parse OKX instruments metadata")?;
    Ok(Some(cache))
}

async fn print_collector_health(
    database_url: String,
    source: Option<String>,
    limit: i64,
) -> anyhow::Result<()> {
    if let Some(source) = source.as_deref() {
        parse_collector_source(source)?;
    }
    let pool = connect(&database_url).await?;
    let rows = repository::list_collector_health(&pool, source.as_deref(), limit)
        .await
        .context("failed to read collector health")?;
    println!(
        "checked_at\tsource\tsymbol\tstatus\tmessages\tevents\traw\tcanonical\treconnects_5m\tlast_latency_ms\tmax_latency_ms"
    );
    for row in rows {
        println!(
            "{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}",
            format_timestamp(row.checked_at),
            row.source,
            row.symbol,
            row.status,
            row.messages_received,
            row.normalized_events,
            row.raw_inserted,
            row.canonical_inserted,
            row.reconnects_5m,
            row.last_latency_ms
                .map_or_else(|| "-".to_owned(), |value| value.to_string()),
            row.max_latency_ms
        );
    }
    Ok(())
}

async fn print_collector_status_json(
    database_url: String,
    source: Option<String>,
    _limit: i64,
    window_minutes: i64,
) -> anyhow::Result<()> {
    if let Some(source) = source.as_deref() {
        parse_collector_source(source)?;
    }
    let pool = connect(&database_url).await?;
    let mut metrics = repository::collector_dashboard_metrics(
        &pool,
        repository::MetricsWindow::minutes(window_minutes.max(1)),
    )
    .await
    .context("failed to read collector dashboard metrics")?;
    if let Some(source) = source {
        metrics.sources.retain(|row| row.source == source);
    }
    println!(
        "{}",
        serde_json::to_string_pretty(&metrics).context("failed to serialize collector metrics")?
    );
    Ok(())
}

async fn print_collector_overlap_report(
    database_url: String,
    primary_source: String,
    diagnostic_source: String,
    window_minutes: i64,
    bucket_seconds: i64,
) -> anyhow::Result<()> {
    parse_collector_source(&primary_source)?;
    parse_collector_source(&diagnostic_source)?;
    if primary_source == diagnostic_source {
        anyhow::bail!("primary-source and diagnostic-source must be different");
    }

    let pool = connect(&database_url).await?;
    let report = repository::source_overlap_report(
        &pool,
        &primary_source,
        &diagnostic_source,
        repository::MetricsWindow::minutes(window_minutes.max(1)),
        bucket_seconds.max(1),
    )
    .await
    .context("failed to read source overlap report")?;
    println!(
        "{}",
        serde_json::to_string_pretty(&report).context("failed to serialize overlap report")?
    );
    Ok(())
}

fn format_timestamp(timestamp: OffsetDateTime) -> String {
    timestamp
        .format(&Rfc3339)
        .unwrap_or_else(|_| timestamp.unix_timestamp().to_string())
}

async fn connect(database_url: &str) -> anyhow::Result<sqlx::PgPool> {
    PgPoolOptions::new()
        .max_connections(5)
        .connect(database_url)
        .await
        .context("failed to connect to database")
}
