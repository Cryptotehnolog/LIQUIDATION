//! Source probe definitions and payload normalization routing.

use liq_connectors::{ConnectorError, binance, bybit, okx};
use liq_domain::{LiquidationEvent, Source};
use serde_json::Value;
use time::OffsetDateTime;

/// Supported collector sources.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CollectorSource {
    /// Bybit public derivatives liquidation stream.
    Bybit,
    /// Binance USD-M public forceOrder snapshot stream.
    Binance,
    /// OKX public liquidation-orders stream.
    Okx,
}

impl CollectorSource {
    /// Parse a storage source id.
    #[must_use]
    pub fn parse(value: &str) -> Option<Self> {
        match value {
            "bybit" => Some(Self::Bybit),
            "binance" => Some(Self::Binance),
            "okx" => Some(Self::Okx),
            _ => None,
        }
    }

    /// Return the domain source id.
    #[must_use]
    pub const fn domain_source(self) -> Source {
        match self {
            Self::Bybit => Source::Bybit,
            Self::Binance => Source::Binance,
            Self::Okx => Source::Okx,
        }
    }
}

/// A single live source/symbol probe target.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SourceProbe {
    source: CollectorSource,
    symbol: String,
}

impl SourceProbe {
    /// Build a Bybit probe.
    #[must_use]
    pub fn bybit(symbol: impl Into<String>) -> Self {
        Self {
            source: CollectorSource::Bybit,
            symbol: symbol.into().to_ascii_uppercase(),
        }
    }

    /// Build a Binance probe.
    #[must_use]
    pub fn binance(symbol: impl Into<String>) -> Self {
        Self {
            source: CollectorSource::Binance,
            symbol: symbol.into().to_ascii_lowercase(),
        }
    }

    /// Build an OKX probe.
    #[must_use]
    pub fn okx(symbol: impl Into<String>) -> Self {
        Self {
            source: CollectorSource::Okx,
            symbol: symbol.into().to_ascii_uppercase(),
        }
    }

    /// Build a probe from source id and symbol.
    #[must_use]
    pub fn new(source: CollectorSource, symbol: impl Into<String>) -> Self {
        match source {
            CollectorSource::Bybit => Self::bybit(symbol),
            CollectorSource::Binance => Self::binance(symbol),
            CollectorSource::Okx => Self::okx(symbol),
        }
    }

    /// Return the source enum.
    #[must_use]
    pub const fn source(&self) -> CollectorSource {
        self.source
    }

    /// Return the configured stream symbol.
    #[must_use]
    pub fn symbol(&self) -> &str {
        &self.symbol
    }

    /// Return the WebSocket endpoint.
    #[must_use]
    pub fn websocket_url(&self) -> String {
        match self.source {
            CollectorSource::Bybit => "wss://stream.bybit.com/v5/public/linear".to_owned(),
            CollectorSource::Binance => {
                format!("wss://fstream.binance.com/ws/{}@forceOrder", self.symbol)
            }
            CollectorSource::Okx => "wss://ws.okx.com:8443/ws/v5/public".to_owned(),
        }
    }

    /// Return the subscription message when the endpoint requires one.
    #[must_use]
    pub fn subscribe_message(&self) -> Option<String> {
        match self.source {
            CollectorSource::Bybit => Some(format!(
                r#"{{"op":"subscribe","args":["allLiquidation.{}"]}}"#,
                self.symbol
            )),
            CollectorSource::Binance => None,
            CollectorSource::Okx => Some(format!(
                r#"{{"op":"subscribe","args":[{{"channel":"liquidation-orders","instType":"SWAP","instId":"{}"}}]}}"#,
                self.symbol
            )),
        }
    }

    /// Normalize a raw text payload into canonical liquidation events.
    ///
    /// # Errors
    ///
    /// Returns a connector error when a liquidation payload is malformed.
    pub fn normalize_payload(
        &self,
        payload: &str,
        received_ts: OffsetDateTime,
    ) -> Result<Vec<LiquidationEvent>, ConnectorError> {
        match self.source {
            CollectorSource::Bybit => {
                if !is_bybit_liquidation_payload(payload) {
                    return Ok(Vec::new());
                }
                bybit::normalize_all_liquidation(payload, received_ts)
            }
            CollectorSource::Binance => {
                binance::normalize_force_order(payload, received_ts).map(|event| vec![event])
            }
            CollectorSource::Okx => Ok(Vec::new()),
        }
    }

    /// Parse raw-only source metadata for payloads that are not canonical-safe.
    ///
    /// # Errors
    ///
    /// Returns a connector error when a source-specific raw metadata payload is
    /// malformed.
    pub fn raw_only_events(
        &self,
        payload: &str,
    ) -> Result<Vec<RawOnlySourceEvent>, ConnectorError> {
        match self.source {
            CollectorSource::Bybit | CollectorSource::Binance => Ok(Vec::new()),
            CollectorSource::Okx => okx::parse_liquidation_orders(payload).map(|items| {
                items
                    .into_iter()
                    .map(|item| RawOnlySourceEvent {
                        source: Source::Okx,
                        source_event_id: item.source_event_id,
                        source_quality: "websocket_only",
                        symbol: item.symbol,
                        exchange_ts: item.exchange_ts,
                    })
                    .collect()
            }),
        }
    }
}

/// Raw source event identity parsed without canonical liquidation normalization.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RawOnlySourceEvent {
    /// Source venue.
    pub source: Source,
    /// Source-local event id.
    pub source_event_id: String,
    /// Source quality string stored with raw payloads.
    pub source_quality: &'static str,
    /// Exchange symbol.
    pub symbol: String,
    /// Exchange event timestamp.
    pub exchange_ts: OffsetDateTime,
}

fn is_bybit_liquidation_payload(payload: &str) -> bool {
    let Ok(value) = serde_json::from_str::<Value>(payload) else {
        return false;
    };

    value
        .get("topic")
        .and_then(Value::as_str)
        .is_some_and(|topic| topic.starts_with("allLiquidation."))
        && value.get("data").is_some_and(Value::is_array)
}

#[cfg(test)]
mod tests {
    use super::*;
    use time::OffsetDateTime;

    #[test]
    fn builds_source_specific_urls() {
        assert_eq!(
            SourceProbe::bybit("btcusdt").websocket_url(),
            "wss://stream.bybit.com/v5/public/linear"
        );
        assert_eq!(
            SourceProbe::binance("BTCUSDT").websocket_url(),
            "wss://fstream.binance.com/ws/btcusdt@forceOrder"
        );
        assert_eq!(
            SourceProbe::okx("btc-usdt-swap").websocket_url(),
            "wss://ws.okx.com:8443/ws/v5/public"
        );
    }

    #[test]
    fn ignores_bybit_subscription_ack() {
        let probe = SourceProbe::bybit("BTCUSDT");
        let events = probe
            .normalize_payload(
                r#"{"success":true,"op":"subscribe","conn_id":"fixture"}"#,
                OffsetDateTime::UNIX_EPOCH,
            )
            .expect("ack should not be an error");

        assert!(events.is_empty());
    }

    #[test]
    fn parses_okx_raw_only_payload() {
        let probe = SourceProbe::okx("BTC-USDT-SWAP");
        let raw = probe
            .raw_only_events(include_str!(
                "../../liq-connectors/tests/fixtures/okx_liquidation_orders.json"
            ))
            .expect("fixture should parse");

        assert_eq!(raw.len(), 1);
        assert_eq!(raw[0].source, Source::Okx);
        assert_eq!(raw[0].source_quality, "websocket_only");
        assert_eq!(raw[0].symbol, "BTC-USDT-SWAP");
    }
}
