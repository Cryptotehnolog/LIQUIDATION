//! Canonical market-data models for paper replay.

use rust_decimal::Decimal;
use serde::{Deserialize, Serialize};
use time::OffsetDateTime;
use uuid::Uuid;

/// Venue used by strategy legs outside liquidation-source aggregation.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MarketVenue {
    /// Polymarket CLOB prediction market.
    Polymarket,
    /// Hyperliquid perpetual market.
    Hyperliquid,
}

impl MarketVenue {
    /// Stable lowercase identifier for storage and reports.
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Polymarket => "polymarket",
            Self::Hyperliquid => "hyperliquid",
        }
    }
}

/// Order book side.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum BookSide {
    /// Bid side.
    Bid,
    /// Ask side.
    Ask,
}

/// Aggressor trade side when the venue provides it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TradeSide {
    /// Buyer-initiated trade.
    Buy,
    /// Seller-initiated trade.
    Sell,
    /// Venue did not provide a reliable side.
    Unknown,
}

/// Canonical top-of-book quote used by paper fill models.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct MarketQuote {
    /// Deterministic quote id generated from venue/source identity.
    pub event_id: Uuid,
    /// Venue.
    pub venue: MarketVenue,
    /// Source-specific event id or deterministic payload hash.
    pub source_event_id: String,
    /// Venue market id or instrument id.
    pub instrument_id: String,
    /// Human-readable symbol or market slug.
    pub symbol: String,
    /// Best bid price.
    pub best_bid: Option<Decimal>,
    /// Best bid size.
    pub best_bid_size: Option<Decimal>,
    /// Best ask price.
    pub best_ask: Option<Decimal>,
    /// Best ask size.
    pub best_ask_size: Option<Decimal>,
    /// Exchange event timestamp.
    pub exchange_ts: OffsetDateTime,
    /// Local receive timestamp.
    pub received_ts: OffsetDateTime,
}

/// Canonical market trade used by conservative paper fill models.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct MarketTrade {
    /// Deterministic trade id generated from venue/source identity.
    pub event_id: Uuid,
    /// Venue.
    pub venue: MarketVenue,
    /// Source-specific event id or deterministic payload hash.
    pub source_event_id: String,
    /// Venue market id or instrument id.
    pub instrument_id: String,
    /// Human-readable symbol or market slug.
    pub symbol: String,
    /// Trade side.
    pub side: TradeSide,
    /// Execution price.
    pub price: Decimal,
    /// Executed quantity.
    pub quantity: Decimal,
    /// USD notional when price/quantity semantics are known.
    pub notional_usd: Option<Decimal>,
    /// Exchange event timestamp.
    pub exchange_ts: OffsetDateTime,
    /// Local receive timestamp.
    pub received_ts: OffsetDateTime,
}
