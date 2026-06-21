//! Bounded live collector runtime and persistence path.

use std::{sync::Once, time::Duration};

use futures_util::{SinkExt, StreamExt};
use liq_domain::{LiquidationEvent, SourceQuality};
use liq_recorder::{records::RawSourceEvent, repository};
use serde_json::Value;
use sha2::{Digest, Sha256};
use sqlx::PgPool;
use thiserror::Error;
use time::OffsetDateTime;
use tokio::sync::mpsc;
use tokio_tungstenite::{connect_async, tungstenite::Message};
use tracing::{info, warn};

use crate::source::SourceProbe;

static RUSTLS_PROVIDER: Once = Once::new();

/// Reconnect limits for a source probe.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ReconnectPolicy {
    /// Maximum reconnect attempts inside the probe run.
    pub max_reconnects: u16,
    /// Delay before the first reconnect attempt.
    pub initial_backoff: Duration,
    /// Upper bound for reconnect delay.
    pub max_backoff: Duration,
}

impl Default for ReconnectPolicy {
    fn default() -> Self {
        Self {
            max_reconnects: 5,
            initial_backoff: Duration::from_secs(1),
            max_backoff: Duration::from_secs(30),
        }
    }
}

/// Collector runtime settings.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CollectorSettings {
    /// Bounded channel capacity between WebSocket reader and recorder.
    pub channel_capacity: usize,
    /// Number of raw WebSocket payloads to read before stopping.
    pub max_messages: usize,
    /// Minimum raw WebSocket payloads required for a successful probe.
    pub min_messages: usize,
    /// Per-message read timeout.
    pub read_timeout: Duration,
    /// Source reconnect policy.
    pub reconnect: ReconnectPolicy,
}

impl Default for CollectorSettings {
    fn default() -> Self {
        Self {
            channel_capacity: 128,
            max_messages: 1,
            min_messages: 0,
            read_timeout: Duration::from_secs(30),
            reconnect: ReconnectPolicy::default(),
        }
    }
}

impl CollectorSettings {
    /// Validate settings before opening a live connection.
    ///
    /// # Errors
    ///
    /// Returns an error when limits would make the runtime unsafe or useless.
    pub fn validate(&self) -> Result<(), CollectorError> {
        if self.channel_capacity == 0 {
            return Err(CollectorError::InvalidSetting(
                "channel_capacity must be greater than zero",
            ));
        }
        if self.max_messages == 0 {
            return Err(CollectorError::InvalidSetting(
                "max_messages must be greater than zero",
            ));
        }
        if self.min_messages > self.max_messages {
            return Err(CollectorError::InvalidSetting(
                "min_messages must be less than or equal to max_messages",
            ));
        }
        if self.read_timeout.is_zero() {
            return Err(CollectorError::InvalidSetting(
                "read_timeout must be greater than zero",
            ));
        }
        if self.reconnect.initial_backoff.is_zero() {
            return Err(CollectorError::InvalidSetting(
                "initial_backoff must be greater than zero",
            ));
        }
        if self.reconnect.max_backoff < self.reconnect.initial_backoff {
            return Err(CollectorError::InvalidSetting(
                "max_backoff must be greater than or equal to initial_backoff",
            ));
        }
        Ok(())
    }
}

/// Collector counters returned by a probe run.
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct CollectorStats {
    /// Raw WebSocket messages received.
    pub received_messages: u64,
    /// Canonical liquidation events normalized from messages.
    pub normalized_events: u64,
    /// Raw source event rows inserted.
    pub raw_inserted: u64,
    /// Canonical liquidation event rows inserted.
    pub canonical_inserted: u64,
    /// Reconnect attempts made.
    pub reconnects: u64,
}

#[derive(Debug)]
struct ReceivedPayload {
    payload: String,
    received_ts: OffsetDateTime,
}

