//! Bounded live collector runtime and persistence path.

use std::{
    collections::VecDeque,
    sync::Once,
    time::{Duration, Instant},
};

use futures_util::{SinkExt, StreamExt};
use liq_domain::{LiquidationEvent, SourceQuality};
use liq_recorder::{
    records::{CollectorHealthRecord, RawSourceEvent},
    repository,
};
use serde_json::Value;
use sha2::{Digest, Sha256};
use sqlx::PgPool;
use thiserror::Error;
use time::OffsetDateTime;
use tokio::sync::{mpsc, watch};
use tokio::task::JoinSet;
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
    /// Maximum time to wait when the recorder channel is full.
    pub channel_send_timeout: Duration,
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
            channel_send_timeout: Duration::from_secs(5),
            reconnect: ReconnectPolicy::default(),
        }
    }
}

/// Long-running collector service settings.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CollectorRunSettings {
    /// Bounded channel capacity between WebSocket reader and recorder.
    pub channel_capacity: usize,
    /// Per-message read timeout.
    pub read_timeout: Duration,
    /// Maximum time to wait when the recorder channel is full.
    pub channel_send_timeout: Duration,
    /// Source reconnect policy.
    pub reconnect: ReconnectPolicy,
    /// Raw and canonical insert batch size.
    pub batch_size: usize,
    /// Maximum time to wait before flushing a partial batch.
    pub batch_flush_interval: Duration,
    /// Interval for writing collector health rows.
    pub health_interval: Duration,
    /// Optional raw message limit for test and bounded runs.
    pub max_messages: Option<usize>,
    /// Optional runtime limit for test and bounded runs.
    pub max_runtime: Option<Duration>,
}

impl Default for CollectorRunSettings {
    fn default() -> Self {
        Self {
            channel_capacity: 1024,
            read_timeout: Duration::from_secs(30),
            channel_send_timeout: Duration::from_secs(5),
            reconnect: ReconnectPolicy::default(),
            batch_size: 256,
            batch_flush_interval: Duration::from_secs(2),
            health_interval: Duration::from_secs(30),
            max_messages: None,
            max_runtime: None,
        }
    }
}

