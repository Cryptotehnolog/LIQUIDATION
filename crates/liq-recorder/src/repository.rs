//! Postgres persistence operations.

use liq_domain::{LiquidationEvent, LiquidationSide, Source, SourceQuality};
use sqlx::{PgPool, QueryBuilder};

use crate::records::RawSourceEvent;

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
        ON CONFLICT (source, source_event_id) DO NOTHING
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
    .execute(pool)
    .await?;

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
        ON CONFLICT (source, source_event_id) DO NOTHING
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
    .execute(pool)
    .await?;

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

    query.push_values(events, |mut row, event| {
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
    query.push(" ON CONFLICT (source, source_event_id) DO NOTHING");

    let result = query.build().execute(pool).await?;
    Ok(result.rows_affected())
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
