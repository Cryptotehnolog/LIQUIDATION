//! Source identity and quality metadata.

use serde::{Deserialize, Serialize};

/// Supported market-data sources.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Source {
    /// Bybit derivatives.
    Bybit,
    /// Binance USD-M futures.
    Binance,
    /// OKX public derivatives liquidation stream.
    Okx,
    /// Bitget UTA public liquidation snapshot stream.
    Bitget,
    /// Gate futures public liquidation stream.
    Gate,
    /// Polymarket CLOB market data.
    Polymarket,
    /// Hyperliquid market data for hedge simulation.
    Hyperliquid,
}

/// Quality semantics for a source stream.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SourceQuality {
    /// Source claims all liquidation events for the subscribed symbol.
    AllEvents,
    /// Source emits a snapshot or latest/largest event per time window.
    SnapshotOnly,
    /// Source is derived from another source and must not fill gaps silently.
    Derived,
    /// Source is WebSocket-only and has no verified historical backfill.
    WebsocketOnly,
}

impl Source {
    /// Stable lowercase identifier for storage and logs.
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Bybit => "bybit",
            Self::Binance => "binance",
            Self::Okx => "okx",
            Self::Bitget => "bitget",
            Self::Gate => "gate",
            Self::Polymarket => "polymarket",
            Self::Hyperliquid => "hyperliquid",
        }
    }
}
