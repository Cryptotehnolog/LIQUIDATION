//! Postgres persistence operations.

use liq_domain::{LiquidationEvent, LiquidationSide, Source, SourceQuality};
use sqlx::{PgPool, QueryBuilder};
use time::OffsetDateTime;

use crate::records::{
    CollectorDashboardHistory, CollectorDashboardMetrics, CollectorHealthRecord,
    CollectorHistorySample, CollectorSourceMetrics, CollectorStorageSignal, RawSourceEvent,
    SourceOverlapBucket, SourceOverlapReport, SourceOverlapSummary,
};

/// Metrics aggregation window.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct MetricsWindow {
    seconds: i64,
}

impl MetricsWindow {
    /// Build a window from minutes.
    #[must_use]
    pub const fn minutes(minutes: i64) -> Self {
        Self {
            seconds: minutes * 60,
        }
    }

    /// Return the window size in seconds.
    #[must_use]
    pub const fn seconds(self) -> i64 {
        self.seconds
    }
}

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
            last_payload_ts,
            checked_at,
            messages_received,
            normalized_events,
            raw_inserted,
            canonical_inserted,
            last_latency_ms,
            max_latency_ms
        )
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13)
        ",
    )
    .bind(&health.source)
    .bind(&health.symbol)
    .bind(&health.status)
    .bind(health.reconnects_5m)
    .bind(health.last_event_ts)
    .bind(health.last_payload_ts)
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
                last_payload_ts,
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
                last_payload_ts,
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

/// Return dashboard-ready collector metrics.
///
/// # Errors
///
/// Returns an error when Postgres rejects one of the metrics queries.
pub async fn collector_dashboard_metrics(
    pool: &PgPool,
    window: MetricsWindow,
) -> Result<CollectorDashboardMetrics, sqlx::Error> {
    let window_seconds = window.seconds().max(1);
    let sources = sqlx::query_as::<_, CollectorSourceMetricsRow>(
        r"
        WITH latest AS (
            SELECT DISTINCT ON (source, symbol)
                source,
                symbol,
                status,
                checked_at,
                last_payload_ts,
                last_event_ts,
                messages_received,
                normalized_events,
                raw_inserted,
                canonical_inserted,
                reconnects_5m
            FROM collector_health
            ORDER BY source, symbol, checked_at DESC
        ),
        bucketed AS (
            SELECT
                source,
                symbol,
                COALESCE(MAX(reconnects_5m), 0)::INT AS max_reconnects_5m,
                COUNT(*) FILTER (WHERE last_latency_ms < 100) AS latency_bucket_lt_100_ms,
                COUNT(*) FILTER (WHERE last_latency_ms >= 100 AND last_latency_ms < 500) AS latency_bucket_100_500_ms,
                COUNT(*) FILTER (WHERE last_latency_ms >= 500 AND last_latency_ms < 1000) AS latency_bucket_500_1000_ms,
                COUNT(*) FILTER (WHERE last_latency_ms >= 1000) AS latency_bucket_ge_1000_ms
            FROM collector_health
            WHERE checked_at >= NOW() - ($1::BIGINT * INTERVAL '1 second')
            GROUP BY source, symbol
        )
        SELECT
            latest.source,
            latest.symbol,
            latest.status,
            latest.checked_at,
            latest.last_payload_ts,
            latest.last_event_ts,
            CASE
                WHEN latest.last_payload_ts IS NULL THEN NULL
                ELSE (EXTRACT(EPOCH FROM (NOW() - latest.last_payload_ts)) * 1000)::BIGINT
            END AS freshness_ms,
            latest.messages_received,
            latest.normalized_events,
            latest.raw_inserted,
            latest.canonical_inserted,
            latest.reconnects_5m,
            COALESCE(bucketed.max_reconnects_5m, latest.reconnects_5m)::INT AS max_reconnects_5m,
            COALESCE(bucketed.latency_bucket_lt_100_ms, 0)::BIGINT AS latency_bucket_lt_100_ms,
            COALESCE(bucketed.latency_bucket_100_500_ms, 0)::BIGINT AS latency_bucket_100_500_ms,
            COALESCE(bucketed.latency_bucket_500_1000_ms, 0)::BIGINT AS latency_bucket_500_1000_ms,
            COALESCE(bucketed.latency_bucket_ge_1000_ms, 0)::BIGINT AS latency_bucket_ge_1000_ms
        FROM latest
        LEFT JOIN bucketed USING (source, symbol)
        ORDER BY latest.source, latest.symbol
        ",
    )
    .bind(window_seconds)
    .fetch_all(pool)
    .await?;

    let storage = sqlx::query_as::<_, CollectorStorageSignalRow>(
        r"
        SELECT
            (
                pg_total_relation_size('raw_source_events'::regclass)
                + pg_total_relation_size('liquidation_events'::regclass)
                + pg_total_relation_size('collector_health'::regclass)
            )::BIGINT AS total_bytes,
            pg_total_relation_size('raw_source_events'::regclass)::BIGINT AS raw_source_events_bytes,
            pg_total_relation_size('liquidation_events'::regclass)::BIGINT AS liquidation_events_bytes,
            pg_total_relation_size('collector_health'::regclass)::BIGINT AS collector_health_bytes,
            (
                SELECT COUNT(*)::BIGINT
                FROM raw_source_events
                WHERE received_ts >= NOW() - ($1::BIGINT * INTERVAL '1 second')
            ) AS raw_rows_window,
            (
                SELECT COUNT(*)::BIGINT
                FROM liquidation_events
                WHERE received_ts >= NOW() - ($1::BIGINT * INTERVAL '1 second')
            ) AS canonical_rows_window
        ",
    )
    .bind(window_seconds)
    .fetch_one(pool)
    .await?;

    Ok(CollectorDashboardMetrics {
        window_seconds,
        sources: sources
            .into_iter()
            .map(CollectorSourceMetrics::from)
            .collect(),
        storage: CollectorStorageSignal::from(storage),
    })
}

