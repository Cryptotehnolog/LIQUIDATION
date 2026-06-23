//! Polymarket CLOB market-data normalizers.

use liq_domain::{MarketQuote, MarketTrade, MarketVenue, TradeSide};
use rust_decimal::Decimal;
use serde::Deserialize;
use serde_json::Value;
use time::OffsetDateTime;
use uuid::Uuid;

use crate::ConnectorError;

#[derive(Debug, Deserialize)]
struct PolymarketBookPayload {
    market: String,
    #[serde(rename = "asset_id")]
    asset_id: String,
    timestamp: String,
    #[serde(default)]
    bids: Vec<PolymarketBookLevel>,
    #[serde(default)]
    asks: Vec<PolymarketBookLevel>,
}

#[derive(Debug, Deserialize)]
struct PolymarketTradePayload {
    market: String,
    #[serde(rename = "asset_id")]
    asset_id: String,
    timestamp: String,
    price: String,
    size: String,
    side: String,
}

#[derive(Debug, Clone, Deserialize)]
struct PolymarketBookLevel {
    price: String,
    size: String,
}

/// Normalize Polymarket market channel book payloads into top-of-book quotes.
///
/// # Errors
///
/// Returns an error when JSON, decimal, or timestamp fields are invalid.
pub fn normalize_market_quotes(
    payload: &str,
    received_ts: OffsetDateTime,
) -> Result<Vec<MarketQuote>, ConnectorError> {
    payload_values(payload)?
        .into_iter()
        .filter(|value| event_type(value) == Some("book"))
        .map(|value| normalize_book_value(value, received_ts))
        .collect()
}

/// Normalize Polymarket `last_trade_price` payloads into market trades.
///
/// # Errors
///
/// Returns an error when JSON, decimal, timestamp, or side fields are invalid.
pub fn normalize_market_trades(
    payload: &str,
    received_ts: OffsetDateTime,
) -> Result<Vec<MarketTrade>, ConnectorError> {
    payload_values(payload)?
        .into_iter()
        .filter(|value| event_type(value) == Some("last_trade_price"))
        .map(|value| normalize_trade_value(value, received_ts))
        .collect()
}

fn payload_values(payload: &str) -> Result<Vec<Value>, ConnectorError> {
    let value = serde_json::from_str::<Value>(payload)?;
    Ok(match value {
        Value::Array(items) => items,
        item => vec![item],
    })
}

fn event_type(value: &Value) -> Option<&'static str> {
    match value.get("event_type").and_then(Value::as_str) {
        Some("book") => Some("book"),
        Some("last_trade_price") => Some("last_trade_price"),
        _ => None,
    }
}

fn normalize_book_value(
    value: Value,
    received_ts: OffsetDateTime,
) -> Result<MarketQuote, ConnectorError> {
    let parsed = serde_json::from_value::<PolymarketBookPayload>(value)?;
    let exchange_ts = timestamp_ms_from_str(&parsed.timestamp)?;
    let best_bid = best_bid(&parsed.bids)?;
    let best_ask = best_ask(&parsed.asks)?;
    let source_event_id = format!(
        "polymarket:book:{}:{}:{}",
        parsed.market, parsed.asset_id, parsed.timestamp
    );

    Ok(MarketQuote {
        event_id: deterministic_event_id(&source_event_id),
        venue: MarketVenue::Polymarket,
        source_event_id,
        instrument_id: parsed.asset_id,
        symbol: parsed.market,
        best_bid: best_bid.as_ref().map(|level| level.0),
        best_bid_size: best_bid.as_ref().map(|level| level.1),
        best_ask: best_ask.as_ref().map(|level| level.0),
        best_ask_size: best_ask.as_ref().map(|level| level.1),
        exchange_ts,
        received_ts,
    })
}

fn normalize_trade_value(
    value: Value,
    received_ts: OffsetDateTime,
) -> Result<MarketTrade, ConnectorError> {
    let parsed = serde_json::from_value::<PolymarketTradePayload>(value)?;
    let price = parse_decimal("price", &parsed.price)?;
    let quantity = parse_decimal("size", &parsed.size)?;
    let exchange_ts = timestamp_ms_from_str(&parsed.timestamp)?;
    let side = match parsed.side.as_str() {
        "BUY" | "buy" => TradeSide::Buy,
        "SELL" | "sell" => TradeSide::Sell,
        _ => TradeSide::Unknown,
    };
    let source_event_id = format!(
        "polymarket:last_trade_price:{}:{}:{}:{}:{}",
        parsed.market, parsed.asset_id, parsed.timestamp, parsed.price, parsed.size
    );

    Ok(MarketTrade {
        event_id: deterministic_event_id(&source_event_id),
        venue: MarketVenue::Polymarket,
        source_event_id,
        instrument_id: parsed.asset_id,
        symbol: parsed.market,
        side,
        price,
        quantity,
        notional_usd: Some(price * quantity),
        exchange_ts,
        received_ts,
    })
}

fn best_bid(levels: &[PolymarketBookLevel]) -> Result<Option<(Decimal, Decimal)>, ConnectorError> {
    parsed_levels(levels)?
        .into_iter()
        .max_by(|left, right| left.0.cmp(&right.0))
        .map_or(Ok(None), |level| Ok(Some(level)))
}

fn best_ask(levels: &[PolymarketBookLevel]) -> Result<Option<(Decimal, Decimal)>, ConnectorError> {
    parsed_levels(levels)?
        .into_iter()
        .min_by(|left, right| left.0.cmp(&right.0))
        .map_or(Ok(None), |level| Ok(Some(level)))
}

fn parsed_levels(
    levels: &[PolymarketBookLevel],
) -> Result<Vec<(Decimal, Decimal)>, ConnectorError> {
    levels
        .iter()
        .map(|level| {
            Ok((
                parse_decimal("price", &level.price)?,
                parse_decimal("size", &level.size)?,
            ))
        })
        .collect()
}

fn deterministic_event_id(source_event_id: &str) -> Uuid {
    Uuid::new_v5(&Uuid::NAMESPACE_URL, source_event_id.as_bytes())
}

fn parse_decimal(field: &'static str, value: &str) -> Result<Decimal, ConnectorError> {
    value
        .parse::<Decimal>()
        .map_err(|_| ConnectorError::Decimal {
            field,
            value: value.to_owned(),
        })
}

fn timestamp_ms_from_str(value: &str) -> Result<OffsetDateTime, ConnectorError> {
    let timestamp_ms = value
        .parse::<i64>()
        .map_err(|_| ConnectorError::Timestamp(-1))?;
    OffsetDateTime::from_unix_timestamp_nanos(i128::from(timestamp_ms) * 1_000_000)
        .map_err(|_| ConnectorError::Timestamp(timestamp_ms))
}
