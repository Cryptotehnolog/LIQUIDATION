//! Bybit allLiquidation normalizer.

use liq_domain::{LiquidationEvent, LiquidationSide, Source, SourceQuality};
use rust_decimal::Decimal;
use serde::Deserialize;
use time::OffsetDateTime;
use uuid::Uuid;

use crate::ConnectorError;

#[derive(Debug, Deserialize)]
struct BybitPayload {
    data: Vec<BybitLiquidation>,
}

#[derive(Debug, Deserialize)]
struct BybitLiquidation {
    #[serde(rename = "T")]
    event_time_ms: i64,
    #[serde(rename = "s")]
    symbol: String,
    #[serde(rename = "S")]
    side: String,
    #[serde(rename = "v")]
    quantity: String,
    #[serde(rename = "p")]
    price: String,
}

/// Normalize a Bybit `allLiquidation` message.
///
/// # Errors
///
/// Returns an error when JSON, decimal, timestamp, or side fields are invalid.
pub fn normalize_all_liquidation(
    payload: &str,
    received_ts: OffsetDateTime,
) -> Result<Vec<LiquidationEvent>, ConnectorError> {
    let parsed: BybitPayload = serde_json::from_str(payload)?;
    parsed
        .data
        .into_iter()
        .map(|item| normalize_item(item, received_ts))
        .collect()
}

fn normalize_item(
    item: BybitLiquidation,
    received_ts: OffsetDateTime,
) -> Result<LiquidationEvent, ConnectorError> {
    let price = parse_decimal("p", &item.price)?;
    let quantity = parse_decimal("v", &item.quantity)?;
    let exchange_ts = timestamp_ms(item.event_time_ms)?;

    let side = match item.side.as_str() {
        "Buy" => LiquidationSide::Long,
        "Sell" => LiquidationSide::Short,
        _ => return Err(ConnectorError::Missing("S")),
    };

    let source_event_id = format!(
        "bybit:{}:{}:{}:{}:{}",
        item.symbol, item.event_time_ms, item.side, item.price, item.quantity
    );

    Ok(LiquidationEvent {
        event_id: deterministic_event_id(&source_event_id),
        source: Source::Bybit,
        source_event_id,
        source_quality: SourceQuality::AllEvents,
        symbol: item.symbol,
        side,
        price,
        quantity,
        notional_usd: price * quantity,
        exchange_ts,
        received_ts,
    })
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
