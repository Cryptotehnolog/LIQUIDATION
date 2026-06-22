//! Fixture-based connector normalization tests.

use liq_connectors::{binance, bybit, okx};
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

#[test]
fn parses_okx_liquidation_orders_as_raw_only() {
    let events =
        okx::parse_liquidation_orders(include_str!("fixtures/okx_liquidation_orders.json"))
            .expect("fixture must parse");

    assert_eq!(events.len(), 1);
    let event = &events[0];
    assert_eq!(event.symbol, "BTC-USDT-SWAP");
    assert_eq!(
        event.source_event_id,
        "okx:BTC-USDT-SWAP:1718750001000:long:sell:65000:100"
    );
    assert_eq!(
        event.exchange_ts,
        OffsetDateTime::from_unix_timestamp(1_718_750_001)
            .expect("fixture timestamp must be valid")
    );
}

#[test]
fn ignores_okx_non_liquidation_service_payload() {
    let events = okx::parse_liquidation_orders(r#"{"event":"error","msg":"fixture"}"#)
        .expect("non-liquidation JSON should be ignored");

    assert!(events.is_empty());
}
