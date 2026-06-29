//! LIQUIDATION operator CLI.

mod dashboard;
mod polymarket_markets;

use anyhow::Context;
use clap::{Args, Parser, Subcommand};
use dashboard::DashboardArgs;
use liq_collector::{
    CollectorRunSettings, CollectorSettings, CollectorSource, SourceProbe, run_live_collector,
    run_live_collectors, run_live_probe,
};
use liq_connectors::okx::OkxInstrumentCache;
use liq_recorder::{
    migrations,
    records::{PaperReplayDataRecord, PolymarketMarketRecord},
    repository, schema,
};
use liq_replay::{
    BaselineMarket, BaselineStrategyConfig, DryRunRequest, FeeSchedule, FillModel,
    MarketDataReadiness, PaperReplayDataCounts, PaperReplayInput, PaperReplayPreflightInput,
    PaperReplayPreflightReport, PaperReplayReport, StrategyReadinessExplanation,
    StrategyReadinessReport, paper_replay_preflight, run_paper_replay, validate_dry_run,
};
use polymarket_markets::{
    PolymarketMarketFetchFilter, PolymarketMarketFetchRequest, fetch_polymarket_markets,
    selected_markets_from_payload,
};
use rust_decimal::Decimal;
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
    /// Run deterministic paper replay over stored events.
    Run(Box<ReplayRunOptions>),
    /// Check whether a stored window is good enough for a real paper replay.
    Preflight(Box<ReplayRunOptions>),
    /// Manage Polymarket market metadata used by replay auto mode.
    Market {
        #[command(subcommand)]
        command: ReplayMarketCommand,
    },
}

#[derive(Debug, Args)]
struct ReplayRunOptions {
    /// Strategy id. MVP supports `baseline`.
    #[arg(long, default_value = "baseline")]
    strategy: String,
    /// Replay parameter profile. Supported: `baseline`, `research-wide-threshold`.
    #[arg(long, default_value = "baseline")]
    replay_profile: String,
    /// Postgres connection URL. Defaults to `DATABASE_URL`.
    #[arg(long, env = "DATABASE_URL")]
    database_url: String,
    /// Active Polymarket market id or slug. Required unless `--latest-polymarket-market` is set.
    #[arg(long)]
    market_id: Option<String>,
    /// Polymarket UP outcome token id. Required unless `--latest-polymarket-market` is set.
    #[arg(long)]
    up_token_id: Option<String>,
    /// Polymarket DOWN outcome token id. Required unless `--latest-polymarket-market` is set.
    #[arg(long)]
    down_token_id: Option<String>,
    /// Inclusive replay start timestamp in milliseconds. Required unless `--latest-polymarket-market` is set.
    #[arg(long)]
    start_unix_ms: Option<i64>,
    /// Exclusive replay end timestamp in milliseconds. Required unless `--latest-polymarket-market` is set.
    #[arg(long)]
    end_unix_ms: Option<i64>,
    /// Use the latest known Polymarket market metadata from durable storage.
    #[arg(long)]
    latest_polymarket_market: bool,
    /// Base asset used when resolving `--latest-polymarket-market`.
    #[arg(long, default_value = "BTC")]
    base_asset: String,
    /// Market type used when resolving `--latest-polymarket-market`.
    #[arg(long, default_value = "btc_5m")]
    market_type: String,
    /// Polymarket entry fill model: `trade_cross` or `book_touch`.
    #[arg(long, default_value = "trade_cross")]
    fill_model: String,
    /// Minimum dominant liquidation notional for a signal.
    #[arg(long)]
    liquidation_threshold_min_usd: Option<Decimal>,
    /// Maximum dominant liquidation notional; above this the wave is considered missed.
    #[arg(long)]
    liquidation_threshold_max_usd: Option<Decimal>,
    /// Pullback percentage applied to the observed Polymarket best ask.
    #[arg(long)]
    pullback_pct: Option<Decimal>,
    /// Paper USD allocated to the Polymarket leg.
    #[arg(long)]
    polymarket_usd_per_position: Option<Decimal>,
    /// Cancel or avoid unfilled orders this many seconds before market expiry.
    #[arg(long)]
    order_cancel_window_seconds: Option<i64>,
    /// Paper hedge notional in USD for each filled Polymarket signal.
    #[arg(long, default_value = "15")]
    hedge_notional_usd: Decimal,
    /// Conservative hedge slippage penalty per hedge fill, in USD.
    #[arg(long, default_value = "0")]
    hedge_slippage_usd: Decimal,
    /// Funding duration charged per hedge fill.
    #[arg(long, default_value = "0")]
    funding_hours: Decimal,
    /// Polymarket maker fee in basis points.
    #[arg(long, default_value = "0")]
    polymarket_maker_bps: Decimal,
    /// Polymarket taker fee in basis points.
    #[arg(long, default_value = "0")]
    polymarket_taker_bps: Decimal,
    /// Hyperliquid maker fee in basis points.
    #[arg(long, default_value = "0")]
    hyperliquid_maker_bps: Decimal,
    /// Hyperliquid taker fee in basis points.
    #[arg(long, default_value = "0")]
    hyperliquid_taker_bps: Decimal,
    /// Hyperliquid funding or holding cost in basis points per hour.
    #[arg(long, default_value = "0")]
    hyperliquid_funding_bps_per_hour: Decimal,
    /// Emit machine-readable JSON.
    #[arg(long)]
    json: bool,
    /// Optional path to write the JSON replay report artifact.
    #[arg(long)]
    artifact_path: Option<PathBuf>,
    /// Maximum allowed age after market end for real replay preflight.
    #[arg(long, default_value_t = 15)]
    market_stale_after_minutes: i64,
}

