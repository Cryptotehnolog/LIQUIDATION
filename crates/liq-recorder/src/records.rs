//! Recorder input records.

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
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CollectorHealthRecord {
    /// Source venue or provider id.
    pub source: String,
    /// Exchange symbol.
    pub symbol: String,
    /// Health status, e.g. `ok`, `degraded`, `failed`.
    pub status: String,
    /// Reconnect count inside the current 5-minute rolling window.
    pub reconnects_5m: i32,
    /// Last canonical event timestamp observed by the collector.
    pub last_event_ts: Option<OffsetDateTime>,
    /// Health check timestamp.
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
