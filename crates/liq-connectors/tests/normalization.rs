//! Fixture-based connector normalization tests.

use liq_connectors::{binance, bybit};
use liq_domain::{LiquidationSide, Source, SourceQuality};
use rust_decimal::Decimal;
use time::OffsetDateTime;

#[test]
fn normalizes_binance_force_order_snapshot() {
    let received_ts = OffsetDateTime::from_unix_timestamp(1_718_750_001)
        .expect("fixture timestamp must be valid");
    let event = binance::normalize_force_order(
        include_str!("fixtures/binance_force_order.json"),
        received_ts,
    )
    .expect("fixture must normalize");

    assert_eq!(event.source, Source::Binance);
    assert_eq!(event.source_quality, SourceQuality::SnapshotOnly);
    assert_eq!(event.symbol, "BTCUSDT");
    assert_eq!(event.side, LiquidationSide::Long);
    assert_eq!(event.price, Decimal::new(6_500_000, 2));
    assert_eq!(event.quantity, Decimal::new(100, 3));
    assert_eq!(event.notional_usd, Decimal::new(650_000, 2));
}

#[test]
fn normalizes_bybit_all_liquidation_event() {
    let received_ts = OffsetDateTime::from_unix_timestamp(1_718_750_001)
        .expect("fixture timestamp must be valid");
    let events = bybit::normalize_all_liquidation(
        include_str!("fixtures/bybit_all_liquidation.json"),
        received_ts,
    )
    .expect("fixture must normalize");

    assert_eq!(events.len(), 1);
    let event = &events[0];
    assert_eq!(event.source, Source::Bybit);
    assert_eq!(event.source_quality, SourceQuality::AllEvents);
    assert_eq!(event.symbol, "BTCUSDT");
    assert_eq!(event.side, LiquidationSide::Long);
    assert_eq!(event.price, Decimal::new(6_500_000, 2));
    assert_eq!(event.quantity, Decimal::new(100, 3));
    assert_eq!(event.notional_usd, Decimal::new(650_000, 2));
}
