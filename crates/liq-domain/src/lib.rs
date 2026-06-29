//! Shared domain types for LIQUIDATION.

pub mod liquidation;
pub mod market;
pub mod source;

pub use liquidation::{LiquidationEvent, LiquidationSide};
pub use market::{BookSide, MarketQuote, MarketTrade, MarketVenue, TradeSide};
pub use source::{Source, SourceQuality};

#[cfg(test)]
mod tests {
    use super::*;
    use rust_decimal::Decimal;
    use time::OffsetDateTime;
    use uuid::Uuid;

    #[test]
    fn source_has_stable_storage_identifier() {
        assert_eq!(Source::Bybit.as_str(), "bybit");
        assert_eq!(Source::Binance.as_str(), "binance");
        assert_eq!(Source::Okx.as_str(), "okx");
        assert_eq!(Source::Bitget.as_str(), "bitget");
        assert_eq!(Source::Polymarket.as_str(), "polymarket");
        assert_eq!(Source::Hyperliquid.as_str(), "hyperliquid");
    }

    #[test]
    fn liquidation_event_reports_receive_latency_ms() {
        let exchange_ts =
            OffsetDateTime::from_unix_timestamp(1_718_750_000).expect("fixture timestamp");
        let received_ts = exchange_ts + time::Duration::milliseconds(250);
        let event = LiquidationEvent {
            event_id: Uuid::nil(),
            source: Source::Bybit,
            source_event_id: "bybit:fixture".to_owned(),
            source_quality: SourceQuality::AllEvents,
            symbol: "BTCUSDT".to_owned(),
            side: LiquidationSide::Long,
            price: Decimal::new(6_500_000, 2),
            quantity: Decimal::new(1, 1),
            notional_usd: Decimal::new(650_000, 2),
            exchange_ts,
            received_ts,
        };

        assert_eq!(event.latency_ms(), 250);
    }
}