#[derive(Debug, Subcommand)]
enum ReplayMarketCommand {
    /// Upsert one Polymarket market metadata row.
    Upsert(Box<ReplayMarketUpsertOptions>),
    /// Fetch BTC 5-minute market metadata from Polymarket Gamma API.
    Fetch(Box<ReplayMarketFetchOptions>),
    /// List recent Polymarket markets.
    List {
        /// Postgres connection URL. Defaults to `DATABASE_URL`.
        #[arg(long, env = "DATABASE_URL")]
        database_url: String,
        /// Base asset.
        #[arg(long, default_value = "BTC")]
        base_asset: String,
        /// Market type.
        #[arg(long, default_value = "btc_5m")]
        market_type: String,
        /// Maximum rows to print.
        #[arg(long, default_value_t = 10)]
        limit: i64,
        /// Emit machine-readable JSON.
        #[arg(long)]
        json: bool,
    },
}

#[derive(Debug, Args)]
struct ReplayMarketUpsertOptions {
    /// Postgres connection URL. Defaults to `DATABASE_URL`.
    #[arg(long, env = "DATABASE_URL")]
    database_url: String,
    /// Polymarket market id.
    #[arg(long)]
    market_id: String,
    /// Optional market slug.
    #[arg(long)]
    slug: Option<String>,
    /// Optional market title/question.
    #[arg(long)]
    title: Option<String>,
    /// Base asset.
    #[arg(long, default_value = "BTC")]
    base_asset: String,
    /// Market type.
    #[arg(long, default_value = "btc_5m")]
    market_type: String,
    /// Polymarket UP outcome token id.
    #[arg(long)]
    up_token_id: String,
    /// Polymarket DOWN outcome token id.
    #[arg(long)]
    down_token_id: String,
    /// Inclusive market start timestamp in milliseconds.
    #[arg(long)]
    start_unix_ms: i64,
    /// Exclusive market end timestamp in milliseconds.
    #[arg(long)]
    end_unix_ms: i64,
    /// Market status.
    #[arg(long, default_value = "open")]
    status: String,
    /// Metadata source.
    #[arg(long, default_value = "manual")]
    source: String,
}

#[derive(Debug, Args)]
struct ReplayMarketFetchOptions {
    /// Postgres connection URL. Required when `--apply` is set. Defaults to `DATABASE_URL`.
    #[arg(long, env = "DATABASE_URL")]
    database_url: Option<String>,
    /// Polymarket Gamma markets endpoint. Query parameters are preserved.
    #[arg(long, default_value = "https://gamma-api.polymarket.com/markets")]
    endpoint_url: String,
    /// Read Gamma payload from a local fixture instead of the network.
    #[arg(long)]
    fixture_path: Option<PathBuf>,
    /// Base asset.
    #[arg(long, default_value = "BTC")]
    base_asset: String,
    /// Market type.
    #[arg(long, default_value = "btc_5m")]
    market_type: String,
    /// Required text fragment in question or slug. Repeat for multiple terms.
    #[arg(long = "match-term")]
    match_terms: Vec<String>,
    /// Required market window length in seconds.
    #[arg(long, default_value_t = 300)]
    window_seconds: i64,
    /// Gamma page size.
    #[arg(long, default_value_t = 100)]
    page_limit: u16,
    /// Maximum Gamma pages to scan.
    #[arg(long, default_value_t = 20)]
    max_pages: u16,
    /// Upsert selected metadata into `TimescaleDB`. Without this flag the command is dry-run only.
    #[arg(long)]
    apply: bool,
    /// Keep all matching markets instead of only the latest by start timestamp.
    #[arg(long)]
    all_matches: bool,
    /// Optional JSON artifact path for selected metadata.
    #[arg(long)]
    output_path: Option<PathBuf>,
    /// Emit machine-readable JSON.
    #[arg(long)]
    json: bool,
}

