//! Gate futures public liquidation WebSocket parser.

use std::collections::HashMap;

use liq_domain::{LiquidationEvent, LiquidationSide, Source, SourceQuality};
use rust_decimal::Decimal;
use serde_json::Value;
use time::OffsetDateTime;
use uuid::Uuid;

use crate::ConnectorError;

/// Raw liquidation metadata that can be stored before canonical notional
/// normalization is safe.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GateRawLiquidation {
    /// Deterministic source-local event id.
    pub source_event_id: String,
    /// Gate contract name, e.g. `BTC_USDT`.
    pub symbol: String,
    /// Gate liquidation event timestamp.
    pub exchange_ts: OffsetDateTime,
}

/// Gate contract metadata required for safe canonical notional calculation.
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct GateContractCache {
    contracts: HashMap<String, GateContract>,
}

impl GateContractCache {
    /// Parse a Gate futures contract response into cache.
    ///
    /// # Errors
    ///
    /// Returns an error when JSON or multiplier decimals are invalid.
    pub fn from_contract_response(payload: &str) -> Result<Self, ConnectorError> {
        let value = serde_json::from_str::<Value>(payload)?;
        let items = contract_items(&value);
        let mut contracts = HashMap::with_capacity(items.len());
        for item in items {
            let name = required_string(item, "name", "gate.contract.name")?;
            let multiplier = parse_decimal_value(
                "quanto_multiplier",
                item.get("quanto_multiplier")
                    .ok_or(ConnectorError::Missing("gate.quanto_multiplier"))?,
            )?;
            if multiplier <= Decimal::ZERO {
                return Err(ConnectorError::Decimal {
                    field: "quanto_multiplier",
                    value: multiplier.to_string(),
                });
            }
            contracts.insert(
                name.clone(),
                GateContract {
                    name,
                    quanto_multiplier: multiplier,
                },
            );
        }

        Ok(Self { contracts })
    }

    fn get(&self, contract: &str) -> Option<&GateContract> {
        self.contracts.get(contract)
    }

