//! OKX liquidation-orders WebSocket raw metadata parser.

use serde::Deserialize;
use serde_json::Value;
use time::OffsetDateTime;

use crate::ConnectorError;

/// Raw liquidation metadata that can be stored before canonical notional
/// normalization is safe.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OkxRawLiquidation {
    /// Deterministic source-local event id.
    pub source_event_id: String,
    /// OKX instrument id, e.g. `BTC-USDT-SWAP`.
    pub symbol: String,
    /// OKX liquidation detail timestamp.
    pub exchange_ts: OffsetDateTime,
}

#[derive(Debug, Deserialize)]
struct OkxPayload {
    #[serde(default)]
    data: Vec<OkxLiquidation>,
}

#[derive(Debug, Deserialize)]
struct OkxLiquidation {
    #[serde(rename = "instId")]
    inst_id: String,
    #[serde(default)]
    details: Vec<OkxLiquidationDetail>,
}

#[derive(Debug, Deserialize)]
struct OkxLiquidationDetail {
    #[serde(rename = "bkPx")]
    bankruptcy_price: String,
    #[serde(rename = "posSide")]
    position_side: String,
    side: String,
    sz: String,
    ts: String,
}

/// Parse OKX `liquidation-orders` WebSocket payload into raw event metadata.
///
/// This intentionally does not create canonical [`liq_domain::LiquidationEvent`]
/// values. OKX `sz` is instrument-specific contract size, so `notional_usd`
/// needs instrument metadata before it is safe for strategy aggregation.
///
/// # Errors
///
/// Returns an error when JSON is invalid, timestamps are invalid, or a required
/// liquidation detail field is missing.
pub fn parse_liquidation_orders(payload: &str) -> Result<Vec<OkxRawLiquidation>, ConnectorError> {
    let value = serde_json::from_str::<Value>(payload)?;
    if value
        .get("arg")
        .and_then(|arg| arg.get("channel"))
        .and_then(Value::as_str)
        .is_none_or(|channel| channel != "liquidation-orders")
    {
        return Ok(Vec::new());
    }

    let parsed: OkxPayload = serde_json::from_value(value)?;

    parsed
        .data
        .into_iter()
        .flat_map(|item| {
            let symbol = item.inst_id;
            item.details
                .into_iter()
                .map(move |detail| normalize_detail(&symbol, &detail))
        })
        .collect()
}

fn normalize_detail(
    symbol: &str,
    detail: &OkxLiquidationDetail,
) -> Result<OkxRawLiquidation, ConnectorError> {
    if detail.ts.is_empty()
        || detail.bankruptcy_price.is_empty()
        || detail.position_side.is_empty()
        || detail.side.is_empty()
        || detail.sz.is_empty()
    {
        return Err(ConnectorError::Missing("okx.details"));
    }

    let timestamp_ms = detail
        .ts
        .parse::<i64>()
        .map_err(|_| ConnectorError::Timestamp(-1))?;
    let exchange_ts =
        OffsetDateTime::from_unix_timestamp_nanos(i128::from(timestamp_ms) * 1_000_000)
            .map_err(|_| ConnectorError::Timestamp(timestamp_ms))?;

    let source_event_id = format!(
        "okx:{}:{}:{}:{}:{}:{}",
        symbol, detail.ts, detail.position_side, detail.side, detail.bankruptcy_price, detail.sz
    );

    Ok(OkxRawLiquidation {
        source_event_id,
        symbol: symbol.to_owned(),
        exchange_ts,
    })
}