#[derive(Debug, Subcommand)]
enum CollectorCommand {
    /// Run a bounded live WebSocket probe and persist observed liquidation events.
    Probe {
        /// Postgres connection URL. Defaults to `DATABASE_URL`.
        #[arg(long, env = "DATABASE_URL")]
        database_url: String,
        /// Source id: bybit, binance, okx, bitget, polymarket, or hyperliquid.
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
        /// Source id: bybit, binance, okx, bitget, polymarket, or hyperliquid. Repeat for multi-source runs.
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
        /// Optional source id: bybit, binance, okx, bitget, polymarket, or hyperliquid.
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
        /// Optional source id: bybit, binance, okx, bitget, polymarket, or hyperliquid.
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
    /// Print multi-source diagnostic usefulness report.
    UsefulnessReport {
        /// Postgres connection URL. Defaults to `DATABASE_URL`.
        #[arg(long, env = "DATABASE_URL")]
        database_url: String,
        /// Primary source used as the current strategy baseline.
        #[arg(long, default_value = "bybit")]
        primary_source: String,
        /// Metrics aggregation window in minutes.
        #[arg(long, default_value_t = 60)]
        window_minutes: i64,
        /// Bucket size in seconds for additive coverage counts.
        #[arg(long, default_value_t = 60)]
        bucket_seconds: i64,
        /// Mark health rows stale when payload age exceeds this many seconds.
        #[arg(long, default_value_t = 120)]
        stale_after_seconds: i64,
        /// Emit machine-readable JSON.
        #[arg(long)]
        json: bool,
        /// Optional path to write JSON report artifact.
        #[arg(long)]
        artifact_path: Option<PathBuf>,
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
        /// Optional latest replay JSON artifact shown by the read-only dashboard.
        #[arg(long)]
        replay_artifact_path: Option<PathBuf>,
        /// Optional Polymarket market metadata JSON artifact shown by the dashboard.
        #[arg(long)]
        polymarket_market_artifact_path: Option<PathBuf>,
        /// Mark Polymarket metadata stale when latest market end is older than this many minutes.
        #[arg(long, default_value_t = 15)]
        polymarket_market_stale_after_minutes: i64,
    },
}

#[derive(Debug, Subcommand)]
enum StrategyCommand {
    /// Print fail-closed strategy readiness report.
    Readiness {
        /// Optional nested readiness command.
        #[command(subcommand)]
        command: Option<ReadinessCommand>,
        /// Optional Postgres connection URL. Defaults to `DATABASE_URL` when set.
        #[arg(long, env = "DATABASE_URL")]
        database_url: Option<String>,
        /// Market-data evidence window in minutes when a database is configured.
        #[arg(long, default_value_t = 60)]
        window_minutes: i64,
        /// Emit machine-readable JSON.
        #[arg(long)]
        json: bool,
    },
}

#[derive(Debug, Subcommand)]
enum ReadinessCommand {
    /// Explain readiness conditions with observed counts and pass/fail state.
    Explain {
        /// Optional Postgres connection URL. Defaults to `DATABASE_URL` when set.
        #[arg(long, env = "DATABASE_URL")]
        database_url: Option<String>,
        /// Market-data evidence window in minutes when a database is configured.
        #[arg(long, default_value_t = 60)]
        window_minutes: i64,
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
        Command::Replay { command } => handle_replay_command(command).await?,
        Command::Collector { command } => handle_collector_command(command).await?,
        Command::Strategy { command } => handle_strategy_command(&command).await?,
    }