    /// Return whether this contract has metadata that supports canonical
    /// notional calculation in the current MVP rules.
    #[must_use]
    pub fn supports_canonical_contract(&self, contract: &str) -> bool {
        self.get(contract).is_some()
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct GateContract {
    name: String,
    quanto_multiplier: Decimal,
}

/// Parse Gate `futures.public_liquidates` WebSocket payload into raw metadata.
///
/// # Errors
///
/// Returns an error when liquidation JSON, timestamps, or required fields are
/// malformed.
pub fn parse_public_liquidates(payload: &str) -> Result<Vec<GateRawLiquidation>, ConnectorError> {
    let value = serde_json::from_str::<Value>(payload)?;
    if !is_public_liquidates_payload(&value) {
        return Ok(Vec::new());
    }

    let Some(items) = value.get("result").and_then(Value::as_array) else {
        return Ok(Vec::new());
    };

    items
        .iter()
        .map(|item| raw_liquidation_from_value(item, &value))
        .collect()
}

/// Normalize Gate `futures.public_liquidates` payload into canonical liquidation
/// events.
///
/// Gate reports liquidation `size` in contracts. Canonical normalization is
/// only allowed after contract metadata proves `quanto_multiplier`, so
/// `notional_usd = abs(size) * quanto_multiplier * price` is traceable.
///
/// # Errors
///
/// Returns an error when metadata is missing or cannot prove an honest
/// `notional_usd` calculation.
pub fn normalize_public_liquidates(
    payload: &str,
    received_ts: OffsetDateTime,
    contracts: &GateContractCache,
) -> Result<Vec<LiquidationEvent>, ConnectorError> {
    let value = serde_json::from_str::<Value>(payload)?;
    if !is_public_liquidates_payload(&value) {
        return Ok(Vec::new());
    }

    let Some(items) = value.get("result").and_then(Value::as_array) else {
        return Ok(Vec::new());
    };

    items
        .iter()
        .map(|item| canonical_liquidation_from_value(item, &value, received_ts, contracts))
        .collect()
}

fn contract_items(value: &Value) -> Vec<&Value> {
    if let Some(items) = value.as_array() {
        return items.iter().collect();
    }
    if let Some(items) = value.get("data").and_then(Value::as_array) {
        return items.iter().collect();
    }
    vec![value]
}

fn is_public_liquidates_payload(value: &Value) -> bool {
    value
        .get("channel")
        .and_then(Value::as_str)
        .is_some_and(|channel| channel == "futures.public_liquidates")
        && value
            .get("event")
            .and_then(Value::as_str)
            .is_some_and(|event| event == "update")
}

fn raw_liquidation_from_value(
    item: &Value,
    root: &Value,
) -> Result<GateRawLiquidation, ConnectorError> {
    let symbol = required_string(item, "contract", "gate.contract")?;
    let size = parse_decimal_value(
        "size",
        item.get("size")
            .ok_or(ConnectorError::Missing("gate.size"))?,
    )?;
    let price = parse_decimal_value(
        "price",
        item.get("price")
            .ok_or(ConnectorError::Missing("gate.price"))?,
    )?;
    let exchange_ts = timestamp_from_item_or_root(item, root)?;
    let timestamp_ms = exchange_ts.unix_timestamp_nanos() / 1_000_000;
    let source_event_id = format!("gate:{symbol}:{timestamp_ms}:{size}:{price}");

    Ok(GateRawLiquidation {
        source_event_id,
        symbol,
        exchange_ts,
    })
}

fn canonical_liquidation_from_value(
    item: &Value,
    root: &Value,
    received_ts: OffsetDateTime,
    contracts: &GateContractCache,
) -> Result<LiquidationEvent, ConnectorError> {
    let raw = raw_liquidation_from_value(item, root)?;
    let contract = contracts
        .get(&raw.symbol)
        .ok_or(ConnectorError::Missing("gate.contract_metadata"))?;
    if contract.name != raw.symbol {
        return Err(ConnectorError::Missing("gate.contract_metadata"));
    }
    let size = parse_decimal_value(
        "size",
        item.get("size")
            .ok_or(ConnectorError::Missing("gate.size"))?,
    )?;
    if size == Decimal::ZERO {
        return Err(ConnectorError::Decimal {
            field: "size",
            value: size.to_string(),
        });
    }
    let price = parse_decimal_value(
        "price",
        item.get("price")
            .ok_or(ConnectorError::Missing("gate.price"))?,
    )?;
    let quantity = size.abs() * contract.quanto_multiplier;
    let liquidation_side = if size.is_sign_positive() {
        LiquidationSide::Long
    } else {
        LiquidationSide::Short
    };

    Ok(LiquidationEvent {
        event_id: deterministic_event_id(&raw.source_event_id),
        source: Source::Gate,
        source_event_id: raw.source_event_id,
        source_quality: SourceQuality::WebsocketOnly,
        symbol: raw.symbol,
        side: liquidation_side,
        price,
        quantity,
        notional_usd: price * quantity,
        exchange_ts: raw.exchange_ts,
        received_ts,
    })
}

fn required_string(
    item: &Value,
    field: &'static str,
    missing: &'static str,
) -> Result<String, ConnectorError> {
    item.get(field)
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
        .map(ToOwned::to_owned)
        .ok_or(ConnectorError::Missing(missing))
}

fn parse_decimal_value(field: &'static str, value: &Value) -> Result<Decimal, ConnectorError> {
    match value {
        Value::String(raw) => parse_decimal(field, raw),
        Value::Number(raw) => parse_decimal(field, &raw.to_string()),
        _ => Err(ConnectorError::Missing(field)),
    }
}

fn parse_decimal(field: &'static str, value: &str) -> Result<Decimal, ConnectorError> {
    value
        .parse::<Decimal>()
        .map_err(|_| ConnectorError::Decimal {
            field,
            value: value.to_owned(),
        })
}

fn timestamp_from_item_or_root(
    item: &Value,
    root: &Value,
) -> Result<OffsetDateTime, ConnectorError> {
    if let Some(timestamp_ms) = item
        .get("time_ms")
        .or_else(|| root.get("time_ms"))
        .map(parse_i128_value)
        .transpose()?
    {
        return timestamp_ms_to_datetime(timestamp_ms);
    }
    let timestamp_seconds = item
        .get("time")
        .or_else(|| root.get("time"))
        .map(parse_i128_value)
        .transpose()?
        .ok_or(ConnectorError::Missing("gate.time"))?;
    timestamp_ms_to_datetime(timestamp_seconds * 1_000)
}

fn parse_i128_value(value: &Value) -> Result<i128, ConnectorError> {
    match value {
        Value::String(raw) => raw
            .parse::<i128>()
            .map_err(|_| ConnectorError::Timestamp(-1)),
        Value::Number(raw) => raw
            .as_i64()
            .map(i128::from)
            .ok_or(ConnectorError::Timestamp(-1)),
        _ => Err(ConnectorError::Timestamp(-1)),
    }
}

fn timestamp_ms_to_datetime(timestamp_ms: i128) -> Result<OffsetDateTime, ConnectorError> {
    OffsetDateTime::from_unix_timestamp_nanos(timestamp_ms * 1_000_000)
        .map_err(|_| ConnectorError::Timestamp(saturating_i128_to_i64(timestamp_ms)))
}

fn deterministic_event_id(source_event_id: &str) -> Uuid {
    Uuid::new_v5(&Uuid::NAMESPACE_URL, source_event_id.as_bytes())
}

fn saturating_i128_to_i64(value: i128) -> i64 {
    i64::try_from(value).unwrap_or(if value.is_negative() {
        i64::MIN
    } else {
        i64::MAX
    })
}
