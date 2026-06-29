//! Recorder input and read-model records.

use liq_domain::{LiquidationEvent, MarketQuote, MarketTrade};
use rust_decimal::Decimal;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use time::OffsetDateTime;

/// Raw source event ready for durable storage.
#[derive(Debug, Clone, PartialEq)]
pub struct RawSourceEvent {
    /// Source venue or provider id.
    pub source: String,
    /// Source-local event id.
    pub source_event_id: String,
    /// Source quality semantics.
    pub source_quality: String,
    /// Exchange symbol.
    pub symbol: String,
    /// Exchange event timestamp.
    pub exchange_ts: OffsetDateTime,
    /// Local receive timestamp.
    pub received_ts: OffsetDateTime,
    /// Raw JSON payload.
    pub payload: Value,
    /// SHA-256 payload checksum encoded as lowercase hex.
    pub payload_sha256: String,
}

/// Collector health row ready for durable storage.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CollectorHealthRecord {
    /// Source venue or provider id.
    pub source: String,
    /// Exchange symbol.
    pub symbol: String,
    /// Health status, e.g. `ok`, `degraded`, `failed`.
    pub status: String,
    /// Reconnect count inside the current 5-minute rolling window.
    pub reconnects_5m: i32,
    /// Last raw payload timestamp observed by the collector.
    #[serde(with = "time::serde::rfc3339::option")]
    pub last_payload_ts: Option<OffsetDateTime>,
    /// Last canonical event timestamp observed by the collector.
    #[serde(with = "time::serde::rfc3339::option")]
    pub last_event_ts: Option<OffsetDateTime>,
    /// Health check timestamp.
    #[serde(with = "time::serde::rfc3339")]
    pub checked_at: OffsetDateTime,
    /// Raw WebSocket messages received by the collector.
    pub messages_received: i64,
    /// Canonical liquidation events normalized by the collector.
    pub normalized_events: i64,
    /// Raw rows inserted by the recorder.
    pub raw_inserted: i64,
    /// Canonical rows inserted by the recorder.
    pub canonical_inserted: i64,
    /// Last observed exchange-to-receive latency in milliseconds.
    pub last_latency_ms: Option<i64>,
    /// Maximum observed exchange-to-receive latency in milliseconds.
    pub max_latency_ms: i64,
}

/// Dashboard-ready collector metrics snapshot.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CollectorDashboardMetrics {
    /// Metrics window in seconds.
    pub window_seconds: i64,
    /// Source/symbol metrics.
    pub sources: Vec<CollectorSourceMetrics>,
    /// Storage pressure signal.
    pub storage: CollectorStorageSignal,
}

/// Dashboard-ready metrics for one source and symbol.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CollectorSourceMetrics {
    /// Source venue or provider id.
    pub source: String,
    /// Exchange symbol.
    pub symbol: String,
    /// Source quality semantics used by replay/dashboard policy.
    pub source_quality: String,
    /// Dashboard coverage role, e.g. `strategy_primary` or `diagnostic_only`.
    pub coverage_role: String,
    /// Whether this source is allowed to participate in strategy signals.
    pub participates_in_signals: bool,
    /// Latest source status.
    pub status: String,
    /// Latest health check timestamp.
    #[serde(with = "time::serde::rfc3339")]
    pub checked_at: OffsetDateTime,
    /// Last raw payload timestamp observed by the collector.
    #[serde(with = "time::serde::rfc3339::option")]
    pub last_payload_ts: Option<OffsetDateTime>,
    /// Last canonical event timestamp observed by the collector.
    #[serde(with = "time::serde::rfc3339::option")]
    pub last_event_ts: Option<OffsetDateTime>,
    /// Milliseconds since the latest payload when known.
    pub freshness_ms: Option<i64>,
    /// Latest raw WebSocket messages received counter.
    pub messages_received: i64,
    /// Latest normalized events counter.
    pub normalized_events: i64,
    /// Latest raw rows inserted counter.
    pub raw_inserted: i64,
    /// Latest canonical rows inserted counter.
    pub canonical_inserted: i64,
    /// Latest reconnect count inside rolling 5-minute window.
    pub reconnects_5m: i32,
    /// Maximum reconnect count observed in the dashboard window.
    pub max_reconnects_5m: i32,
    /// Health rows in window with latency below 100 ms.
    pub latency_bucket_lt_100_ms: i64,
    /// Health rows in window with latency between 100 ms and 499 ms.
    pub latency_bucket_100_500_ms: i64,
    /// Health rows in window with latency between 500 ms and 999 ms.
    pub latency_bucket_500_1000_ms: i64,
    /// Health rows in window with latency at or above 1000 ms.
    pub latency_bucket_ge_1000_ms: i64,
}