/// Return dashboard-ready collector history samples.
///
/// # Errors
///
/// Returns an error when Postgres rejects the history query.
pub async fn collector_dashboard_history(
    pool: &PgPool,
    window: MetricsWindow,
) -> Result<CollectorDashboardHistory, sqlx::Error> {
    let window_seconds = window.seconds().max(1);
    let samples = sqlx::query_as::<_, CollectorHistorySampleRow>(
        r"
        SELECT
            source,
            symbol,
            checked_at,
            status,
            CASE
                WHEN last_payload_ts IS NULL THEN NULL
                ELSE (EXTRACT(EPOCH FROM (NOW() - last_payload_ts)) * 1000)::BIGINT
            END AS freshness_ms,
            last_latency_ms,
            reconnects_5m,
            messages_received,
            normalized_events
        FROM collector_health
        WHERE checked_at >= NOW() - ($1::BIGINT * INTERVAL '1 second')
        ORDER BY source, symbol, checked_at
        ",
    )
    .bind(window_seconds)
    .fetch_all(pool)
    .await?;

    Ok(CollectorDashboardHistory {
        window_seconds,
        samples: samples
            .into_iter()
            .map(CollectorHistorySample::from)
            .collect(),
    })
}

/// Return source coverage overlap for a primary and diagnostic source.
///
/// This is not event deduplication: different venues can liquidate correlated
/// positions at similar times, and those remain distinct events. The report is
/// a coverage/readiness diagnostic over the same time window.
///
/// # Errors
///
/// Returns an error when Postgres rejects one of the report queries.
pub async fn source_overlap_report(
    pool: &PgPool,
    primary_source: &str,
    diagnostic_source: &str,
    window: MetricsWindow,
    bucket_seconds: i64,
) -> Result<SourceOverlapReport, sqlx::Error> {
    let window_seconds = window.seconds().max(1);
    let bucket_seconds = bucket_seconds.max(1);
    let primary = source_overlap_summary(pool, primary_source, window_seconds).await?;
    let diagnostic = source_overlap_summary(pool, diagnostic_source, window_seconds).await?;
    let buckets = source_overlap_buckets(
        pool,
        primary_source,
        diagnostic_source,
        window_seconds,
        bucket_seconds,
    )
    .await?;

    Ok(SourceOverlapReport {
        window_seconds,
        bucket_seconds,
        primary,
        diagnostic,
        buckets,
    })
}

