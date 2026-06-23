//! Hyperliquid market-data normalizers for paper hedge simulation.

use liq_domain::{MarketQuote, MarketTrade, MarketVenue, TradeSide};
use rust_decimal::Decimal;
use serde::Deserialize;
use serde_json::Value;
use time::OffsetDateTime;
use uuid::Uuid;

use crate::ConnectorError;

#[derive(Debug, Deserialize)]
struct HyperliquidBboPayload {
    data: HyperliquidBboData,
}

#[derive(Debug, Deserialize)]
struct HyperliquidBboData {
    coin: String,
    time: i64,
    bbo: Vec<HyperliquidBookLevel>,
}

#[derive(Debug, Deserialize)]
struct HyperliquidTradesPayload {
    data: Vec<HyperliquidTrade>,
}

#[derive(Debug, Clone, Deserialize)]
struct HyperliquidBookLevel {
    px: String,
    sz: String,
}

#[derive(Debug, Deserialize)]
struct HyperliquidTrade {
    coin: String,
    side: String,
    px: String,
    sz: String,
    time: i64,
    #[serde(default)]
    hash: String,
    #[serde(default)]
    tid: u64,
}

/// Normalize Hyperliquid `bbo` payloads into top-of-book quotes.
///
/// # Errors
///
/// Returns an error when JSON, decimal, or timestamp fields are invalid.
pub fn normalize_market_quotes(
    payload: &str,
    received_ts: OffsetDateTime,
) -> Result<Vec<MarketQuote>, ConnectorError> {
    if channel(payload)? != Some("bbo") {
        return Ok(Vec::new());
    }
    let parsed = serde_json::from_str::<HyperliquidBboPayload>(payload)?;
    let bid = parsed.data.bbo.first().map(parse_level).transpose()?;
    let ask = parsed.data.bbo.get(1).map(parse_level).transpose()?;
    let exchange_ts = timestamp_ms(parsed.data.time)?;
    let source_event_id = format!("hyperliquid:bbo:{}:{}", parsed.data.coin, parsed.data.time);

    Ok(vec![MarketQuote {
        event_id: deterministic_event_id(&source_event_id),
        venue: MarketVenue::Hyperliquid,
        source_event_id,
        instrument_id: parsed.data.coin.clone(),
        symbol: format!("{}-PERP", parsed.data.coin),
        best_bid: bid.as_ref().map(|level| level.0),
        best_bid_size: bid.as_ref().map(|level| level.1),
        best_ask: ask.as_ref().map(|level| level.0),
        best_ask_size: ask.as_ref().map(|level| level.1),
        exchange_ts,
        received_ts,
    }])
}

/// Normalize Hyperliquid `trades` payloads into market trades.
///
/// # Errors
///
/// Returns an error when JSON, decimal, timestamp, or side fields are invalid.
pub fn normalize_market_trades(
    payload: &str,
    received_ts: OffsetDateTime,
) -> Result<Vec<MarketTrade>, ConnectorError> {
    if channel(payload)? != Some("trades") {
        return Ok(Vec::new());
    }
    let parsed = serde_json::from_str::<HyperliquidTradesPayload>(payload)?;

    parsed
        .data
        .iter()
        .map(|trade| normalize_trade(trade, received_ts))
        .collect()
}

fn channel(payload: &str) -> Result<Option<&'static str>, ConnectorError> {
    let value = serde_json::from_str::<Value>(payload)?;
    Ok(match value.get("channel").and_then(Value::as_str) {
        Some("bbo") => Some("bbo"),
        Some("trades") => Some("trades"),
        _ => None,
    })
}

fn normalize_trade(
    trade: &HyperliquidTrade,
    received_ts: OffsetDateTime,
) -> Result<MarketTrade, ConnectorError> {
    let price = parse_decimal("px", &trade.px)?;
    let quantity = parse_decimal("sz", &trade.sz)?;
    let exchange_ts = timestamp_ms(trade.time)?;
    let side = match trade.side.as_str() {
        "B" => TradeSide::Buy,
        "A" => TradeSide::Sell,
        _ => TradeSide::Unknown,
    };
    let source_event_id = format!(
        "hyperliquid:trade:{}:{}:{}:{}:{}",
        trade.coin, trade.time, trade.tid, trade.hash, trade.px
    );

    Ok(MarketTrade {
        event_id: deterministic_event_id(&source_event_id),
        venue: MarketVenue::Hyperliquid,
        source_event_id,
        instrument_id: trade.coin.clone(),
        symbol: format!("{}-PERP", trade.coin),
        side,
        price,
        quantity,
        notional_usd: Some(price * quantity),
        exchange_ts,
        received_ts,
    })
}

fn parse_level(level: &HyperliquidBookLevel) -> Result<(Decimal, Decimal), ConnectorError> {
    Ok((
        parse_decimal("px", &level.px)?,
        parse_decimal("sz", &level.sz)?,
    ))
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

fn timestamp_ms(value: i64) -> Result<OffsetDateTime, ConnectorError> {
    OffsetDateTime::from_unix_timestamp_nanos(i128::from(value) * 1_000_000)
        .map_err(|_| ConnectorError::Timestamp(value))
}