    Ok(())
}

async fn handle_strategy_command(command: &StrategyCommand) -> anyhow::Result<()> {
    match command {
        StrategyCommand::Readiness {
            command,
            database_url,
            window_minutes,
            json,
        } => {
            if let Some(ReadinessCommand::Explain {
                database_url,
                window_minutes,
                json,
            }) = command
            {
                let explanation =
                    strategy_readiness_explanation(database_url.as_deref(), *window_minutes)
                        .await?;
                print_strategy_readiness_explanation(&explanation, *json)?;
            } else {
                let report =
                    strategy_readiness_report(database_url.as_deref(), *window_minutes).await?;
                print_strategy_readiness_report(&report, *json)?;
            }
        }
    }
    Ok(())
}

async fn strategy_readiness_report(
    database_url: Option<&str>,
    window_minutes: i64,
) -> anyhow::Result<StrategyReadinessReport> {
    let Some(database_url) = database_url else {
        return Ok(StrategyReadinessReport::current_foundation());
    };
    let readiness = read_market_data_readiness(database_url, window_minutes).await?;
    Ok(StrategyReadinessReport::from_market_data(readiness))
}

async fn strategy_readiness_explanation(
    database_url: Option<&str>,
    window_minutes: i64,
) -> anyhow::Result<StrategyReadinessExplanation> {
    let Some(database_url) = database_url else {
        return Ok(StrategyReadinessExplanation::current_foundation());
    };
    let readiness = read_market_data_readiness(database_url, window_minutes).await?;
    Ok(StrategyReadinessExplanation::from_market_data(readiness))
}

async fn read_market_data_readiness(
    database_url: &str,
    window_minutes: i64,
) -> anyhow::Result<MarketDataReadiness> {
    let pool = connect(database_url).await?;
    let readiness = repository::market_data_readiness(
        &pool,
        repository::MetricsWindow::minutes(window_minutes.max(1)),
    )
    .await
    .context("failed to read market-data readiness")?;
    Ok(MarketDataReadiness {
        polymarket_quotes: readiness.polymarket_quotes,
        polymarket_trades: readiness.polymarket_trades,
        hyperliquid_quotes: readiness.hyperliquid_quotes,
        hyperliquid_trades: readiness.hyperliquid_trades,
    })
}

fn print_strategy_readiness_report(
    report: &StrategyReadinessReport,
    json: bool,
) -> anyhow::Result<()> {
    if json {
        println!(
            "{}",
            serde_json::to_string_pretty(report)
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
    Ok(())
}

fn print_strategy_readiness_explanation(
    explanation: &StrategyReadinessExplanation,
    json: bool,
) -> anyhow::Result<()> {
    if json {
        println!(
            "{}",
            serde_json::to_string_pretty(explanation)
                .context("failed to serialize strategy readiness explanation")?
        );
    } else {
        print_strategy_readiness_report(&explanation.report, false)?;
        println!("conditions:");
        for condition in &explanation.conditions {
            println!(
                "- {}: passed={} required='{}' observed='{}'",
                condition.id, condition.passed, condition.required, condition.observed
            );
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

async fn handle_replay_command(command: ReplayCommand) -> anyhow::Result<()> {
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
        ReplayCommand::Run(options) => {
            handle_replay_run(*options).await?;
        }
        ReplayCommand::Preflight(options) => {
            handle_replay_preflight(*options).await?;
        }
        ReplayCommand::Market { command } => match command {
            ReplayMarketCommand::Upsert(options) => {
                upsert_polymarket_market_from_cli(*options).await?;
            }
            ReplayMarketCommand::Fetch(options) => {
                fetch_polymarket_markets_from_cli(*options).await?;
            }
            ReplayMarketCommand::List {
                database_url,
                base_asset,
                market_type,
                limit,
                json,
            } => {
                list_polymarket_markets_from_cli(
                    &database_url,
                    &base_asset,
                    &market_type,
                    limit,
                    json,
                )
                .await?;
            }
        },
    }
    Ok(())
}

async fn handle_replay_run(options: ReplayRunOptions) -> anyhow::Result<()> {
    let json = options.json;
    let artifact_path = options.artifact_path.clone();
    let report = run_replay_from_database(replay_options_to_args(options)?).await?;
    if let Some(artifact_path) = artifact_path {
        write_replay_artifact(&artifact_path, &report).await?;
    }
    print_replay_report(&report, json)
}

async fn handle_replay_preflight(options: ReplayRunOptions) -> anyhow::Result<()> {
    let json = options.json;
    let report = preflight_replay_from_database(replay_options_to_args(options)?).await?;
    let ready_for_replay = report.ready_for_replay;
    print_replay_preflight_report(&report, json)?;
    if !ready_for_replay {
        anyhow::bail!(
            "paper replay preflight failed: {} blocker(s)",
            report.blockers.len()
        );
    }
    Ok(())
}

fn replay_options_to_args(options: ReplayRunOptions) -> anyhow::Result<ReplayRunArgs> {
    let strategy_config = resolve_baseline_strategy_config(&options)?;
    Ok(ReplayRunArgs {
        strategy: options.strategy,
        database_url: options.database_url,
        market_id: options.market_id,
        up_token_id: options.up_token_id,
        down_token_id: options.down_token_id,
        start_unix_ms: options.start_unix_ms,
        end_unix_ms: options.end_unix_ms,
        fill_model: options.fill_model,
        strategy_config,
        hedge_notional_usd: options.hedge_notional_usd,
        hedge_slippage_usd: options.hedge_slippage_usd,
        funding_hours: options.funding_hours,
        polymarket_maker_bps: options.polymarket_maker_bps,
        polymarket_taker_bps: options.polymarket_taker_bps,
        hyperliquid_maker_bps: options.hyperliquid_maker_bps,
        hyperliquid_taker_bps: options.hyperliquid_taker_bps,
        hyperliquid_funding_bps_per_hour: options.hyperliquid_funding_bps_per_hour,
        latest_polymarket_market: options.latest_polymarket_market,
        base_asset: options.base_asset,
        market_type: options.market_type,
        market_stale_after_minutes: options.market_stale_after_minutes,
    })
}

struct ReplayRunArgs {
    strategy: String,
    database_url: String,
    market_id: Option<String>,
    up_token_id: Option<String>,
    down_token_id: Option<String>,
    start_unix_ms: Option<i64>,
    end_unix_ms: Option<i64>,
    fill_model: String,
    strategy_config: BaselineStrategyConfig,
    hedge_notional_usd: Decimal,
    hedge_slippage_usd: Decimal,
    funding_hours: Decimal,
    polymarket_maker_bps: Decimal,
    polymarket_taker_bps: Decimal,
    hyperliquid_maker_bps: Decimal,
    hyperliquid_taker_bps: Decimal,
    hyperliquid_funding_bps_per_hour: Decimal,
    latest_polymarket_market: bool,
    base_asset: String,
    market_type: String,
    market_stale_after_minutes: i64,
}

async fn run_replay_from_database(args: ReplayRunArgs) -> anyhow::Result<PaperReplayReport> {
    let (market, data, fill_model, fee_schedule, preflight) =
        load_replay_inputs_from_database(&args).await?;
    if !preflight.ready_for_replay {
        anyhow::bail!(
            "paper replay preflight failed: {} blocker(s); run `liq replay preflight --json` for details",
            preflight.blockers.len()
        );
    }

    let input = PaperReplayInput {
        market,
        liquidations: data.liquidations,
        polymarket_quotes: data.polymarket_quotes,
        polymarket_trades: data.polymarket_trades,
        hyperliquid_quotes: data.hyperliquid_quotes,
        hyperliquid_trades: data.hyperliquid_trades,
        strategy_config: args.strategy_config,
        fill_model,
        fee_schedule,
        hedge_notional_usd: args.hedge_notional_usd,
        hedge_slippage_usd: args.hedge_slippage_usd,
        funding_hours: args.funding_hours,
    };
    run_paper_replay(&input).context("paper replay failed")
}

async fn preflight_replay_from_database(
    args: ReplayRunArgs,
) -> anyhow::Result<PaperReplayPreflightReport> {
    let (_market, _data, _fill_model, _fee_schedule, preflight) =
        load_replay_inputs_from_database(&args).await?;
    Ok(preflight)
}

async fn load_replay_inputs_from_database(
    args: &ReplayRunArgs,
) -> anyhow::Result<(
    BaselineMarket,
    liq_recorder::records::PaperReplayDataRecord,
    FillModel,
    FeeSchedule,
    PaperReplayPreflightReport,
)> {
    if args.strategy != "baseline" {
        anyhow::bail!(
            "unsupported replay strategy '{}'; supported: baseline",
            args.strategy
        );
    }
    validate_replay_numeric_args(args)?;
    let pool = connect(&args.database_url).await?;
    let market = resolve_replay_market(&pool, args).await?;

    let request = DryRunRequest {
        sources: vec![
            "bybit".to_owned(),
            "polymarket".to_owned(),
            "hyperliquid".to_owned(),
        ],
        start_unix_ms: market.start_unix_ms,
        end_unix_ms: market.end_unix_ms,
    };
    validate_dry_run(&request).context("replay run validation failed")?;

    let fill_model = parse_fill_model(&args.fill_model)?;
    let start = offset_from_unix_ms(market.start_unix_ms)?;
    let end = offset_from_unix_ms(market.end_unix_ms)?;
    let data = repository::paper_replay_data(&pool, start, end)
        .await
        .context("failed to read paper replay data")?;
    let data = filter_replay_data_for_market(data, &market);
    let fee_schedule = FeeSchedule {
        version: "cli_fee_schedule_v1".to_owned(),
        polymarket_maker_bps: args.polymarket_maker_bps,
        polymarket_taker_bps: args.polymarket_taker_bps,
        hyperliquid_maker_bps: args.hyperliquid_maker_bps,
        hyperliquid_taker_bps: args.hyperliquid_taker_bps,
        hyperliquid_funding_bps_per_hour: args.hyperliquid_funding_bps_per_hour,
    };
    let preflight = paper_replay_preflight(&PaperReplayPreflightInput {
        market: market.clone(),
        data_counts: paper_replay_data_counts(&data),
        minimum_counts: PaperReplayDataCounts::real_run_minimums(),
        fill_model,
        fee_schedule: fee_schedule.clone(),
        hedge_slippage_usd: args.hedge_slippage_usd,
        funding_hours: args.funding_hours,
        now_unix_ms: Some(offset_to_unix_ms(OffsetDateTime::now_utc())?),
        market_stale_after_ms: Some(args.market_stale_after_minutes.max(1) * 60 * 1_000),
        require_trade_cross: true,
        require_nonzero_cost_assumptions: true,
    });

    Ok((market, data, fill_model, fee_schedule, preflight))
}

fn validate_replay_numeric_args(args: &ReplayRunArgs) -> anyhow::Result<()> {
    if args.hedge_notional_usd <= Decimal::ZERO {
        anyhow::bail!("--hedge-notional-usd must be greater than zero");
    }
    if args.hedge_slippage_usd < Decimal::ZERO {
        anyhow::bail!("--hedge-slippage-usd must be greater than or equal to zero");
    }
    if args.funding_hours < Decimal::ZERO {
        anyhow::bail!("--funding-hours must be greater than or equal to zero");
    }
    for (name, value) in [
        ("--polymarket-maker-bps", args.polymarket_maker_bps),
        ("--polymarket-taker-bps", args.polymarket_taker_bps),
        ("--hyperliquid-maker-bps", args.hyperliquid_maker_bps),
        ("--hyperliquid-taker-bps", args.hyperliquid_taker_bps),
        (
            "--hyperliquid-funding-bps-per-hour",
            args.hyperliquid_funding_bps_per_hour,
        ),
    ] {
        if value < Decimal::ZERO {
            anyhow::bail!("{name} must be greater than or equal to zero");
        }
    }
    Ok(())
}

fn resolve_baseline_strategy_config(
    options: &ReplayRunOptions,
) -> anyhow::Result<BaselineStrategyConfig> {
    let mut config = match options.replay_profile.as_str() {
        "baseline" => BaselineStrategyConfig::default(),
        "research-wide-threshold" => BaselineStrategyConfig {
            liquidation_threshold_max_usd: Decimal::new(1_000_000, 0),
            ..BaselineStrategyConfig::default()
        },
        other => anyhow::bail!(
            "unsupported replay profile '{other}'; supported: baseline, research-wide-threshold"
        ),
    };

    if let Some(value) = options.liquidation_threshold_min_usd {
        config.liquidation_threshold_min_usd = value;
    }
    if let Some(value) = options.liquidation_threshold_max_usd {
        config.liquidation_threshold_max_usd = value;
    }
    if let Some(value) = options.pullback_pct {
        config.pullback_pct = value;
    }
    if let Some(value) = options.polymarket_usd_per_position {
        config.polymarket_usd_per_position = value;
    }
    if let Some(value) = options.order_cancel_window_seconds {
        config.order_cancel_window_ms = value
            .checked_mul(1_000)
            .context("--order-cancel-window-seconds is too large")?;
    }

    validate_baseline_strategy_config(&config)?;
    Ok(config)
}

fn validate_baseline_strategy_config(config: &BaselineStrategyConfig) -> anyhow::Result<()> {
    if config.liquidation_threshold_min_usd <= Decimal::ZERO {
        anyhow::bail!("--liquidation-threshold-min-usd must be greater than zero");
    }
    if config.liquidation_threshold_max_usd < config.liquidation_threshold_min_usd {
        anyhow::bail!(
            "--liquidation-threshold-max-usd must be greater than or equal to --liquidation-threshold-min-usd"
        );
    }
    if config.pullback_pct < Decimal::ZERO || config.pullback_pct >= Decimal::ONE {
        anyhow::bail!("--pullback-pct must be greater than or equal to 0 and less than 1");
    }
    if config.polymarket_usd_per_position <= Decimal::ZERO {
        anyhow::bail!("--polymarket-usd-per-position must be greater than zero");
    }
    if config.order_cancel_window_ms < 0 {
        anyhow::bail!("--order-cancel-window-seconds must be greater than or equal to zero");
    }
    Ok(())
}

fn filter_replay_data_for_market(
    data: PaperReplayDataRecord,
    market: &BaselineMarket,
) -> PaperReplayDataRecord {
    let up_token = market.up_token_id.as_str();
    let down_token = market.down_token_id.as_str();
    PaperReplayDataRecord {
        liquidations: data
            .liquidations
            .into_iter()
            .filter(|event| is_btc_liquidation_symbol(&event.symbol))
            .collect(),
        polymarket_quotes: data
            .polymarket_quotes
            .into_iter()
            .filter(|quote| quote.instrument_id == up_token || quote.instrument_id == down_token)
            .collect(),
        polymarket_trades: data
            .polymarket_trades
            .into_iter()
            .filter(|trade| trade.instrument_id == up_token || trade.instrument_id == down_token)
            .collect(),
        hyperliquid_quotes: data
            .hyperliquid_quotes
            .into_iter()
            .filter(|quote| is_hyperliquid_btc_instrument(&quote.instrument_id, &quote.symbol))
            .collect(),
        hyperliquid_trades: data
            .hyperliquid_trades
            .into_iter()
            .filter(|trade| is_hyperliquid_btc_instrument(&trade.instrument_id, &trade.symbol))
            .collect(),
    }
}

fn paper_replay_data_counts(data: &PaperReplayDataRecord) -> PaperReplayDataCounts {
    PaperReplayDataCounts {
        liquidations: data.liquidations.len(),
        polymarket_quotes: data.polymarket_quotes.len(),
        polymarket_trades: data.polymarket_trades.len(),
        hyperliquid_quotes: data.hyperliquid_quotes.len(),
        hyperliquid_trades: data.hyperliquid_trades.len(),
    }
}

fn is_btc_liquidation_symbol(symbol: &str) -> bool {
    matches!(
        symbol.to_ascii_uppercase().as_str(),
        "BTCUSDT" | "BTC-USDT" | "BTC-USDT-SWAP"
    )
}

fn is_hyperliquid_btc_instrument(instrument_id: &str, symbol: &str) -> bool {
    instrument_id.eq_ignore_ascii_case("BTC")
        || instrument_id.eq_ignore_ascii_case("BTC-PERP")
        || symbol.eq_ignore_ascii_case("BTC")
        || symbol.eq_ignore_ascii_case("BTC-PERP")
}

async fn resolve_replay_market(
    pool: &sqlx::PgPool,
    args: &ReplayRunArgs,
) -> anyhow::Result<BaselineMarket> {
    if args.latest_polymarket_market {
        if args.market_id.is_some()
            || args.up_token_id.is_some()
            || args.down_token_id.is_some()
            || args.start_unix_ms.is_some()
            || args.end_unix_ms.is_some()
        {
            anyhow::bail!(
                "--latest-polymarket-market cannot be combined with manual market/token/time arguments"
            );
        }
        let market = repository::latest_polymarket_market(
            pool,
            &args.base_asset,
            &args.market_type,
        )
        .await
        .with_context(|| {
            format!(
                "failed to read latest Polymarket metadata for base_asset={} market_type={}",
                args.base_asset, args.market_type
            )
        })?
        .with_context(|| {
            format!(
                "no Polymarket market metadata found for base_asset={} market_type={}",
                args.base_asset, args.market_type
            )
        })?;
        return Ok(BaselineMarket {
            market_id: market.market_id,
            up_token_id: market.up_token_id,
            down_token_id: market.down_token_id,
            start_unix_ms: offset_to_unix_ms(market.start_ts)?,
            end_unix_ms: offset_to_unix_ms(market.end_ts)?,
        });
    }

    Ok(BaselineMarket {
        market_id: required_replay_arg(args.market_id.clone(), "--market-id")?,
        up_token_id: required_replay_arg(args.up_token_id.clone(), "--up-token-id")?,
        down_token_id: required_replay_arg(args.down_token_id.clone(), "--down-token-id")?,
        start_unix_ms: required_replay_arg(args.start_unix_ms, "--start-unix-ms")?,
        end_unix_ms: required_replay_arg(args.end_unix_ms, "--end-unix-ms")?,
    })
}

fn required_replay_arg<T>(value: Option<T>, name: &str) -> anyhow::Result<T> {
    value.with_context(|| {
        format!("missing required replay argument {name}; pass it explicitly or use --latest-polymarket-market")
    })
}

async fn upsert_polymarket_market_from_cli(
    options: ReplayMarketUpsertOptions,
) -> anyhow::Result<()> {
    let start_ts = offset_from_unix_ms(options.start_unix_ms)?;
    let end_ts = offset_from_unix_ms(options.end_unix_ms)?;
    let pool = connect(&options.database_url).await?;
    let market = PolymarketMarketRecord {
        market_id: options.market_id,
        slug: options.slug,
        title: options.title,
        base_asset: options.base_asset,
        market_type: options.market_type,
        up_token_id: options.up_token_id,
        down_token_id: options.down_token_id,
        start_ts,
        end_ts,
        status: options.status,
        source: options.source,
        raw_payload: serde_json::json!({"source": "liq-cli"}),
    };
    repository::upsert_polymarket_market(&pool, &market)
        .await
        .context("failed to upsert Polymarket market metadata")?;
    println!("polymarket market metadata upsert ok: {}", market.market_id);
    Ok(())
}

async fn list_polymarket_markets_from_cli(
    database_url: &str,
    base_asset: &str,
    market_type: &str,
    limit: i64,
    json: bool,
) -> anyhow::Result<()> {
    let pool = connect(database_url).await?;
    let markets = repository::list_polymarket_markets(&pool, base_asset, market_type, limit)
        .await
        .context("failed to list Polymarket market metadata")?;
    if json {
        println!(
            "{}",
            serde_json::to_string_pretty(&markets)
                .context("failed to serialize Polymarket market metadata")?
        );
    } else {
        for market in markets {
            println!(
                "{} {} {}..{} up={} down={} status={} source={}",
                market.market_id,
                market.base_asset,
                market.start_ts.format(&Rfc3339)?,
                market.end_ts.format(&Rfc3339)?,
                market.up_token_id,
                market.down_token_id,
                market.status,
                market.source
            );
        }
    }
    Ok(())
}

async fn fetch_polymarket_markets_from_cli(
    options: ReplayMarketFetchOptions,
) -> anyhow::Result<()> {
    if options.page_limit == 0 {
        anyhow::bail!("--page-limit must be greater than zero");
    }
    if options.max_pages == 0 {
        anyhow::bail!("--max-pages must be greater than zero");
    }
    if options.window_seconds <= 0 {
        anyhow::bail!("--window-seconds must be greater than zero");
    }

    let match_terms = if options.match_terms.is_empty() {
        PolymarketMarketFetchFilter::default().match_terms
    } else {
        options.match_terms
    };
    let filter = PolymarketMarketFetchFilter {
        base_asset: options.base_asset,
        market_type: options.market_type,
        match_terms,
        window_seconds: options.window_seconds,
        latest_only: !options.all_matches,
    };
    let markets = if let Some(fixture_path) = options.fixture_path.as_ref() {
        let payload = tokio::fs::read_to_string(fixture_path)
            .await
            .with_context(|| {
                format!(
                    "failed to read Polymarket metadata fixture {}",
                    fixture_path.display()
                )
            })?;
        selected_markets_from_payload(&payload, &filter)?
    } else {
        fetch_polymarket_markets(&PolymarketMarketFetchRequest {
            endpoint_url: options.endpoint_url,
            page_limit: options.page_limit,
            max_pages: options.max_pages,
            filter,
        })
        .await?
    };

    if markets.is_empty() {
        anyhow::bail!("no valid Polymarket BTC 5-minute markets matched the fetch filter");
    }

    if let Some(output_path) = options.output_path.as_ref() {
        write_json_artifact(output_path, &markets).await?;
    }

    if options.apply {
        let database_url = options
            .database_url
            .as_deref()
            .context("--database-url or DATABASE_URL is required when --apply is set")?;
        let pool = connect(database_url).await?;
        for market in &markets {
            repository::upsert_polymarket_market(&pool, market)
                .await
                .with_context(|| {
                    format!(
                        "failed to upsert Polymarket market metadata {}",
                        market.market_id
                    )
                })?;
        }
    }

    if options.json {
        println!(
            "{}",
            serde_json::to_string_pretty(&markets)
                .context("failed to serialize Polymarket market fetch result")?
        );
    } else {
        let mode = if options.apply { "applied" } else { "dry-run" };
        println!("polymarket market fetch {mode}: {} selected", markets.len());
        for market in markets {
            println!(
                "{} {}..{} up={} down={} status={} source={}",
                market.market_id,
                market.start_ts.format(&Rfc3339)?,
                market.end_ts.format(&Rfc3339)?,
                market.up_token_id,
                market.down_token_id,
                market.status,
                market.source
            );
        }
    }
    Ok(())
}

async fn write_replay_artifact(
    artifact_path: &PathBuf,
    report: &PaperReplayReport,
) -> anyhow::Result<()> {
    write_json_artifact(artifact_path, report).await
}

async fn write_json_artifact<T>(artifact_path: &PathBuf, value: &T) -> anyhow::Result<()>
where
    T: serde::Serialize,
{
    if let Some(parent) = artifact_path.parent() {
        tokio::fs::create_dir_all(parent).await.with_context(|| {
            format!(
                "failed to create JSON artifact directory {}",
                parent.display()
            )
        })?;
    }
    let payload = serde_json::to_vec_pretty(value).context("failed to serialize JSON artifact")?;
    tokio::fs::write(artifact_path, payload)
        .await
        .with_context(|| format!("failed to write JSON artifact {}", artifact_path.display()))?;
    Ok(())
}

fn parse_fill_model(value: &str) -> anyhow::Result<FillModel> {
    match value {
        "trade_cross" => Ok(FillModel::TradeCross),
        "book_touch" => Ok(FillModel::BookTouch),
        _ => anyhow::bail!("unsupported fill model '{value}'; supported: trade_cross, book_touch"),
    }
}

fn offset_from_unix_ms(unix_ms: i64) -> anyhow::Result<OffsetDateTime> {
    OffsetDateTime::from_unix_timestamp_nanos(i128::from(unix_ms) * 1_000_000)
        .with_context(|| format!("invalid unix millisecond timestamp: {unix_ms}"))
}

fn offset_to_unix_ms(timestamp: OffsetDateTime) -> anyhow::Result<i64> {
    i64::try_from(timestamp.unix_timestamp_nanos() / 1_000_000)
        .context("timestamp cannot be represented as unix milliseconds")
}

fn print_replay_report(report: &PaperReplayReport, json: bool) -> anyhow::Result<()> {
    if json {
        println!(
            "{}",
            serde_json::to_string_pretty(report).context("failed to serialize replay report")?
        );
    } else {
        println!("strategy_version: {}", report.strategy_version);
        println!("signal_count: {}", report.signal_count);
        println!("polymarket_fills: {}", report.polymarket_fills);
        println!("hedge_fills: {}", report.hedge_fills);
        println!("unhedged_signals: {}", report.unhedged_signals);
        println!("gross_pnl_usd: {}", report.gross_pnl_usd);
        println!("net_unsettled_pnl_usd: {}", report.net_pnl_usd);
        println!("max_drawdown_usd: {}", report.max_drawdown_usd);
        println!("settlement_status: {:?}", report.settlement_status);
    }
    Ok(())
}

fn print_replay_preflight_report(
    report: &PaperReplayPreflightReport,
    json: bool,
) -> anyhow::Result<()> {
    if json {
        println!(
            "{}",
            serde_json::to_string_pretty(report)
                .context("failed to serialize replay preflight report")?
        );
    } else {
        println!("ready_for_replay: {}", report.ready_for_replay);
        println!("market_id: {}", report.market.market_id);
        println!(
            "data_counts: liquidations={} polymarket_quotes={} polymarket_trades={} hyperliquid_quotes={} hyperliquid_trades={}",
            report.data_counts.liquidations,
            report.data_counts.polymarket_quotes,
            report.data_counts.polymarket_trades,
            report.data_counts.hyperliquid_quotes,
            report.data_counts.hyperliquid_trades
        );
        println!("blockers:");
        for item in &report.blockers {
            println!("- {}: {} ({})", item.id, item.status, item.note);
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
        CollectorCommand::UsefulnessReport {
            database_url,
            primary_source,
            window_minutes,
            bucket_seconds,
            stale_after_seconds,
            json,
            artifact_path,
        } => {
            print_collector_usefulness_report(
                database_url,
                primary_source,
                window_minutes,
                bucket_seconds,
                stale_after_seconds,
                json,
                artifact_path,
            )
            .await?;
        }
        CollectorCommand::Dashboard {
            bind,
            database_url,
            window_minutes,
            poll_seconds,
            fixture_path,
            replay_artifact_path,
            polymarket_market_artifact_path,
            polymarket_market_stale_after_minutes,
        } => {
            dashboard::serve_dashboard(DashboardArgs {
                bind,
                database_url,
                window_minutes,
                poll_seconds,
                fixture_path,
                replay_artifact_path,
                polymarket_market_artifact_path,
                polymarket_market_stale_after_minutes,
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

async fn print_collector_usefulness_report(
    database_url: String,
    primary_source: String,
    window_minutes: i64,
    bucket_seconds: i64,
    stale_after_seconds: i64,
    json: bool,
    artifact_path: Option<PathBuf>,
) -> anyhow::Result<()> {
    parse_collector_source(&primary_source)?;
    let pool = connect(&database_url).await?;
    let report = repository::source_usefulness_report(
        &pool,
        &primary_source,
        repository::MetricsWindow::minutes(window_minutes.max(1)),
        bucket_seconds.max(1),
        time::Duration::seconds(stale_after_seconds.max(1)),
    )
    .await
    .context("failed to read source usefulness report")?;
    if let Some(path) = artifact_path.as_ref() {
        write_json_artifact(path, &report).await?;
    }
    if json {
        println!(
            "{}",
            serde_json::to_string_pretty(&report)
                .context("failed to serialize source usefulness report")?
        );
    } else {
        println!(
            "source usefulness: primary={} window={}s bucket={}s stale_after={}s",
            report.primary_source,
            report.window_seconds,
            report.bucket_seconds,
            report.stale_after_seconds
        );
        println!(
            "source\tsymbols\trole\tquality\tsignals\traw_events\tcanonical_events\tmax_notional_usd\tlatency_p50_ms\tlatency_p95_ms\tstale_bps\tadditive_buckets\tverdict"
        );
        for row in &report.sources {
            println!(
                "{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}",
                row.source,
                if row.symbols.is_empty() {
                    "-".to_owned()
                } else {
                    row.symbols.join(",")
                },
                row.coverage_role,
                row.source_quality,
                row.participates_in_signals,
                row.raw_events,
                row.canonical_events,
                row.max_notional_usd
                    .map_or_else(|| "-".to_owned(), |value| value.to_string()),
                row.median_latency_ms
                    .map_or_else(|| "-".to_owned(), |value| value.to_string()),
                row.p95_latency_ms
                    .map_or_else(|| "-".to_owned(), |value| value.to_string()),
                row.stale_rate_bps,
                row.liquidation_ready_buckets_without_primary,
                row.verdict
            );
        }
    }
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