async fn source_overlap_summary(
    pool: &PgPool,
    source: &str,
    window_seconds: i64,
) -> Result<SourceOverlapSummary, sqlx::Error> {
    let row = sqlx::query_as::<_, SourceOverlapSummaryRow>(
        r"
        WITH latest AS (
            SELECT
                status,
                last_payload_ts,
                last_event_ts,
                messages_received,
                normalized_events,
                raw_inserted,
                canonical_inserted
            FROM collector_health
            WHERE source = $1
              AND checked_at >= NOW() - ($2::BIGINT * INTERVAL '1 second')
            ORDER BY checked_at DESC
            LIMIT 1
        ),
        symbols AS (
            SELECT symbol
            FROM collector_health
            WHERE source = $1
              AND checked_at >= NOW() - ($2::BIGINT * INTERVAL '1 second')
            UNION
            SELECT symbol
            FROM raw_source_events
            WHERE source = $1
              AND received_ts >= NOW() - ($2::BIGINT * INTERVAL '1 second')
            UNION
            SELECT symbol
            FROM liquidation_events
            WHERE source = $1
              AND received_ts >= NOW() - ($2::BIGINT * INTERVAL '1 second')
        )
        SELECT
            $1::TEXT AS source,
            COALESCE((SELECT string_agg(symbol, ',' ORDER BY symbol) FROM symbols), '') AS symbols_csv,
            (SELECT status FROM latest) AS latest_status,
            (SELECT last_payload_ts FROM latest) AS last_payload_ts,
            (SELECT last_event_ts FROM latest) AS last_event_ts,
            (
                SELECT COUNT(*)::BIGINT
                FROM collector_health
                WHERE source = $1
                  AND checked_at >= NOW() - ($2::BIGINT * INTERVAL '1 second')
            ) AS health_rows,
            (
                SELECT COUNT(*)::BIGINT
                FROM raw_source_events
                WHERE source = $1
                  AND received_ts >= NOW() - ($2::BIGINT * INTERVAL '1 second')
            ) AS raw_events,
            (
                SELECT COUNT(*)::BIGINT
                FROM liquidation_events
                WHERE source = $1
                  AND received_ts >= NOW() - ($2::BIGINT * INTERVAL '1 second')
            ) AS canonical_events,
            COALESCE((SELECT messages_received FROM latest), 0)::BIGINT AS messages_received,
            COALESCE((SELECT normalized_events FROM latest), 0)::BIGINT AS normalized_events,
            COALESCE((SELECT raw_inserted FROM latest), 0)::BIGINT AS raw_inserted,
            COALESCE((SELECT canonical_inserted FROM latest), 0)::BIGINT AS canonical_inserted
        ",
    )
    .bind(source)
    .bind(window_seconds)
    .fetch_one(pool)
    .await?;

    Ok(SourceOverlapSummary::from(row))
}

async fn source_overlap_buckets(
    pool: &PgPool,
    primary_source: &str,
    diagnostic_source: &str,
    window_seconds: i64,
    bucket_seconds: i64,
) -> Result<Vec<SourceOverlapBucket>, sqlx::Error> {
    let rows = sqlx::query_as::<_, SourceOverlapBucketRow>(
        r"
        WITH raw_counts AS (
            SELECT
                source,
                to_timestamp(floor(extract(epoch FROM received_ts) / $4::BIGINT) * $4::BIGINT) AS bucket_start,
                COUNT(*)::BIGINT AS event_count
            FROM raw_source_events
            WHERE source IN ($1, $2)
              AND received_ts >= NOW() - ($3::BIGINT * INTERVAL '1 second')
            GROUP BY source, bucket_start
        ),
        canonical_counts AS (
            SELECT
                source,
                to_timestamp(floor(extract(epoch FROM received_ts) / $4::BIGINT) * $4::BIGINT) AS bucket_start,
                COUNT(*)::BIGINT AS event_count
            FROM liquidation_events
            WHERE source IN ($1, $2)
              AND received_ts >= NOW() - ($3::BIGINT * INTERVAL '1 second')
            GROUP BY source, bucket_start
        ),
        buckets AS (
            SELECT bucket_start FROM raw_counts
            UNION
            SELECT bucket_start FROM canonical_counts
        )
        SELECT
            buckets.bucket_start,
            COALESCE(SUM(raw_counts.event_count) FILTER (WHERE raw_counts.source = $1), 0)::BIGINT
                AS primary_raw_events,
            COALESCE(SUM(canonical_counts.event_count) FILTER (WHERE canonical_counts.source = $1), 0)::BIGINT
                AS primary_canonical_events,
            COALESCE(SUM(raw_counts.event_count) FILTER (WHERE raw_counts.source = $2), 0)::BIGINT
                AS diagnostic_raw_events,
            COALESCE(SUM(canonical_counts.event_count) FILTER (WHERE canonical_counts.source = $2), 0)::BIGINT
                AS diagnostic_canonical_events
        FROM buckets
        LEFT JOIN raw_counts USING (bucket_start)
        LEFT JOIN canonical_counts USING (bucket_start)
        GROUP BY buckets.bucket_start
        ORDER BY buckets.bucket_start
        ",
    )
    .bind(primary_source)
    .bind(diagnostic_source)
    .bind(window_seconds)
    .bind(bucket_seconds)
    .fetch_all(pool)
    .await?;

    Ok(rows.into_iter().map(SourceOverlapBucket::from).collect())
}

