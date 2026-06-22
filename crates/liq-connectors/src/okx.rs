//! OKX liquidation-orders WebSocket raw metadata parser.

use std::collections::HashMap;

use liq_domain::{LiquidationEvent, LiquidationSide, Source, SourceQuality};
use rust_decimal::Decimal;
use serde::Deserialize;
use serde_json::Value;
use time::OffsetDateTime;
use uuid::Uuid;

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

/// OKX instrument metadata required for safe canonical notional calculation.
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct OkxInstrumentCache {
    instruments: HashMap<String, OkxInstrument>,
}

impl OkxInstrumentCache {
    /// Parse OKX `GET /api/v5/public/instruments` response into cache.
    ///
    /// # Errors
    ///
    /// Returns an error when JSON or contract value decimals are invalid.
    pub fn from_instruments_response(payload: &str) -> Result<Self, ConnectorError> {
        let parsed: OkxInstrumentResponse = serde_json::from_str(payload)?;
        let mut instruments = HashMap::with_capacity(parsed.data.len());
        for item in parsed.data {
            let contract_value = parse_decimal("ctVal", &item.contract_value)?;
            instruments.insert(
                item.instrument_id.clone(),
                OkxInstrument {
                    instrument_id: item.instrument_id,
                    contract_value,
                    contract_value_currency: item.contract_value_currency,
                },
            );
        }

        Ok(Self { instruments })
    }

    fn get(&self, instrument_id: &str) -> Option<&OkxInstrument> {
        self.instruments.get(instrument_id)
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct OkxInstrument {
    instrument_id: String,
    contract_value: Decimal,
    contract_value_currency: String,
}

#[derive(Debug, Deserialize)]
struct OkxInstrumentResponse {
    #[serde(default)]
    data: Vec<OkxInstrumentItem>,
}

#[derive(Debug, Deserialize)]
struct OkxInstrumentItem {
    #[serde(rename = "instId")]
    instrument_id: String,
    #[serde(rename = "ctVal")]
    contract_value: String,
    #[serde(rename = "ctValCcy")]
    contract_value_currency: String,
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

/// Normalize OKX `liquidation-orders` payload into canonical liquidation events.
///
/// This only succeeds for instruments whose contract value currency matches the
/// instrument base asset, e.g. `BTC-USDT-SWAP` with `ctValCcy=BTC`.
///
/// # Errors
///
/// Returns an error when instrument metadata is missing or cannot prove an
/// honest `notional_usd` calculation.
pub fn normalize_liquidation_orders(
    payload: &str,
    received_ts: OffsetDateTime,
    instruments: &OkxInstrumentCache,
) -> Result<Vec<LiquidationEvent>, ConnectorError> {
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
            let instrument = instruments.get(&item.inst_id);
            item.details.into_iter().map(move |detail| {
                normalize_canonical_detail(&item.inst_id, instrument, &detail, received_ts)
            })
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

fn normalize_canonical_detail(
    symbol: &str,
    instrument: Option<&OkxInstrument>,
    detail: &OkxLiquidationDetail,
    received_ts: OffsetDateTime,
) -> Result<LiquidationEvent, ConnectorError> {
    validate_detail(detail)?;
    let instrument = instrument.ok_or(ConnectorError::Missing("okx.instrument_metadata"))?;
    let base_asset = base_asset(symbol).ok_or(ConnectorError::Missing("okx.instrument_base"))?;
    if instrument.instrument_id != symbol || instrument.contract_value_currency != base_asset {
        return Err(ConnectorError::Missing("okx.instrument_metadata"));
    }

    let price = parse_decimal("bkPx", &detail.bankruptcy_price)?;
    let contracts = parse_decimal("sz", &detail.sz)?;
    let quantity = contracts * instrument.contract_value;
    let exchange_ts = timestamp_ms_from_str(&detail.ts)?;
    let side = match detail.position_side.as_str() {
        "long" => LiquidationSide::Long,
        "short" => LiquidationSide::Short,
        _ => return Err(ConnectorError::Missing("okx.posSide")),
    };
    let source_event_id = source_event_id(symbol, detail);

    Ok(LiquidationEvent {
        event_id: deterministic_event_id(&source_event_id),
        source: Source::Okx,
        source_event_id,
        source_quality: SourceQuality::WebsocketOnly,
        symbol: symbol.to_owned(),
        side,
        price,
        quantity,
        notional_usd: price * quantity,
        exchange_ts,
        received_ts,
    })
}

fn validate_detail(detail: &OkxLiquidationDetail) -> Result<(), ConnectorError> {
    if detail.ts.is_empty()
        || detail.bankruptcy_price.is_empty()
        || detail.position_side.is_empty()
        || detail.side.is_empty()
        || detail.sz.is_empty()
    {
        return Err(ConnectorError::Missing("okx.details"));
    }

    Ok(())
}

fn source_event_id(symbol: &str, detail: &OkxLiquidationDetail) -> String {
    format!(
        "okx:{}:{}:{}:{}:{}:{}",
        symbol, detail.ts, detail.position_side, detail.side, detail.bankruptcy_price, detail.sz
    )
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

fn base_asset(instrument_id: &str) -> Option<&str> {
    instrument_id.split_once('-').map(|(base, _)| base)
}
