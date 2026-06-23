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
fn normalizes_polymarket_price_change_to_top_of_book_quotes() {
    let quotes = polymarket::normalize_market_quotes(
        include_str!("fixtures/polymarket_price_change.json"),
        OffsetDateTime::UNIX_EPOCH,
    )
    .expect("fixture must normalize");

    assert_eq!(quotes.len(), 2);
    assert_eq!(quotes[0].venue, MarketVenue::Polymarket);
    assert_eq!(quotes[0].instrument_id, "123456789");
    assert_eq!(quotes[0].best_bid, Some(Decimal::new(50, 2)));
    assert_eq!(quotes[0].best_bid_size, None);
    assert_eq!(quotes[0].best_ask, Some(Decimal::new(53, 2)));
    assert_eq!(quotes[0].best_ask_size, None);
    assert_eq!(quotes[1].instrument_id, "987654321");
    assert_eq!(quotes[1].best_bid, Some(Decimal::new(46, 2)));
    assert_eq!(quotes[1].best_ask, Some(Decimal::new(49, 2)));
}

#[test]
fn normalizes_polymarket_best_bid_ask_custom_feature_payload() {
    let quotes = polymarket::normalize_market_quotes(
        include_str!("fixtures/polymarket_best_bid_ask.json"),
        OffsetDateTime::UNIX_EPOCH,
    )
    .expect("fixture must normalize");

    assert_eq!(quotes.len(), 1);
    let quote = &quotes[0];
    assert_eq!(quote.instrument_id, "123456789");
    assert_eq!(quote.best_bid, Some(Decimal::new(49, 2)));
    assert_eq!(quote.best_ask, Some(Decimal::new(52, 2)));
    assert_eq!(quote.best_bid_size, None);
    assert_eq!(quote.best_ask_size, None);
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
fn normalizes_hyperliquid_nullable_bbo_side() {
    let quotes = hyperliquid::normalize_market_quotes(
        include_str!("fixtures/hyperliquid_bbo_nullable.json"),
        OffsetDateTime::UNIX_EPOCH,
    )
    .expect("fixture must normalize");

    assert_eq!(quotes.len(), 1);
    let quote = &quotes[0];
    assert_eq!(quote.best_bid, None);
    assert_eq!(quote.best_bid_size, None);
    assert_eq!(quote.best_ask, Some(Decimal::new(650_020, 1)));
    assert_eq!(quote.best_ask_size, Some(Decimal::new(2, 2)));
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