/// Dashboard-ready history series for trend widgets.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CollectorDashboardHistory {
    /// Metrics window in seconds.
    pub window_seconds: i64,
    /// Historical samples ordered by source, symbol, and timestamp.
    pub samples: Vec<CollectorHistorySample>,
}

/// One collector trend sample.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CollectorHistorySample {
    /// Source venue or provider id.
    pub source: String,
    /// Exchange symbol.
    pub symbol: String,
    /// Health check timestamp.
    #[serde(with = "time::serde::rfc3339")]
    pub checked_at: OffsetDateTime,
    /// Health status at the sample timestamp.
    pub status: String,
    /// Milliseconds since the latest payload at read time when known.
    pub freshness_ms: Option<i64>,
    /// Last observed exchange-to-receive latency in milliseconds.
    pub last_latency_ms: Option<i64>,
    /// Latest reconnect count inside rolling 5-minute window.
    pub reconnects_5m: i32,
    /// Latest raw WebSocket messages received counter.
    pub messages_received: i64,
    /// Latest normalized events counter.
    pub normalized_events: i64,
}

/// Dashboard-ready storage pressure signal.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CollectorStorageSignal {
    /// Total bytes used by collector-facing tables.
    pub total_bytes: i64,
    /// Bytes used by raw payload storage.
    pub raw_source_events_bytes: i64,
    /// Bytes used by canonical event storage.
    pub liquidation_events_bytes: i64,
    /// Bytes used by collector health storage.
    pub collector_health_bytes: i64,
    /// Raw source rows inserted inside the dashboard window.
    pub raw_rows_window: i64,
    /// Canonical rows inserted inside the dashboard window.
    pub canonical_rows_window: i64,
}

/// Source coverage overlap report for one primary and one diagnostic source.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SourceOverlapReport {
    /// Metrics window in seconds.
    pub window_seconds: i64,
    /// Bucket size in seconds.
    pub bucket_seconds: i64,
    /// Primary source summary.
    pub primary: SourceOverlapSummary,
    /// Diagnostic source summary.
    pub diagnostic: SourceOverlapSummary,
    /// Per-bucket raw/canonical counts.
    pub buckets: Vec<SourceOverlapBucket>,
}

/// Source-level overlap summary.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SourceOverlapSummary {
    /// Source venue id.
    pub source: String,
    /// Comma-free list of symbols observed in the window.
    pub symbols: Vec<String>,
    /// Latest health status in the window, when known.
    pub latest_status: Option<String>,
    /// Latest payload timestamp in the window, when known.
    #[serde(with = "time::serde::rfc3339::option")]
    pub last_payload_ts: Option<OffsetDateTime>,
    /// Latest canonical event timestamp in the window, when known.
    #[serde(with = "time::serde::rfc3339::option")]
    pub last_event_ts: Option<OffsetDateTime>,
    /// Health rows observed in the window.
    pub health_rows: i64,
    /// Raw rows observed in the window.
    pub raw_events: i64,
    /// Canonical rows observed in the window.
    pub canonical_events: i64,
    /// Latest reported message counter in the window.
    pub messages_received: i64,
    /// Latest reported normalized event counter in the window.
    pub normalized_events: i64,
    /// Latest reported raw insert counter in the window.
    pub raw_inserted: i64,
    /// Latest reported canonical insert counter in the window.
    pub canonical_inserted: i64,
}

/// One overlap bucket.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SourceOverlapBucket {
    /// Bucket start timestamp.
    #[serde(with = "time::serde::rfc3339")]
    pub bucket_start: OffsetDateTime,
    /// Primary raw rows in this bucket.
    pub primary_raw_events: i64,
    /// Primary canonical rows in this bucket.
    pub primary_canonical_events: i64,
    /// Diagnostic raw rows in this bucket.
    pub diagnostic_raw_events: i64,
    /// Diagnostic canonical rows in this bucket.
    pub diagnostic_canonical_events: i64,
}

