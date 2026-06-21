//! Binance USD-M forceOrder normalizer.

use liq_domain::{LiquidationEvent, LiquidationSide, Source, SourceQuality};
use rust_decimal::Decimal;
use serde::Deserialize;
use time::OffsetDateTime;
use uuid::Uuid;

use crate::ConnectorError;

#[derive(Debug, Deserialize)]
struct BinancePayload {
    #[serde(rename = "E")]
    event_time_ms: i64,
    #[serde(rename = "o")]
    order: BinanceOrder,
}

#[derive(Debug, Deserialize)]
struct BinanceOrder {
    #[serde(rename = "s")]
    symbol: String,
    #[serde(rename = "S")]
    side: String,
    #[serde(rename = "p")]
    price: String,
    #[serde(rename = "q")]
    quantity: String,
}

/// Normalize a Binance `forceOrder` snapshot message.
///
/// # Errors
///
/// Returns an error when JSON, decimal, timestamp, or side fields are invalid.
pub fn normalize_force_order(
    payload: &str,
    received_ts: OffsetDateTime,
) -> Result<LiquidationEvent, ConnectorError> {
    let parsed: BinancePayload = serde_json::from_str(payload)?;
    let price = parse_decimal("o.p", &parsed.order.price)?;
    let quantity = parse_decimal("o.q", &parsed.order.quantity)?;
    let exchange_ts = timestamp_ms(parsed.event_time_ms)?;

    let side = match parsed.order.side.as_str() {
        "SELL" => LiquidationSide::Long,
        "BUY" => LiquidationSide::Short,
        _ => return Err(ConnectorError::Missing("o.S")),
    };

    let source_event_id = format!(
        "binance:{}:{}:{}:{}:{}",
        parsed.order.symbol,
        parsed.event_time_ms,
        parsed.order.side,
        parsed.order.price,
        parsed.order.quantity
    );

    Ok(LiquidationEvent {
        event_id: deterministic_event_id(&source_event_id),
        source: Source::Binance,
        source_event_id,
        source_quality: SourceQuality::SnapshotOnly,
        symbol: parsed.order.symbol,
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
