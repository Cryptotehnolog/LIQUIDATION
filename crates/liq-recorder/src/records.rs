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
