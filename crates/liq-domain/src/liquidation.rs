//! Canonical liquidation event model.

use rust_decimal::Decimal;
use serde::{Deserialize, Serialize};
use time::OffsetDateTime;
use uuid::Uuid;

use crate::source::{Source, SourceQuality};

/// Liquidated side.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum LiquidationSide {
    /// Long position was liquidated.
    Long,
    /// Short position was liquidated.
    Short,
}

/// Canonical normalized liquidation event.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct LiquidationEvent {
    /// Deterministic event id generated from source and source event identity.
    pub event_id: Uuid,
    /// Source venue.
    pub source: Source,
    /// Source-specific event id or deterministic payload hash.
    pub source_event_id: String,
    /// Source quality semantics.
    pub source_quality: SourceQuality,
    /// Exchange symbol as received or canonicalized by adapter.
    pub symbol: String,
    /// Liquidated side.
    pub side: LiquidationSide,
    /// Liquidation price.
    pub price: Decimal,
    /// Liquidated quantity in base units when available.
    pub quantity: Decimal,
    /// USD notional. Required for strategy aggregation.
    pub notional_usd: Decimal,
    /// Exchange event timestamp.
    pub exchange_ts: OffsetDateTime,
    /// Local receive timestamp.
    pub received_ts: OffsetDateTime,
}

impl LiquidationEvent {
    /// Returns receive latency in milliseconds.
    #[must_use]
    pub fn latency_ms(&self) -> i128 {
        (self.received_ts - self.exchange_ts).whole_milliseconds()
    }
}