/// Collector runtime error.
#[derive(Debug, Error)]
pub enum CollectorError {
    /// Runtime setting is invalid.
    #[error("invalid collector setting: {0}")]
    InvalidSetting(&'static str),
    /// WebSocket connection or read failed.
    #[error("websocket error")]
    WebSocket(#[source] Box<tokio_tungstenite::tungstenite::Error>),
    /// WebSocket read timed out.
    #[error("websocket read timed out after {0:?}")]
    ReadTimeout(Duration),
    /// The producer could not send a payload to the recorder.
    #[error("collector channel closed")]
    ChannelClosed,
    /// Connector normalization failed.
    #[error("connector normalization failed")]
    Connector(#[from] liq_connectors::ConnectorError),
    /// Raw payload is not valid JSON.
    #[error("raw payload is not valid JSON")]
    Json(#[from] serde_json::Error),
    /// Recorder insert failed.
    #[error("recorder insert failed")]
    Recorder(#[from] sqlx::Error),
    /// A task failed to join.
    #[error("collector task join failed")]
    Join(#[from] tokio::task::JoinError),
}

/// Run a bounded live WebSocket probe and persist raw plus canonical events.
///
/// # Errors
///
/// Returns an error when settings are invalid, the source cannot be read, or
/// recorder persistence fails.
pub async fn run_live_probe(
    pool: PgPool,
    probe: SourceProbe,
    settings: CollectorSettings,
) -> Result<CollectorStats, CollectorError> {
    settings.validate()?;
    install_rustls_provider();
    let (sender, receiver) = mpsc::channel(settings.channel_capacity);
    let producer_probe = probe.clone();
    let producer_settings = settings.clone();

    let producer = tokio::spawn(async move {
        read_with_reconnects(producer_probe, producer_settings, sender).await
    });

    let mut stats = record_payloads(&pool, &probe, receiver).await?;
    let producer_stats = producer.await??;
    stats.received_messages = producer_stats.received_messages;
    stats.reconnects = producer_stats.reconnects;

    Ok(stats)
}

async fn read_with_reconnects(
    probe: SourceProbe,
    settings: CollectorSettings,
    sender: mpsc::Sender<ReceivedPayload>,
) -> Result<CollectorStats, CollectorError> {
    let mut stats = CollectorStats::default();
    let mut reconnects = 0_u16;
    let mut backoff = settings.reconnect.initial_backoff;

    loop {
        match read_once(&probe, &settings, &sender, &mut stats).await {
            Ok(()) => return Ok(stats),
            Err(error) if reconnects < settings.reconnect.max_reconnects => {
                reconnects += 1;
                stats.reconnects = u64::from(reconnects);
                warn!(
                    source = ?probe.source(),
                    symbol = probe.symbol(),
                    reconnects,
                    error = %error,
                    "live probe reconnecting"
                );
                tokio::time::sleep(backoff).await;
                backoff = (backoff * 2).min(settings.reconnect.max_backoff);
            }
            Err(error) => return Err(error),
        }
    }
}

async fn read_once(
    probe: &SourceProbe,
    settings: &CollectorSettings,
    sender: &mpsc::Sender<ReceivedPayload>,
    stats: &mut CollectorStats,
) -> Result<(), CollectorError> {
    let url = probe.websocket_url();
    let (mut socket, _) = connect_async(&url).await.map_err(websocket_error)?;
    info!(url, "websocket connected");

    if let Some(message) = probe.subscribe_message() {
        socket
            .send(Message::Text(message.into()))
            .await
            .map_err(websocket_error)?;
    }

    while stats.received_messages < settings.max_messages as u64 {
        let timeout_result = tokio::time::timeout(settings.read_timeout, socket.next()).await;
        let Some(message) = (match timeout_result {
            Ok(message) => message,
            Err(_) if stats.received_messages >= settings.min_messages as u64 => return Ok(()),
            Err(_) => return Err(CollectorError::ReadTimeout(settings.read_timeout)),
        }) else {
            return Ok(());
        };

        match message.map_err(websocket_error)? {
            Message::Text(text) => {
                send_payload(sender, text.to_string()).await?;
                stats.received_messages += 1;
            }
            Message::Binary(bytes) => {
                if let Ok(text) = String::from_utf8(bytes.to_vec()) {
                    send_payload(sender, text).await?;
                    stats.received_messages += 1;
                }
            }
            Message::Ping(_) | Message::Pong(_) | Message::Frame(_) => {}
            Message::Close(_) => return Ok(()),
        }
    }

    Ok(())
}

fn websocket_error(error: tokio_tungstenite::tungstenite::Error) -> CollectorError {
    CollectorError::WebSocket(Box::new(error))
}

fn install_rustls_provider() {
    RUSTLS_PROVIDER.call_once(|| {
        let _ = rustls::crypto::ring::default_provider().install_default();
    });
}

async fn send_payload(
    sender: &mpsc::Sender<ReceivedPayload>,
    payload: String,
) -> Result<(), CollectorError> {
    sender
        .send(ReceivedPayload {
            payload,
            received_ts: OffsetDateTime::now_utc(),
        })
        .await
        .map_err(|_| CollectorError::ChannelClosed)
}

async fn record_payloads(
    pool: &PgPool,
    probe: &SourceProbe,
    mut receiver: mpsc::Receiver<ReceivedPayload>,
) -> Result<CollectorStats, CollectorError> {
    let mut stats = CollectorStats::default();
    while let Some(received) = receiver.recv().await {
        let events = probe.normalize_payload(&received.payload, received.received_ts)?;
        stats.normalized_events += events.len() as u64;
        for event in events {
            let raw = raw_event_from_payload(&event, &received.payload)?;
            stats.raw_inserted += repository::insert_raw_source_event(pool, &raw).await?;
            stats.canonical_inserted += repository::insert_liquidation_event(pool, &event).await?;
        }
    }

    Ok(stats)
}

fn raw_event_from_payload(
    event: &LiquidationEvent,
    payload: &str,
) -> Result<RawSourceEvent, CollectorError> {
    let payload_json = serde_json::from_str::<Value>(payload)?;
    Ok(RawSourceEvent {
        source: event.source.as_str().to_owned(),
        source_event_id: event.source_event_id.clone(),
        source_quality: source_quality_as_str(event.source_quality).to_owned(),
        symbol: event.symbol.clone(),
        exchange_ts: event.exchange_ts,
        received_ts: event.received_ts,
        payload: payload_json,
        payload_sha256: sha256_hex(payload.as_bytes()),
    })
}

fn source_quality_as_str(source_quality: SourceQuality) -> &'static str {
    match source_quality {
        SourceQuality::AllEvents => "all_events",
        SourceQuality::SnapshotOnly => "snapshot_only",
        SourceQuality::Derived => "derived",
    }
}

fn sha256_hex(input: &[u8]) -> String {
    let digest = Sha256::digest(input);
    format!("{digest:x}")
}

#[cfg(test)]
mod tests {
    use liq_domain::{LiquidationSide, Source, SourceQuality};
    use rust_decimal::Decimal;
    use uuid::Uuid;

    use super::*;

    #[test]
    fn rejects_zero_channel_capacity() {
        let settings = CollectorSettings {
            channel_capacity: 0,
            ..CollectorSettings::default()
        };

        let err = settings
            .validate()
            .expect_err("zero channel capacity must fail");
        assert!(err.to_string().contains("channel_capacity"));
    }

    #[test]
    fn rejects_min_messages_above_max_messages() {
        let settings = CollectorSettings {
            min_messages: 2,
            max_messages: 1,
            ..CollectorSettings::default()
        };

        let err = settings
            .validate()
            .expect_err("min_messages above max_messages must fail");
        assert!(err.to_string().contains("min_messages"));
    }

    #[test]
    fn builds_raw_event_with_payload_checksum() {
        let event = LiquidationEvent {
            event_id: Uuid::nil(),
            source: Source::Bybit,
            source_event_id: "bybit:test".to_owned(),
            source_quality: SourceQuality::AllEvents,
            symbol: "BTCUSDT".to_owned(),
            side: LiquidationSide::Long,
            price: Decimal::new(6_500_000, 2),
            quantity: Decimal::new(100, 3),
            notional_usd: Decimal::new(650_000, 2),
            exchange_ts: OffsetDateTime::UNIX_EPOCH,
            received_ts: OffsetDateTime::UNIX_EPOCH,
        };

        let raw = raw_event_from_payload(&event, r#"{"fixture":true}"#)
            .expect("valid JSON payload must become raw event");

        assert_eq!(raw.source, "bybit");
        assert_eq!(raw.source_quality, "all_events");
        assert_eq!(raw.payload_sha256.len(), 64);
        assert_ne!(raw.payload_sha256, "0".repeat(64));
    }

    #[test]
    fn rustls_provider_install_is_idempotent() {
        install_rustls_provider();
        install_rustls_provider();
    }
}
