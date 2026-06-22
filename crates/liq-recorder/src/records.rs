//! Recorder input and read-model records.

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
