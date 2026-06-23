//! Market-data connector regression tests.

use liq_connectors::{hyperliquid, polymarket};
use liq_domain::{MarketVenue, TradeSide};
use rust_decimal::Decimal;
use time::OffsetDateTime;

#[test]
fn normalizes_polymarket_book_to_top_of_book_quote() {
    let received_ts = OffsetDateTime::UNIX_EPOCH;

    let quotes = polymarket::normalize_market_quotes(
        include_str!("fixtures/polymarket_book.json"),
        received_ts,
    )
    .expect("fixture must normalize");

    assert_eq!(quotes.len(), 1);
    let quote = &quotes[0];
    assert_eq!(quote.venue, MarketVenue::Polymarket);
    assert_eq!(quote.instrument_id, "123456789");
    assert_eq!(quote.symbol, "0xmarket");
    assert_eq!(quote.best_bid, Some(Decimal::new(48, 2)));
    assert_eq!(quote.best_bid_size, Some(Decimal::new(100, 0)));
    assert_eq!(quote.best_ask, Some(Decimal::new(52, 2)));
    assert_eq!(quote.best_ask_size, Some(Decimal::new(80, 0)));
}

#[test]
fn normalizes_polymarket_array_payloads_from_market_channel() {
    let payload = format!(
        "[{},{}]",
        include_str!("fixtures/polymarket_book.json"),
        include_str!("fixtures/polymarket_last_trade_price.json")
    );

    let quotes = polymarket::normalize_market_quotes(&payload, OffsetDateTime::UNIX_EPOCH)
        .expect("array fixture quotes must normalize");
    let trades = polymarket::normalize_market_trades(&payload, OffsetDateTime::UNIX_EPOCH)
        .expect("array fixture trades must normalize");

    assert_eq!(quotes.len(), 1);
    assert_eq!(trades.len(), 1);
}

#[test]
fn normalizes_polymarket_last_trade_price_to_trade() {
    let trades = polymarket::normalize_market_trades(
        include_str!("fixtures/polymarket_last_trade_price.json"),
        OffsetDateTime::UNIX_EPOCH,
    )
    .expect("fixture must normalize");

    assert_eq!(trades.len(), 1);
    let trade = &trades[0];
    assert_eq!(trade.venue, MarketVenue::Polymarket);
    assert_eq!(trade.side, TradeSide::Buy);
    assert_eq!(trade.price, Decimal::new(51, 2));
    assert_eq!(trade.quantity, Decimal::new(125, 1));
    assert_eq!(trade.notional_usd, Some(Decimal::new(6375, 3)));
}

#[test]
fn normalizes_hyperliquid_bbo_to_hedge_quote() {
    let quotes = hyperliquid::normalize_market_quotes(
        include_str!("fixtures/hyperliquid_bbo.json"),
        OffsetDateTime::UNIX_EPOCH,
    )
    .expect("fixture must normalize");

    assert_eq!(quotes.len(), 1);
    let quote = &quotes[0];
    assert_eq!(quote.venue, MarketVenue::Hyperliquid);
    assert_eq!(quote.instrument_id, "BTC");
    assert_eq!(quote.symbol, "BTC-PERP");
    assert_eq!(quote.best_bid, Some(Decimal::new(650_000, 1)));
    assert_eq!(quote.best_ask, Some(Decimal::new(650_010, 1)));
}

#[test]
fn normalizes_hyperliquid_trades_for_trade_cross_hedge_fill() {
    let trades = hyperliquid::normalize_market_trades(
        include_str!("fixtures/hyperliquid_trades.json"),
        OffsetDateTime::UNIX_EPOCH,
    )
    .expect("fixture must normalize");

    assert_eq!(trades.len(), 1);
    let trade = &trades[0];
    assert_eq!(trade.venue, MarketVenue::Hyperliquid);
    assert_eq!(trade.side, TradeSide::Buy);
    assert_eq!(trade.price, Decimal::new(650_100, 1));
    assert_eq!(trade.quantity, Decimal::new(1, 2));
    assert_eq!(trade.notional_usd, Some(Decimal::new(650_100, 3)));
}
