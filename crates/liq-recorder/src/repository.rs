//! Postgres persistence operations.

use liq_domain::{LiquidationEvent, LiquidationSide, Source, SourceQuality};
use sqlx::{PgPool, QueryBuilder};

use crate::records::{CollectorHealthRecord, RawSourceEvent};

/// Insert a raw source event.
///
/// Existing `(source, source_event_id)` rows are left unchanged.
///
/// # Errors
///
/// Returns an error when Postgres rejects the insert.
pub async fn insert_raw_source_event(
    pool: &PgPool,
    event: &RawSourceEvent,
) -> Result<u64, sqlx::Error> {
    let mut tx = pool.begin().await?;
    let key_result = sqlx::query(
        r"
        INSERT INTO raw_source_event_keys (source, source_event_id)
        VALUES ($1, $2)
        ON CONFLICT (source, source_event_id) DO NOTHING
        ",
    )
    .bind(&event.source)
    .bind(&event.source_event_id)
    .execute(&mut *tx)
    .await?;

    if key_result.rows_affected() == 0 {
        tx.commit().await?;
        return Ok(0);
    }

    let result = sqlx::query(
        r"
        INSERT INTO raw_source_events (
            source,
            source_event_id,
            source_quality,
            symbol,
            exchange_ts,
            received_ts,
            payload,
            payload_sha256
        )
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
        ",
    )
    .bind(&event.source)
    .bind(&event.source_event_id)
    .bind(&event.source_quality)
    .bind(&event.symbol)
    .bind(event.exchange_ts)
    .bind(event.received_ts)
    .bind(&event.payload)
    .bind(&event.payload_sha256)
    .execute(&mut *tx)
    .await?;

    tx.commit().await?;
    Ok(result.rows_affected())
}

/// Insert several raw source events in one statement.
///
/// Existing `(source, source_event_id)` rows are left unchanged.
///
/// # Errors
///
/// Returns an error when Postgres rejects the insert.
pub async fn insert_raw_source_events(
    pool: &PgPool,
    events: &[RawSourceEvent],
) -> Result<u64, sqlx::Error> {
    if events.is_empty() {
        return Ok(0);
    }

    let mut tx = pool.begin().await?;
    let mut accepted = Vec::with_capacity(events.len());
    for event in events {
        let key_result = sqlx::query(
            r"
            INSERT INTO raw_source_event_keys (source, source_event_id)
            VALUES ($1, $2)
            ON CONFLICT (source, source_event_id) DO NOTHING
            ",
        )
        .bind(&event.source)
        .bind(&event.source_event_id)
        .execute(&mut *tx)
        .await?;

        if key_result.rows_affected() == 1 {
            accepted.push(event);
        }
    }

    if accepted.is_empty() {
        tx.commit().await?;
        return Ok(0);
    }

    let mut query = QueryBuilder::new(
        r"
        INSERT INTO raw_source_events (
            source,
            source_event_id,
            source_quality,
            symbol,
            exchange_ts,
            received_ts,
            payload,
            payload_sha256
        )
        ",
    );

    query.push_values(accepted, |mut row, event| {
        row.push_bind(&event.source)
            .push_bind(&event.source_event_id)
            .push_bind(&event.source_quality)
            .push_bind(&event.symbol)
            .push_bind(event.exchange_ts)
            .push_bind(event.received_ts)
            .push_bind(&event.payload)
            .push_bind(&event.payload_sha256);
    });

    let result = query.build().execute(&mut *tx).await?;
    tx.commit().await?;
    Ok(result.rows_affected())
}

/// Insert a canonical liquidation event.
///
/// Existing `(source, source_event_id)` rows are left unchanged.
///
/// # Errors
///
/// Returns an error when Postgres rejects the insert.
pub async fn insert_liquidation_event(
    pool: &PgPool,
    event: &LiquidationEvent,
) -> Result<u64, sqlx::Error> {
    let mut tx = pool.begin().await?;
    let key_result = sqlx::query(
        r"
        INSERT INTO liquidation_event_keys (source, source_event_id)
        VALUES ($1, $2)
        ON CONFLICT (source, source_event_id) DO NOTHING
        ",
    )
    .bind(source_as_str(event.source))
    .bind(&event.source_event_id)
    .execute(&mut *tx)
    .await?;

    if key_result.rows_affected() == 0 {
        tx.commit().await?;
        return Ok(0);
    }

    let result = sqlx::query(
        r"
        INSERT INTO liquidation_events (
            event_id,
            source,
            source_event_id,
            source_quality,
            symbol,
            side,
            price,
            quantity,
            notional_usd,
            exchange_ts,
            received_ts
        )
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)
        ",
    )
    .bind(event.event_id)
    .bind(source_as_str(event.source))
    .bind(&event.source_event_id)
    .bind(source_quality_as_str(event.source_quality))
    .bind(&event.symbol)
    .bind(liquidation_side_as_str(event.side))
    .bind(event.price)
    .bind(event.quantity)
    .bind(event.notional_usd)
    .bind(event.exchange_ts)
    .bind(event.received_ts)
    .execute(&mut *tx)
    .await?;

    tx.commit().await?;
    Ok(result.rows_affected())
}