/// Multi-source diagnostic report used before enabling new liquidation sources.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SourceUsefulnessReport {
    /// Metrics window in seconds.
    pub window_seconds: i64,
    /// Bucket size in seconds.
    pub bucket_seconds: i64,
    /// Primary source used as current strategy baseline.
    pub primary_source: String,
    /// Payload age threshold used to classify stale health rows.
    pub stale_after_seconds: i64,
    /// Per-source usefulness summaries.
    pub sources: Vec<SourceUsefulnessSummary>,
}

/// Per-source usefulness summary.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SourceUsefulnessSummary {
    /// Source venue id.
    pub source: String,
    /// Symbols observed in the report window.
    pub symbols: Vec<String>,
    /// Source quality semantics used by replay/dashboard policy.
    pub source_quality: String,
    /// Dashboard coverage role, e.g. `strategy_primary` or `diagnostic_only`.
    pub coverage_role: String,
    /// Whether this source is allowed to participate in strategy signals.
    pub participates_in_signals: bool,
    /// Health rows observed in the window.
    pub health_rows: i64,
    /// Raw source rows observed in the window.
    pub raw_events: i64,
    /// Canonical liquidation rows observed in the window.
    pub canonical_events: i64,
    /// Raw rows per hour over the requested window.
    pub events_per_hour: Decimal,
    /// Canonical liquidation rows per hour over the requested window.
    pub canonical_events_per_hour: Decimal,
    /// Largest canonical liquidation notional observed in the window.
    pub max_notional_usd: Option<Decimal>,
    /// Median observed latency from collector health rows.
    pub median_latency_ms: Option<i64>,
    /// p95 observed latency from collector health rows.
    pub p95_latency_ms: Option<i64>,
    /// Health rows whose payload timestamp was missing or older than the stale threshold.
    pub stale_health_rows: i64,
    /// Stale health rows as basis points of all health rows.
    pub stale_rate_bps: i64,
    /// Buckets where this source and the primary source both had canonical rows.
    pub overlap_buckets_with_primary: i64,
    /// Buckets where this source had canonical rows while the primary source had none.
    pub liquidation_ready_buckets_without_primary: i64,
    /// Diagnostic verdict. This never changes source policy automatically.
    pub verdict: String,
}

/// Durable market-data evidence used by strategy readiness gates.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct MarketDataReadinessRecord {
    /// Polymarket quote rows inside the readiness window.
    pub polymarket_quotes: i64,
    /// Polymarket trade rows inside the readiness window.
    pub polymarket_trades: i64,
    /// Hyperliquid quote rows inside the readiness window.
    pub hyperliquid_quotes: i64,
    /// Hyperliquid trade rows inside the readiness window.
    pub hyperliquid_trades: i64,
}

/// Stored data required by one paper replay run.
#[derive(Debug, Clone, PartialEq)]
pub struct PaperReplayDataRecord {
    /// Canonical liquidation events.
    pub liquidations: Vec<LiquidationEvent>,
    /// Polymarket quote rows.
    pub polymarket_quotes: Vec<MarketQuote>,
    /// Polymarket trade rows.
    pub polymarket_trades: Vec<MarketTrade>,
    /// Hyperliquid quote rows.
    pub hyperliquid_quotes: Vec<MarketQuote>,
    /// Hyperliquid trade rows.
    pub hyperliquid_trades: Vec<MarketTrade>,
}

/// Polymarket BTC market metadata needed to build baseline replay windows.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PolymarketMarketRecord {
    /// Polymarket market id or slug-like stable id.
    pub market_id: String,
    /// Human-readable slug when available.
    pub slug: Option<String>,
    /// Human-readable title/question when available.
    pub title: Option<String>,
    /// Base asset, e.g. `BTC`.
    pub base_asset: String,
    /// Market type, e.g. `btc_5m`.
    pub market_type: String,
    /// Outcome token id for UP.
    pub up_token_id: String,
    /// Outcome token id for DOWN.
    pub down_token_id: String,
    /// Inclusive market start timestamp.
    #[serde(with = "time::serde::rfc3339")]
    pub start_ts: OffsetDateTime,
    /// Exclusive market end timestamp.
    #[serde(with = "time::serde::rfc3339")]
    pub end_ts: OffsetDateTime,
    /// Market status, e.g. `open`, `closed`, `resolved`.
    pub status: String,
    /// Metadata source, e.g. `manual`, `fixture`, or API name.
    pub source: String,
    /// Raw source payload for audit/debug.
    pub raw_payload: Value,
}