#[derive(sqlx::FromRow)]
struct CollectorHealthRow {
    source: String,
    symbol: String,
    status: String,
    reconnects_5m: i32,
    last_event_ts: Option<time::OffsetDateTime>,
    last_payload_ts: Option<time::OffsetDateTime>,
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
            last_payload_ts: row.last_payload_ts,
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

#[derive(sqlx::FromRow)]
struct CollectorSourceMetricsRow {
    source: String,
    symbol: String,
    status: String,
    checked_at: OffsetDateTime,
    last_payload_ts: Option<OffsetDateTime>,
    last_event_ts: Option<OffsetDateTime>,
    freshness_ms: Option<i64>,
    messages_received: i64,
    normalized_events: i64,
    raw_inserted: i64,
    canonical_inserted: i64,
    reconnects_5m: i32,
    max_reconnects_5m: i32,
    latency_bucket_lt_100_ms: i64,
    latency_bucket_100_500_ms: i64,
    latency_bucket_500_1000_ms: i64,
    latency_bucket_ge_1000_ms: i64,
}

impl From<CollectorSourceMetricsRow> for CollectorSourceMetrics {
    fn from(row: CollectorSourceMetricsRow) -> Self {
        let policy = SourcePolicy::from_source(&row.source);
        Self {
            source: row.source,
            symbol: row.symbol,
            source_quality: policy.source_quality.to_owned(),
            coverage_role: policy.coverage_role.to_owned(),
            participates_in_signals: policy.participates_in_signals,
            status: row.status,
            checked_at: row.checked_at,
            last_payload_ts: row.last_payload_ts,
            last_event_ts: row.last_event_ts,
            freshness_ms: row.freshness_ms,
            messages_received: row.messages_received,
            normalized_events: row.normalized_events,
            raw_inserted: row.raw_inserted,
            canonical_inserted: row.canonical_inserted,
            reconnects_5m: row.reconnects_5m,
            max_reconnects_5m: row.max_reconnects_5m,
            latency_bucket_lt_100_ms: row.latency_bucket_lt_100_ms,
            latency_bucket_100_500_ms: row.latency_bucket_100_500_ms,
            latency_bucket_500_1000_ms: row.latency_bucket_500_1000_ms,
            latency_bucket_ge_1000_ms: row.latency_bucket_ge_1000_ms,
        }
    }
}

#[derive(sqlx::FromRow)]
struct CollectorHistorySampleRow {
    source: String,
    symbol: String,
    checked_at: OffsetDateTime,
    status: String,
    freshness_ms: Option<i64>,
    last_latency_ms: Option<i64>,
    reconnects_5m: i32,
    messages_received: i64,
    normalized_events: i64,
}

impl From<CollectorHistorySampleRow> for CollectorHistorySample {
    fn from(row: CollectorHistorySampleRow) -> Self {
        Self {
            source: row.source,
            symbol: row.symbol,
            checked_at: row.checked_at,
            status: row.status,
            freshness_ms: row.freshness_ms,
            last_latency_ms: row.last_latency_ms,
            reconnects_5m: row.reconnects_5m,
            messages_received: row.messages_received,
            normalized_events: row.normalized_events,
        }
    }
}

#[derive(sqlx::FromRow)]
struct CollectorStorageSignalRow {
    total_bytes: i64,
    raw_source_events_bytes: i64,
    liquidation_events_bytes: i64,
    collector_health_bytes: i64,
    raw_rows_window: i64,
    canonical_rows_window: i64,
}

impl From<CollectorStorageSignalRow> for CollectorStorageSignal {
    fn from(row: CollectorStorageSignalRow) -> Self {
        Self {
            total_bytes: row.total_bytes,
            raw_source_events_bytes: row.raw_source_events_bytes,
            liquidation_events_bytes: row.liquidation_events_bytes,
            collector_health_bytes: row.collector_health_bytes,
            raw_rows_window: row.raw_rows_window,
            canonical_rows_window: row.canonical_rows_window,
        }
    }
}

#[derive(sqlx::FromRow)]
struct SourceOverlapSummaryRow {
    source: String,
    symbols_csv: String,
    latest_status: Option<String>,
    last_payload_ts: Option<OffsetDateTime>,
    last_event_ts: Option<OffsetDateTime>,
    health_rows: i64,
    raw_events: i64,
    canonical_events: i64,
    messages_received: i64,
    normalized_events: i64,
    raw_inserted: i64,
    canonical_inserted: i64,
}

impl From<SourceOverlapSummaryRow> for SourceOverlapSummary {
    fn from(row: SourceOverlapSummaryRow) -> Self {
        Self {
            source: row.source,
            symbols: split_symbols_csv(&row.symbols_csv),
            latest_status: row.latest_status,
            last_payload_ts: row.last_payload_ts,
            last_event_ts: row.last_event_ts,
            health_rows: row.health_rows,
            raw_events: row.raw_events,
            canonical_events: row.canonical_events,
            messages_received: row.messages_received,
            normalized_events: row.normalized_events,
            raw_inserted: row.raw_inserted,
            canonical_inserted: row.canonical_inserted,
        }
    }
}

#[derive(sqlx::FromRow)]
struct SourceOverlapBucketRow {
    bucket_start: OffsetDateTime,
    primary_raw_events: i64,
    primary_canonical_events: i64,
    diagnostic_raw_events: i64,
    diagnostic_canonical_events: i64,
}

impl From<SourceOverlapBucketRow> for SourceOverlapBucket {
    fn from(row: SourceOverlapBucketRow) -> Self {
        Self {
            bucket_start: row.bucket_start,
            primary_raw_events: row.primary_raw_events,
            primary_canonical_events: row.primary_canonical_events,
            diagnostic_raw_events: row.diagnostic_raw_events,
            diagnostic_canonical_events: row.diagnostic_canonical_events,
        }
    }
}

fn split_symbols_csv(symbols: &str) -> Vec<String> {
    if symbols.is_empty() {
        return Vec::new();
    }

    symbols.split(',').map(str::to_owned).collect()
}

fn source_as_str(source: Source) -> &'static str {
    source.as_str()
}