/// Insert several canonical liquidation events in one statement.
///
/// Existing `(source, source_event_id)` rows are left unchanged.
///
/// # Errors
///
/// Returns an error when Postgres rejects the insert.
pub async fn insert_liquidation_events(
    pool: &PgPool,
    events: &[LiquidationEvent],
) -> Result<u64, sqlx::Error> {
    if events.is_empty() {
        return Ok(0);
    }

    let mut tx = pool.begin().await?;
    let mut accepted = Vec::with_capacity(events.len());
    for event in events {
        let key_result = sqlx::query(
            r"
            INSERT INTO liquidation_event_keys (source, source_event_id)
            VALUES ($1, $2)
            ON CONFLICT (source, source_event_id) DO NOTHING
            ",
        )
        .bind(source_as_str(event.source))
        .bind(&event.source_event_id)
        .execute(&mut *tx)
        .await?;

        if key_result.rows_affected() == 1 {
            accepted.push(event);
        }
    }

    if accepted.is_empty() {
        tx.commit().await?;
        return Ok(0);
    }

    let mut query = QueryBuilder::new(
        r"
        INSERT INTO liquidation_events (
            event_id,
            source,
            source_event_id,
            source_quality,
            symbol,
            side,
            price,
            quantity,
            notional_usd,
            exchange_ts,
            received_ts
        )
        ",
    );

    query.push_values(accepted, |mut row, event| {
        row.push_bind(event.event_id)
            .push_bind(source_as_str(event.source))
            .push_bind(&event.source_event_id)
            .push_bind(source_quality_as_str(event.source_quality))
            .push_bind(&event.symbol)
            .push_bind(liquidation_side_as_str(event.side))
            .push_bind(event.price)
            .push_bind(event.quantity)
            .push_bind(event.notional_usd)
            .push_bind(event.exchange_ts)
            .push_bind(event.received_ts);
    });

    let result = query.build().execute(&mut *tx).await?;
    tx.commit().await?;
    Ok(result.rows_affected())
}

/// Insert one collector health row.
///
/// # Errors
///
/// Returns an error when Postgres rejects the insert.
pub async fn insert_collector_health(
    pool: &PgPool,
    health: &CollectorHealthRecord,
) -> Result<u64, sqlx::Error> {
    let result = sqlx::query(
        r"
        INSERT INTO collector_health (
            source,
            symbol,
            status,
            reconnects_5m,
            last_event_ts,
            checked_at,
            messages_received,
            normalized_events,
            raw_inserted,
            canonical_inserted,
            last_latency_ms,
            max_latency_ms
        )
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12)
        ",
    )
    .bind(&health.source)
    .bind(&health.symbol)
    .bind(&health.status)
    .bind(health.reconnects_5m)
    .bind(health.last_event_ts)
    .bind(health.checked_at)
    .bind(health.messages_received)
    .bind(health.normalized_events)
    .bind(health.raw_inserted)
    .bind(health.canonical_inserted)
    .bind(health.last_latency_ms)
    .bind(health.max_latency_ms)
    .execute(pool)
    .await?;

    Ok(result.rows_affected())
}

/// List recent collector health rows, optionally filtered by source.
///
/// # Errors
///
/// Returns an error when Postgres rejects the query.
pub async fn list_collector_health(
    pool: &PgPool,
    source: Option<&str>,
    limit: i64,
) -> Result<Vec<CollectorHealthRecord>, sqlx::Error> {
    let limit = limit.clamp(1, 500);
    let rows = if let Some(source) = source {
        sqlx::query_as::<_, CollectorHealthRow>(
            r"
            SELECT
                source,
                symbol,
                status,
                reconnects_5m,
                last_event_ts,
                checked_at,
                messages_received,
                normalized_events,
                raw_inserted,
                canonical_inserted,
                last_latency_ms,
                max_latency_ms
            FROM collector_health
            WHERE source = $1
            ORDER BY checked_at DESC
            LIMIT $2
            ",
        )
        .bind(source)
        .bind(limit)
        .fetch_all(pool)
        .await?
    } else {
        sqlx::query_as::<_, CollectorHealthRow>(
            r"
            SELECT
                source,
                symbol,
                status,
                reconnects_5m,
                last_event_ts,
                checked_at,
                messages_received,
                normalized_events,
                raw_inserted,
                canonical_inserted,
                last_latency_ms,
                max_latency_ms
            FROM collector_health
            ORDER BY checked_at DESC
            LIMIT $1
            ",
        )
        .bind(limit)
        .fetch_all(pool)
        .await?
    };

    Ok(rows.into_iter().map(CollectorHealthRecord::from).collect())
}

#[derive(sqlx::FromRow)]
struct CollectorHealthRow {
    source: String,
    symbol: String,
    status: String,
    reconnects_5m: i32,
    last_event_ts: Option<time::OffsetDateTime>,
    checked_at: time::OffsetDateTime,
    messages_received: i64,
    normalized_events: i64,
    raw_inserted: i64,
    canonical_inserted: i64,
    last_latency_ms: Option<i64>,
    max_latency_ms: i64,
}

impl From<CollectorHealthRow> for CollectorHealthRecord {
    fn from(row: CollectorHealthRow) -> Self {
        Self {
            source: row.source,
            symbol: row.symbol,
            status: row.status,
            reconnects_5m: row.reconnects_5m,
            last_event_ts: row.last_event_ts,
            checked_at: row.checked_at,
            messages_received: row.messages_received,
            normalized_events: row.normalized_events,
            raw_inserted: row.raw_inserted,
            canonical_inserted: row.canonical_inserted,
            last_latency_ms: row.last_latency_ms,
            max_latency_ms: row.max_latency_ms,
        }
    }
}

fn source_as_str(source: Source) -> &'static str {
    source.as_str()
}

fn source_quality_as_str(source_quality: SourceQuality) -> &'static str {
    match source_quality {
        SourceQuality::AllEvents => "all_events",
        SourceQuality::SnapshotOnly => "snapshot_only",
        SourceQuality::Derived => "derived",
    }
}

fn liquidation_side_as_str(side: LiquidationSide) -> &'static str {
    match side {
        LiquidationSide::Long => "long",
        LiquidationSide::Short => "short",
    }
}