impl CollectorRunSettings {
    /// Validate settings before opening a long-running live connection.
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
        if self.read_timeout.is_zero() {
            return Err(CollectorError::InvalidSetting(
                "read_timeout must be greater than zero",
            ));
        }
        if self.channel_send_timeout.is_zero() {
            return Err(CollectorError::InvalidSetting(
                "channel_send_timeout must be greater than zero",
            ));
        }
        if self.batch_size == 0 {
            return Err(CollectorError::InvalidSetting(
                "batch_size must be greater than zero",
            ));
        }
        if self.batch_flush_interval.is_zero() {
            return Err(CollectorError::InvalidSetting(
                "batch_flush_interval must be greater than zero",
            ));
        }
        if self.health_interval.is_zero() {
            return Err(CollectorError::InvalidSetting(
                "health_interval must be greater than zero",
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
        if self.channel_send_timeout.is_zero() {
            return Err(CollectorError::InvalidSetting(
                "channel_send_timeout must be greater than zero",
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
    /// Last raw payload timestamp observed by the collector.
    pub last_payload_ts: Option<OffsetDateTime>,
    /// Last canonical event timestamp observed by the collector.
    pub last_event_ts: Option<OffsetDateTime>,
    /// Last observed exchange-to-receive latency in milliseconds.
    pub last_latency_ms: Option<i64>,
    /// Maximum observed exchange-to-receive latency in milliseconds.
    pub max_latency_ms: i64,
}

/// Per-source result returned by a multi-source collector run.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CollectorRunReport {
    /// Source venue or provider id.
    pub source: String,
    /// Exchange symbol.
    pub symbol: String,
    /// Final source status, e.g. `ok`, `failed`, `circuit_open`.
    pub status: String,
    /// Source counters captured by the run.
    pub stats: CollectorStats,
    /// Error message when the source failed.
    pub error: Option<String>,
}

impl CollectorStats {
    /// Observe a raw payload and update freshness counters.
    pub fn observe_payload(&mut self, received_ts: OffsetDateTime) {
        self.last_payload_ts = Some(received_ts);
    }

    /// Observe canonical events and update event/latency counters.
    pub fn observe_events(&mut self, events: &[LiquidationEvent]) {
        self.normalized_events += events.len() as u64;
        for event in events {
            self.last_event_ts = Some(event.exchange_ts);
            let latency_ms = saturating_i128_to_i64(event.latency_ms());
            self.last_latency_ms = Some(latency_ms);
            self.max_latency_ms = self.max_latency_ms.max(latency_ms);
        }
    }

    /// Build a durable health row from current stats.
    #[must_use]
    pub fn to_health_record(
        &self,
        probe: &SourceProbe,
        status: impl Into<String>,
        reconnects_5m: i32,
        checked_at: OffsetDateTime,
    ) -> CollectorHealthRecord {
        CollectorHealthRecord {
            source: probe.source().domain_source().as_str().to_owned(),
            symbol: probe.symbol().to_owned(),
            status: status.into(),
            reconnects_5m,
            last_payload_ts: self.last_payload_ts,
            last_event_ts: self.last_event_ts,
            checked_at,
            messages_received: saturating_u64_to_i64(self.received_messages),
            normalized_events: saturating_u64_to_i64(self.normalized_events),
            raw_inserted: saturating_u64_to_i64(self.raw_inserted),
            canonical_inserted: saturating_u64_to_i64(self.canonical_inserted),
            last_latency_ms: self.last_latency_ms,
            max_latency_ms: self.max_latency_ms,
        }
    }
}

#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
struct ReconnectSnapshot {
    reconnects_5m: i32,
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
    /// The recorder channel stayed full past the configured timeout.
    #[error("collector channel send timed out after {0:?}")]
    BackpressureTimeout(Duration),
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
    /// Reconnect circuit breaker opened.
    #[error("reconnect circuit breaker opened after {attempts} reconnects in 5 minutes")]
    ReconnectCircuitOpen {
        /// Reconnect attempts inside the rolling window.
        attempts: usize,
    },
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

/// Run a long-running live collector until shutdown or configured run limits.
///
/// # Errors
///
/// Returns an error when settings are invalid, the source fails past reconnect
/// policy, or recorder persistence fails.
pub async fn run_live_collector(
    pool: PgPool,
    probe: SourceProbe,
    settings: CollectorRunSettings,
    shutdown: watch::Receiver<bool>,
) -> Result<CollectorStats, CollectorError> {
    settings.validate()?;
    install_rustls_provider();

    let (sender, receiver) = mpsc::channel(settings.channel_capacity);
    let (reconnect_sender, reconnect_receiver) = watch::channel(ReconnectSnapshot::default());
    let producer_probe = probe.clone();
    let producer_settings = settings.clone();
    let producer_shutdown = shutdown.clone();

    let producer = tokio::spawn(async move {
        read_service_with_reconnects(
            producer_probe,
            producer_settings,
            sender,
            reconnect_sender,
            producer_shutdown,
        )
        .await
    });

    let mut stats = record_payloads_batched(
        &pool,
        &probe,
        receiver,
        settings.batch_size,
        settings.batch_flush_interval,
        settings.health_interval,
        reconnect_receiver.clone(),
    )
    .await?;

    match producer.await? {
        Ok(producer_stats) => {
            stats.received_messages = producer_stats.received_messages;
            stats.reconnects = producer_stats.reconnects;
            let reconnects_5m = reconnect_receiver.borrow().reconnects_5m;
            write_health(&pool, &probe, &stats, "ok", reconnects_5m).await?;
            Ok(stats)
        }
        Err(error) => {
            let reconnects_5m = reconnect_receiver.borrow().reconnects_5m;
            write_health(
                &pool,
                &probe,
                &stats,
                health_status_for_error(&error),
                reconnects_5m,
            )
            .await?;
            Err(error)
        }
    }
}

/// Run multiple live collectors in parallel with source-specific health rows.
///
/// # Errors
///
/// Returns an error when settings are invalid, no source is configured, or a
/// collector task cannot be joined.
pub async fn run_live_collectors(
    pool: PgPool,
    probes: Vec<SourceProbe>,
    settings: CollectorRunSettings,
    shutdown: watch::Receiver<bool>,
) -> Result<Vec<CollectorRunReport>, CollectorError> {
    settings.validate()?;
    if probes.is_empty() {
        return Err(CollectorError::InvalidSetting(
            "at least one source must be configured",
        ));
    }

    let mut tasks = JoinSet::new();
    for probe in probes {
        let source = probe.source().domain_source().as_str().to_owned();
        let symbol = probe.symbol().to_owned();
        let pool = pool.clone();
        let settings = settings.clone();
        let shutdown = shutdown.clone();
        tasks.spawn(async move {
            match run_live_collector(pool, probe, settings, shutdown).await {
                Ok(stats) => CollectorRunReport {
                    source,
                    symbol,
                    status: "ok".to_owned(),
                    stats,
                    error: None,
                },
                Err(error) => CollectorRunReport {
                    source,
                    symbol,
                    status: health_status_for_error(&error).to_owned(),
                    stats: CollectorStats::default(),
                    error: Some(error.to_string()),
                },
            }
        });
    }

    let mut reports = Vec::new();
    while let Some(result) = tasks.join_next().await {
        reports.push(result?);
    }
    reports.sort_by(|left, right| {
        left.source
            .cmp(&right.source)
            .then_with(|| left.symbol.cmp(&right.symbol))
    });

    Ok(reports)
}

async fn read_service_with_reconnects(
    probe: SourceProbe,
    settings: CollectorRunSettings,
    sender: mpsc::Sender<ReceivedPayload>,
    reconnect_sender: watch::Sender<ReconnectSnapshot>,
    shutdown: watch::Receiver<bool>,
) -> Result<CollectorStats, CollectorError> {
    let mut stats = CollectorStats::default();
    let mut reconnects = VecDeque::new();
    let mut backoff = settings.reconnect.initial_backoff;
    let started_at = Instant::now();

    loop {
        match read_service_once(
            &probe,
            &settings,
            &sender,
            &mut stats,
            shutdown.clone(),
            started_at,
        )
        .await
        {
            Ok(()) => return Ok(stats),
            Err(error) => {
                let now = Instant::now();
                reconnects.push_back(now);
                while reconnects
                    .front()
                    .is_some_and(|attempt| now.duration_since(*attempt) > Duration::from_secs(300))
                {
                    reconnects.pop_front();
                }
                stats.reconnects += 1;
                let reconnects_5m = reconnects.len();
                let _ = reconnect_sender.send(ReconnectSnapshot {
                    reconnects_5m: saturating_usize_to_i32(reconnects_5m),
                });
                if reconnects_5m > usize::from(settings.reconnect.max_reconnects) {
                    return Err(CollectorError::ReconnectCircuitOpen {
                        attempts: reconnects_5m,
                    });
                }

                warn!(
                    source = ?probe.source(),
                    symbol = probe.symbol(),
                    reconnects_5m,
                    error = %error,
                    "live collector reconnecting"
                );

                tokio::time::sleep(backoff).await;
                if *shutdown.borrow() {
                    return Ok(stats);
                }
                backoff = (backoff * 2).min(settings.reconnect.max_backoff);
            }
        }
    }
}

async fn read_service_once(
    probe: &SourceProbe,
    settings: &CollectorRunSettings,
    sender: &mpsc::Sender<ReceivedPayload>,
    stats: &mut CollectorStats,
    shutdown: watch::Receiver<bool>,
    started_at: Instant,
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

    loop {
        if *shutdown.borrow() {
            return Ok(());
        }
        if settings
            .max_runtime
            .is_some_and(|limit| started_at.elapsed() >= limit)
        {
            return Ok(());
        }
        if settings
            .max_messages
            .is_some_and(|limit| stats.received_messages >= limit as u64)
        {
            return Ok(());
        }

        let Some(message) = (match tokio::time::timeout(settings.read_timeout, socket.next()).await
        {
            Ok(message) => message,
            Err(_) => continue,
        }) else {
            return Ok(());
        };

        match message.map_err(websocket_error)? {
            Message::Text(text) => {
                send_payload(sender, text.to_string(), settings.channel_send_timeout).await?;
                stats.received_messages += 1;
            }
            Message::Binary(bytes) => {
                if let Ok(text) = String::from_utf8(bytes.to_vec()) {
                    send_payload(sender, text, settings.channel_send_timeout).await?;
                    stats.received_messages += 1;
                }
            }
            Message::Ping(_) | Message::Pong(_) | Message::Frame(_) => {}
            Message::Close(_) => return Ok(()),
        }
    }
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
                send_payload(sender, text.to_string(), settings.channel_send_timeout).await?;
                stats.received_messages += 1;
            }
            Message::Binary(bytes) => {
                if let Ok(text) = String::from_utf8(bytes.to_vec()) {
                    send_payload(sender, text, settings.channel_send_timeout).await?;
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
    channel_send_timeout: Duration,
) -> Result<(), CollectorError> {
    let item = ReceivedPayload {
        payload,
        received_ts: OffsetDateTime::now_utc(),
    };
    match tokio::time::timeout(channel_send_timeout, sender.send(item)).await {
        Ok(Ok(())) => Ok(()),
        Ok(Err(_)) => Err(CollectorError::ChannelClosed),
        Err(_) => Err(CollectorError::BackpressureTimeout(channel_send_timeout)),
    }
}

fn health_status_for_error(error: &CollectorError) -> &'static str {
    match error {
        CollectorError::ReconnectCircuitOpen { .. } => "circuit_open",
        CollectorError::BackpressureTimeout(_) => "backpressure",
        _ => "failed",
    }
}

async fn record_payloads(
    pool: &PgPool,
    probe: &SourceProbe,
    mut receiver: mpsc::Receiver<ReceivedPayload>,
) -> Result<CollectorStats, CollectorError> {
    let mut stats = CollectorStats::default();
    while let Some(received) = receiver.recv().await {
        stats.observe_payload(received.received_ts);
        let events = probe.normalize_payload(&received.payload, received.received_ts)?;
        stats.observe_events(&events);
        for event in events {
            let raw = raw_event_from_payload(&event, &received.payload)?;
            stats.raw_inserted += repository::insert_raw_source_event(pool, &raw).await?;
            stats.canonical_inserted += repository::insert_liquidation_event(pool, &event).await?;
        }
    }

    Ok(stats)
}

async fn record_payloads_batched(
    pool: &PgPool,
    probe: &SourceProbe,
    mut receiver: mpsc::Receiver<ReceivedPayload>,
    batch_size: usize,
    batch_flush_interval: Duration,
    health_interval: Duration,
    reconnect_receiver: watch::Receiver<ReconnectSnapshot>,
) -> Result<CollectorStats, CollectorError> {
    let mut stats = CollectorStats::default();
    let mut raw_batch = Vec::with_capacity(batch_size);
    let mut canonical_batch = Vec::with_capacity(batch_size);
    let mut last_health = Instant::now();

    loop {
        match tokio::time::timeout(batch_flush_interval, receiver.recv()).await {
            Ok(Some(payload_item)) => {
                stats.observe_payload(payload_item.received_ts);
                let events =
                    probe.normalize_payload(&payload_item.payload, payload_item.received_ts)?;
                stats.observe_events(&events);
                for event in events {
                    raw_batch.push(raw_event_from_payload(&event, &payload_item.payload)?);
                    canonical_batch.push(event);
                }
                if raw_batch.len() >= batch_size || canonical_batch.len() >= batch_size {
                    flush_batches(pool, &mut raw_batch, &mut canonical_batch, &mut stats).await?;
                }
            }
            Ok(None) => {
                flush_batches(pool, &mut raw_batch, &mut canonical_batch, &mut stats).await?;
                let reconnects_5m = reconnect_receiver.borrow().reconnects_5m;
                write_health(pool, probe, &stats, "ok", reconnects_5m).await?;
                return Ok(stats);
            }
            Err(_) => {
                flush_batches(pool, &mut raw_batch, &mut canonical_batch, &mut stats).await?;
            }
        }

        if last_health.elapsed() >= health_interval {
            flush_batches(pool, &mut raw_batch, &mut canonical_batch, &mut stats).await?;
            let reconnects_5m = reconnect_receiver.borrow().reconnects_5m;
            write_health(pool, probe, &stats, "ok", reconnects_5m).await?;
            last_health = Instant::now();
        }
    }
}

async fn flush_batches(
    pool: &PgPool,
    raw_batch: &mut Vec<RawSourceEvent>,
    canonical_batch: &mut Vec<LiquidationEvent>,
    stats: &mut CollectorStats,
) -> Result<(), CollectorError> {
    if !raw_batch.is_empty() {
        stats.raw_inserted += repository::insert_raw_source_events(pool, raw_batch).await?;
        raw_batch.clear();
    }
    if !canonical_batch.is_empty() {
        stats.canonical_inserted +=
            repository::insert_liquidation_events(pool, canonical_batch).await?;
        canonical_batch.clear();
    }
    Ok(())
}

async fn write_health(
    pool: &PgPool,
    probe: &SourceProbe,
    stats: &CollectorStats,
    health_status: &str,
    reconnects_5m: i32,
) -> Result<(), CollectorError> {
    let health = stats.to_health_record(
        probe,
        health_status,
        reconnects_5m,
        OffsetDateTime::now_utc(),
    );
    repository::insert_collector_health(pool, &health).await?;
    Ok(())
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

fn saturating_u64_to_i64(value: u64) -> i64 {
    i64::try_from(value).unwrap_or(i64::MAX)
}

fn saturating_usize_to_i32(value: usize) -> i32 {
    i32::try_from(value).unwrap_or(i32::MAX)
}

fn saturating_i128_to_i64(value: i128) -> i64 {
    i64::try_from(value).unwrap_or_else(|_| {
        if value.is_negative() {
            i64::MIN
        } else {
            i64::MAX
        }
    })
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
    fn run_settings_rejects_zero_batch_size() {
        let settings = CollectorRunSettings {
            batch_size: 0,
            ..CollectorRunSettings::default()
        };

        let err = settings.validate().expect_err("zero batch size must fail");
        assert!(err.to_string().contains("batch_size"));
    }

    #[test]
    fn run_settings_rejects_zero_channel_send_timeout() {
        let settings = CollectorRunSettings {
            channel_send_timeout: Duration::ZERO,
            ..CollectorRunSettings::default()
        };

        let err = settings
            .validate()
            .expect_err("zero channel_send_timeout must fail");
        assert!(err.to_string().contains("channel_send_timeout"));
    }

    #[test]
    fn multi_source_runner_rejects_empty_probe_list() {
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .build()
            .expect("tokio runtime must build");

        runtime.block_on(async {
            let pool = sqlx::postgres::PgPoolOptions::new()
                .connect_lazy("postgres://liquidation:liquidation@127.0.0.1:15433/liquidation")
                .expect("lazy pool must build");
            let (_, shutdown) = watch::channel(false);

            let err =
                run_live_collectors(pool, Vec::new(), CollectorRunSettings::default(), shutdown)
                    .await
                    .expect_err("empty multi-source run must fail");

            assert!(err.to_string().contains("at least one source"));
        });
    }

    #[test]
    fn maps_collector_errors_to_health_statuses() {
        assert_eq!(
            health_status_for_error(&CollectorError::ReconnectCircuitOpen { attempts: 6 }),
            "circuit_open"
        );
        assert_eq!(
            health_status_for_error(&CollectorError::BackpressureTimeout(Duration::from_secs(1))),
            "backpressure"
        );
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
    fn stats_project_to_health_record_with_latency_metrics() {
        let probe = SourceProbe::bybit("BTCUSDT");
        let exchange_ts = OffsetDateTime::UNIX_EPOCH;
        let received_ts = exchange_ts + time::Duration::milliseconds(350);
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
            exchange_ts,
            received_ts,
        };
        let mut stats = CollectorStats {
            received_messages: 2,
            raw_inserted: 1,
            canonical_inserted: 1,
            ..CollectorStats::default()
        };
        stats.observe_events(&[event]);

        let health = stats.to_health_record(&probe, "ok", 2, received_ts);

        assert_eq!(health.source, "bybit");
        assert_eq!(health.symbol, "BTCUSDT");
        assert_eq!(health.last_payload_ts, None);
        assert_eq!(health.messages_received, 2);
        assert_eq!(health.normalized_events, 1);
        assert_eq!(health.last_latency_ms, Some(350));
        assert_eq!(health.max_latency_ms, 350);
        assert_eq!(health.reconnects_5m, 2);
    }

    #[test]
    fn rustls_provider_install_is_idempotent() {
        install_rustls_provider();
        install_rustls_provider();
    }

    #[test]
    #[ignore = "scheduled heavy test; requires DATABASE_URL"]
    fn mock_collector_stability_records_every_synthetic_event() {
        let Ok(database_url) = std::env::var("DATABASE_URL") else {
            eprintln!("skipping collector stability test: DATABASE_URL is not set");
            return;
        };

        let runtime = tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .build()
            .expect("tokio runtime must build");

        runtime.block_on(async {
            let pool = sqlx::postgres::PgPoolOptions::new()
                .max_connections(5)
                .connect(&database_url)
                .await
                .expect("database must be reachable");
            liq_recorder::migrations::run(&pool)
                .await
                .expect("migrations must run");

            let probe = SourceProbe::bybit("BTCUSDT");
            let (sender, receiver) = mpsc::channel(512);
            let base_ts = unique_timestamp_ms();
            for index in 0..250_i64 {
                let payload = format!(
                    r#"{{"topic":"allLiquidation.BTCUSDT","data":[{{"T":{},"s":"BTCUSDT","S":"Buy","v":"0.001","p":"65000"}}]}}"#,
                    base_ts + index
                );
                sender
                    .send(ReceivedPayload {
                        payload,
                        received_ts: OffsetDateTime::now_utc(),
                    })
                    .await
                    .expect("receiver must be open");
            }
            drop(sender);

            let (_, reconnect_receiver) = watch::channel(ReconnectSnapshot::default());
            let stats = record_payloads_batched(
                &pool,
                &probe,
                receiver,
                64,
                Duration::from_millis(50),
                Duration::from_secs(60),
                reconnect_receiver,
            )
            .await
            .expect("mock collector stability run must succeed");

            assert_eq!(stats.normalized_events, 250);
            assert_eq!(stats.raw_inserted, 250);
            assert_eq!(stats.canonical_inserted, 250);
            assert!(stats.max_latency_ms >= 0);
        });
    }

    fn unique_timestamp_ms() -> i64 {
        let millis = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .expect("system time must be after unix epoch")
            .as_millis();
        i64::try_from(millis).unwrap_or(i64::MAX - 10_000)
    }
}