fn source_quality_as_str(source_quality: SourceQuality) -> &'static str {
    match source_quality {
        SourceQuality::AllEvents => "all_events",
        SourceQuality::SnapshotOnly => "snapshot_only",
        SourceQuality::Derived => "derived",
        SourceQuality::WebsocketOnly => "websocket_only",
    }
}

struct SourcePolicy {
    source_quality: &'static str,
    coverage_role: &'static str,
    participates_in_signals: bool,
}

impl SourcePolicy {
    fn from_source(source: &str) -> Self {
        match source {
            "bybit" => Self {
                source_quality: "all_events",
                coverage_role: "strategy_primary",
                participates_in_signals: true,
            },
            "binance" => Self {
                source_quality: "snapshot_only",
                coverage_role: "diagnostic_only",
                participates_in_signals: false,
            },
            "okx" => Self {
                source_quality: "websocket_only",
                coverage_role: "diagnostic_only",
                participates_in_signals: false,
            },
            _ => Self {
                source_quality: "unknown",
                coverage_role: "diagnostic_only",
                participates_in_signals: false,
            },
        }
    }
}

fn liquidation_side_as_str(side: LiquidationSide) -> &'static str {
    match side {
        LiquidationSide::Long => "long",
        LiquidationSide::Short => "short",
    }
}
