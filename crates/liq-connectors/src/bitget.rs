//! Bitget UTA public liquidation snapshot normalizer.

use liq_domain::{LiquidationEvent, LiquidationSide, Source, SourceQuality};
use rust_decimal::Decimal;
use serde::Deserialize;
use serde_json::Value;
use time::OffsetDateTime;
use uuid::Uuid;

use crate::ConnectorError;

#[derive(Debug, Deserialize)]
struct BitgetPayload {
    #[serde(default)]
    data: Vec<BitgetLiquidation>,
}

#[derive(Debug, Deserialize)]
struct BitgetLiquidation {
    symbol: String,
    side: String,
    price: String,
    amount: String,
    ts: String,
}

/// Normalize Bitget UTA `liquidation` snapshots.
///
/// Bitget documents `amount` for this channel as quote-coin amount. For the
/// USDT futures channel we treat it as `notional_usd`; unsupported service
/// payloads are ignored by returning an empty vector.
///
/// # Errors
///
/// Returns an error when liquidation JSON, decimal, timestamp, or side fields
/// are invalid.
pub fn normalize_liquidations(
    payload: &str,
    received_ts: OffsetDateTime,
) -> Result<Vec<LiquidationEvent>, ConnectorError> {
    if !is_liquidation_payload(payload)? {
        return Ok(Vec::new());
    }

    let parsed: BitgetPayload = serde_json::from_str(payload)?;
    parsed
        .data
        .into_iter()
        .map(|item| normalize_item(item, received_ts))
        .collect()
}

fn normalize_item(
    item: BitgetLiquidation,
    received_ts: OffsetDateTime,
) -> Result<LiquidationEvent, ConnectorError> {
    let price = parse_positive_decimal("price", &item.price)?;
    let notional_usd = parse_positive_decimal("amount", &item.amount)?;
    let quantity = notional_usd / price;
    let event_ts_ms = parse_timestamp_ms(&item.ts)?;
    let exchange_ts = timestamp_ms(event_ts_ms)?;

    let side = match item.side.to_ascii_lowercase().as_str() {
        "buy" => LiquidationSide::Long,
        "sell" => LiquidationSide::Short,
        _ => return Err(ConnectorError::Missing("side")),
    };

    let source_event_id = format!(
        "bitget:{}:{}:{}:{}:{}",
        item.symbol, item.ts, item.side, item.price, item.amount
    );

    Ok(LiquidationEvent {
        event_id: deterministic_event_id(&source_event_id),
        source: Source::Bitget,
        source_event_id,
        source_quality: SourceQuality::SnapshotOnly,
        symbol: item.symbol,
        side,
        price,
        quantity,
        notional_usd,
        exchange_ts,
        received_ts,
    })
}

fn is_liquidation_payload(payload: &str) -> Result<bool, ConnectorError> {
    let value = serde_json::from_str::<Value>(payload)?;
    Ok(value
        .get("arg")
        .and_then(|arg| arg.get("topic").or_else(|| arg.get("channel")))
        .and_then(Value::as_str)
        .is_some_and(|topic| topic.eq_ignore_ascii_case("liquidation")))
}

fn deterministic_event_id(source_event_id: &str) -> Uuid {
    Uuid::new_v5(&Uuid::NAMESPACE_URL, source_event_id.as_bytes())
}

fn parse_positive_decimal(field: &'static str, value: &str) -> Result<Decimal, ConnectorError> {
    let decimal = value
        .parse::<Decimal>()
        .map_err(|_| ConnectorError::Decimal {
            field,
            value: value.to_owned(),
        })?;
    if decimal <= Decimal::ZERO {
        return Err(ConnectorError::Decimal {
            field,
            value: value.to_owned(),
        });
    }
    Ok(decimal)
}

fn parse_timestamp_ms(value: &str) -> Result<i64, ConnectorError> {
    value
        .parse::<i64>()
        .map_err(|_| ConnectorError::Missing("ts"))
}

fn timestamp_ms(value: i64) -> Result<OffsetDateTime, ConnectorError> {
    OffsetDateTime::from_unix_timestamp_nanos(i128::from(value) * 1_000_000)
        .map_err(|_| ConnectorError::Timestamp(value))
}
