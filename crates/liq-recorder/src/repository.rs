//! Postgres persistence operations.

use liq_domain::{
    LiquidationEvent, LiquidationSide, MarketQuote, MarketTrade, MarketVenue, Source,
    SourceQuality, TradeSide,
};
use sqlx::{PgPool, QueryBuilder};
use time::OffsetDateTime;

use crate::records::{
    CollectorDashboardHistory, CollectorDashboardMetrics, CollectorHealthRecord,
    CollectorHistorySample, CollectorSourceMetrics, CollectorStorageSignal,
    MarketDataReadinessRecord, PaperReplayDataRecord, PolymarketMarketRecord, RawSourceEvent,
    SourceOverlapBucket, SourceOverlapReport, SourceOverlapSummary, SourceUsefulnessReport,
    SourceUsefulnessSummary,
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

const SOURCE_USEFULNESS_REPORT_SQL: &str = r"
WITH sources AS (
    SELECT source
    FROM collector_health
    WHERE checked_at >= NOW() - ($2::BIGINT * INTERVAL '1 second')
    UNION
    SELECT source
    FROM raw_source_events
    WHERE received_ts >= NOW() - ($2::BIGINT * INTERVAL '1 second')
    UNION
    SELECT source
    FROM liquidation_events
    WHERE received_ts >= NOW() - ($2::BIGINT * INTERVAL '1 second')
),
canonical_buckets AS (
    SELECT
        source,
        to_timestamp(floor(extract(epoch FROM received_ts) / $3::BIGINT) * $3::BIGINT) AS bucket_start,
        COUNT(*)::BIGINT AS event_count
    FROM liquidation_events
    WHERE received_ts >= NOW() - ($2::BIGINT * INTERVAL '1 second')
    GROUP BY source, bucket_start
)
SELECT
    s.source,
    COALESCE(
        (
            SELECT string_agg(symbol, ',' ORDER BY symbol)
            FROM (
                SELECT symbol
                FROM collector_health
                WHERE source = s.source
                  AND checked_at >= NOW() - ($2::BIGINT * INTERVAL '1 second')
                UNION
                SELECT symbol
                FROM raw_source_events
                WHERE source = s.source
                  AND received_ts >= NOW() - ($2::BIGINT * INTERVAL '1 second')
                UNION
                SELECT symbol
                FROM liquidation_events
                WHERE source = s.source
                  AND received_ts >= NOW() - ($2::BIGINT * INTERVAL '1 second')
            ) symbols
        ),
        ''
    ) AS symbols_csv,
    (
        SELECT COUNT(*)::BIGINT
        FROM collector_health
        WHERE source = s.source
          AND checked_at >= NOW() - ($2::BIGINT * INTERVAL '1 second')
    ) AS health_rows,
    (
        SELECT COUNT(*)::BIGINT
        FROM raw_source_events
        WHERE source = s.source
          AND received_ts >= NOW() - ($2::BIGINT * INTERVAL '1 second')
    ) AS raw_events,
    (
        SELECT COUNT(*)::BIGINT
        FROM liquidation_events
        WHERE source = s.source
          AND received_ts >= NOW() - ($2::BIGINT * INTERVAL '1 second')
    ) AS canonical_events,
    (
        SELECT MAX(notional_usd)
        FROM liquidation_events
        WHERE source = s.source
          AND received_ts >= NOW() - ($2::BIGINT * INTERVAL '1 second')
    ) AS max_notional_usd,
    (
        SELECT percentile_disc(0.5) WITHIN GROUP (ORDER BY last_latency_ms)::BIGINT
        FROM collector_health
        WHERE source = s.source
          AND checked_at >= NOW() - ($2::BIGINT * INTERVAL '1 second')
          AND last_latency_ms IS NOT NULL
    ) AS median_latency_ms,
    (
        SELECT percentile_disc(0.95) WITHIN GROUP (ORDER BY last_latency_ms)::BIGINT
        FROM collector_health
        WHERE source = s.source
          AND checked_at >= NOW() - ($2::BIGINT * INTERVAL '1 second')
          AND last_latency_ms IS NOT NULL
    ) AS p95_latency_ms,
    (
        SELECT COUNT(*)::BIGINT
        FROM collector_health
        WHERE source = s.source
          AND checked_at >= NOW() - ($2::BIGINT * INTERVAL '1 second')
          AND (
              last_payload_ts IS NULL
              OR checked_at - last_payload_ts > ($4::BIGINT * INTERVAL '1 second')
          )
    ) AS stale_health_rows,
    (
        SELECT COUNT(*)::BIGINT
        FROM canonical_buckets source_bucket
        JOIN canonical_buckets primary_bucket
          ON primary_bucket.bucket_start = source_bucket.bucket_start
         AND primary_bucket.source = $1
        WHERE source_bucket.source = s.source
          AND s.source <> $1
    ) AS overlap_buckets_with_primary,
    (
        SELECT COUNT(*)::BIGINT
        FROM canonical_buckets source_bucket
        LEFT JOIN canonical_buckets primary_bucket
          ON primary_bucket.bucket_start = source_bucket.bucket_start
         AND primary_bucket.source = $1
        WHERE source_bucket.source = s.source
          AND s.source <> $1
          AND primary_bucket.source IS NULL
    ) AS liquidation_ready_buckets_without_primary
FROM sources s
ORDER BY s.source
";

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

/// Insert a canonical market quote.
///
/// Existing `(venue, source_event_id)` rows are left unchanged.
///
/// # Errors
///
/// Returns an error when Postgres rejects the insert.
pub async fn insert_market_quote(pool: &PgPool, quote: &MarketQuote) -> Result<u64, sqlx::Error> {
    let mut tx = pool.begin().await?;
    let key_result = sqlx::query(
        r"
        INSERT INTO market_quote_keys (venue, source_event_id)
        VALUES ($1, $2)
        ON CONFLICT (venue, source_event_id) DO NOTHING
        ",
    )
    .bind(market_venue_as_str(quote.venue))
    .bind(&quote.source_event_id)
    .execute(&mut *tx)
    .await?;

    if key_result.rows_affected() == 0 {
        tx.commit().await?;
        return Ok(0);
    }

    let result = sqlx::query(
        r"
        INSERT INTO market_quotes (
            event_id,
            venue,
            source_event_id,
            instrument_id,
            symbol,
            best_bid,
            best_bid_size,
            best_ask,
            best_ask_size,
            exchange_ts,
            received_ts
        )
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)
        ",
    )
    .bind(quote.event_id)
    .bind(market_venue_as_str(quote.venue))
    .bind(&quote.source_event_id)
    .bind(&quote.instrument_id)
    .bind(&quote.symbol)
    .bind(quote.best_bid)
    .bind(quote.best_bid_size)
    .bind(quote.best_ask)
    .bind(quote.best_ask_size)
    .bind(quote.exchange_ts)
    .bind(quote.received_ts)
    .execute(&mut *tx)
    .await?;

    tx.commit().await?;
    Ok(result.rows_affected())
}

/// Insert several canonical market quotes in one statement.
///
/// Existing `(venue, source_event_id)` rows are left unchanged.
///
/// # Errors
///
/// Returns an error when Postgres rejects the insert.
pub async fn insert_market_quotes(
    pool: &PgPool,
    quotes: &[MarketQuote],
) -> Result<u64, sqlx::Error> {
    if quotes.is_empty() {
        return Ok(0);
    }

    let mut tx = pool.begin().await?;
    let mut accepted = Vec::with_capacity(quotes.len());
    for quote in quotes {
        let key_result = sqlx::query(
            r"
            INSERT INTO market_quote_keys (venue, source_event_id)
            VALUES ($1, $2)
            ON CONFLICT (venue, source_event_id) DO NOTHING
            ",
        )
        .bind(market_venue_as_str(quote.venue))
        .bind(&quote.source_event_id)
        .execute(&mut *tx)
        .await?;

        if key_result.rows_affected() == 1 {
            accepted.push(quote);
        }
    }

    if accepted.is_empty() {
        tx.commit().await?;
        return Ok(0);
    }

    let mut query = QueryBuilder::new(
        r"
        INSERT INTO market_quotes (
            event_id,
            venue,
            source_event_id,
            instrument_id,
            symbol,
            best_bid,
            best_bid_size,
            best_ask,
            best_ask_size,
            exchange_ts,
            received_ts
        )
        ",
    );

    query.push_values(accepted, |mut row, quote| {
        row.push_bind(quote.event_id)
            .push_bind(market_venue_as_str(quote.venue))
            .push_bind(&quote.source_event_id)
            .push_bind(&quote.instrument_id)
            .push_bind(&quote.symbol)
            .push_bind(quote.best_bid)
            .push_bind(quote.best_bid_size)
            .push_bind(quote.best_ask)
            .push_bind(quote.best_ask_size)
            .push_bind(quote.exchange_ts)
            .push_bind(quote.received_ts);
    });

    let result = query.build().execute(&mut *tx).await?;
    tx.commit().await?;
    Ok(result.rows_affected())
}

/// Insert a canonical market trade.
///
/// Existing `(venue, source_event_id)` rows are left unchanged.
///
/// # Errors
///
/// Returns an error when Postgres rejects the insert.
pub async fn insert_market_trade(pool: &PgPool, trade: &MarketTrade) -> Result<u64, sqlx::Error> {
    let mut tx = pool.begin().await?;
    let key_result = sqlx::query(
        r"
        INSERT INTO market_trade_keys (venue, source_event_id)
        VALUES ($1, $2)
        ON CONFLICT (venue, source_event_id) DO NOTHING
        ",
    )
    .bind(market_venue_as_str(trade.venue))
    .bind(&trade.source_event_id)
    .execute(&mut *tx)
    .await?;

    if key_result.rows_affected() == 0 {
        tx.commit().await?;
        return Ok(0);
    }

    let result = sqlx::query(
        r"
        INSERT INTO market_trades (
            event_id,
            venue,
            source_event_id,
            instrument_id,
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
    .bind(trade.event_id)
    .bind(market_venue_as_str(trade.venue))
    .bind(&trade.source_event_id)
    .bind(&trade.instrument_id)
    .bind(&trade.symbol)
    .bind(trade_side_as_str(trade.side))
    .bind(trade.price)
    .bind(trade.quantity)
    .bind(trade.notional_usd)
    .bind(trade.exchange_ts)
    .bind(trade.received_ts)
    .execute(&mut *tx)
    .await?;

    tx.commit().await?;
    Ok(result.rows_affected())
}

/// Insert several canonical market trades in one statement.
///
/// Existing `(venue, source_event_id)` rows are left unchanged.
///
/// # Errors
///
/// Returns an error when Postgres rejects the insert.
pub async fn insert_market_trades(
    pool: &PgPool,
    trades: &[MarketTrade],
) -> Result<u64, sqlx::Error> {
    if trades.is_empty() {
        return Ok(0);
    }

    let mut tx = pool.begin().await?;
    let mut accepted = Vec::with_capacity(trades.len());
    for trade in trades {
        let key_result = sqlx::query(
            r"
            INSERT INTO market_trade_keys (venue, source_event_id)
            VALUES ($1, $2)
            ON CONFLICT (venue, source_event_id) DO NOTHING
            ",
        )
        .bind(market_venue_as_str(trade.venue))
        .bind(&trade.source_event_id)
        .execute(&mut *tx)
        .await?;

        if key_result.rows_affected() == 1 {
            accepted.push(trade);
        }
    }

    if accepted.is_empty() {
        tx.commit().await?;
        return Ok(0);
    }

    let mut query = QueryBuilder::new(
        r"
        INSERT INTO market_trades (
            event_id,
            venue,
            source_event_id,
            instrument_id,
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

    query.push_values(accepted, |mut row, trade| {
        row.push_bind(trade.event_id)
            .push_bind(market_venue_as_str(trade.venue))
            .push_bind(&trade.source_event_id)
            .push_bind(&trade.instrument_id)
            .push_bind(&trade.symbol)
            .push_bind(trade_side_as_str(trade.side))
            .push_bind(trade.price)
            .push_bind(trade.quantity)
            .push_bind(trade.notional_usd)
            .push_bind(trade.exchange_ts)
            .push_bind(trade.received_ts);
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

/// Return a multi-source diagnostic usefulness report.
///
/// This report is read-only: it does not change source policy and does not make
/// diagnostic sources participate in strategy signals.
///
/// # Errors
///
/// Returns an error when Postgres rejects the report query.
pub async fn source_usefulness_report(
    pool: &PgPool,
    primary_source: &str,
    window: MetricsWindow,
    bucket_seconds: i64,
    stale_after: time::Duration,
) -> Result<SourceUsefulnessReport, sqlx::Error> {
    let window_seconds = window.seconds().max(1);
    let bucket_seconds = bucket_seconds.max(1);
    let stale_after_seconds = stale_after.whole_seconds().max(1);
    let rows = sqlx::query_as::<_, SourceUsefulnessSummaryRow>(SOURCE_USEFULNESS_REPORT_SQL)
        .bind(primary_source)
        .bind(window_seconds)
        .bind(bucket_seconds)
        .bind(stale_after_seconds)
        .fetch_all(pool)
        .await?;

    Ok(SourceUsefulnessReport {
        window_seconds,
        bucket_seconds,
        primary_source: primary_source.to_owned(),
        stale_after_seconds,
        sources: rows
            .into_iter()
            .map(|row| SourceUsefulnessSummary::from_row(row, window_seconds))
            .collect(),
    })
}

/// Return market-data evidence for strategy readiness gates.
///
/// # Errors
///
/// Returns an error when Postgres rejects the readiness query.
pub async fn market_data_readiness(
    pool: &PgPool,
    window: MetricsWindow,
) -> Result<MarketDataReadinessRecord, sqlx::Error> {
    let window_seconds = window.seconds().max(1);
    let row = sqlx::query_as::<_, MarketDataReadinessRow>(
        r"
        SELECT
            (
                SELECT COUNT(*)::BIGINT
                FROM market_quotes
                WHERE venue = 'polymarket'
                  AND received_ts >= NOW() - ($1::BIGINT * INTERVAL '1 second')
            ) AS polymarket_quotes,
            (
                SELECT COUNT(*)::BIGINT
                FROM market_trades
                WHERE venue = 'polymarket'
                  AND received_ts >= NOW() - ($1::BIGINT * INTERVAL '1 second')
            ) AS polymarket_trades,
            (
                SELECT COUNT(*)::BIGINT
                FROM market_quotes
                WHERE venue = 'hyperliquid'
                  AND received_ts >= NOW() - ($1::BIGINT * INTERVAL '1 second')
            ) AS hyperliquid_quotes,
            (
                SELECT COUNT(*)::BIGINT
                FROM market_trades
                WHERE venue = 'hyperliquid'
                  AND received_ts >= NOW() - ($1::BIGINT * INTERVAL '1 second')
            ) AS hyperliquid_trades
        ",
    )
    .bind(window_seconds)
    .fetch_one(pool)
    .await?;

    Ok(MarketDataReadinessRecord {
        polymarket_quotes: row.polymarket_quotes,
        polymarket_trades: row.polymarket_trades,
        hyperliquid_quotes: row.hyperliquid_quotes,
        hyperliquid_trades: row.hyperliquid_trades,
    })
}

/// Load all persisted rows needed for one paper replay run.
///
/// # Errors
///
/// Returns an error when Postgres rejects one of the replay queries.
pub async fn paper_replay_data(
    pool: &PgPool,
    start: OffsetDateTime,
    end: OffsetDateTime,
) -> Result<PaperReplayDataRecord, sqlx::Error> {
    let liquidations = sqlx::query_as::<_, LiquidationReplayRow>(
        r"
        SELECT
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
        FROM liquidation_events
        WHERE received_ts >= $1 AND received_ts < $2
        ORDER BY received_ts ASC, source ASC, source_event_id ASC
        ",
    )
    .bind(start)
    .bind(end)
    .fetch_all(pool)
    .await?
    .into_iter()
    .map(LiquidationEvent::try_from)
    .collect::<Result<Vec<_>, _>>()?;

    Ok(PaperReplayDataRecord {
        liquidations,
        polymarket_quotes: market_quotes_for_venue(pool, MarketVenue::Polymarket, start, end)
            .await?,
        polymarket_trades: market_trades_for_venue(pool, MarketVenue::Polymarket, start, end)
            .await?,
        hyperliquid_quotes: market_quotes_for_venue(pool, MarketVenue::Hyperliquid, start, end)
            .await?,
        hyperliquid_trades: market_trades_for_venue(pool, MarketVenue::Hyperliquid, start, end)
            .await?,
    })
}

/// Upsert one Polymarket market metadata record.
///
/// # Errors
///
/// Returns an error when Postgres rejects the upsert.
pub async fn upsert_polymarket_market(
    pool: &PgPool,
    market: &PolymarketMarketRecord,
) -> Result<u64, sqlx::Error> {
    let result = sqlx::query(
        r"
        INSERT INTO polymarket_markets (
            market_id,
            slug,
            title,
            base_asset,
            market_type,
            up_token_id,
            down_token_id,
            start_ts,
            end_ts,
            status,
            source,
            raw_payload
        )
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12)
        ON CONFLICT (market_id) DO UPDATE SET
            slug = EXCLUDED.slug,
            title = EXCLUDED.title,
            base_asset = EXCLUDED.base_asset,
            market_type = EXCLUDED.market_type,
            up_token_id = EXCLUDED.up_token_id,
            down_token_id = EXCLUDED.down_token_id,
            start_ts = EXCLUDED.start_ts,
            end_ts = EXCLUDED.end_ts,
            status = EXCLUDED.status,
            source = EXCLUDED.source,
            raw_payload = EXCLUDED.raw_payload,
            updated_at = now()
        ",
    )
    .bind(&market.market_id)
    .bind(&market.slug)
    .bind(&market.title)
    .bind(&market.base_asset)
    .bind(&market.market_type)
    .bind(&market.up_token_id)
    .bind(&market.down_token_id)
    .bind(market.start_ts)
    .bind(market.end_ts)
    .bind(&market.status)
    .bind(&market.source)
    .bind(&market.raw_payload)
    .execute(pool)
    .await?;

    Ok(result.rows_affected())
}

/// Return the latest known Polymarket market for a base asset and market type.
///
/// # Errors
///
/// Returns an error when Postgres rejects the query.
pub async fn latest_polymarket_market(
    pool: &PgPool,
    base_asset: &str,
    market_type: &str,
) -> Result<Option<PolymarketMarketRecord>, sqlx::Error> {
    sqlx::query_as::<_, PolymarketMarketRow>(
        r"
        SELECT
            market_id,
            slug,
            title,
            base_asset,
            market_type,
            up_token_id,
            down_token_id,
            start_ts,
            end_ts,
            status,
            source,
            raw_payload
        FROM polymarket_markets
        WHERE base_asset = $1 AND market_type = $2
        ORDER BY start_ts DESC, end_ts DESC, market_id ASC
        LIMIT 1
        ",
    )
    .bind(base_asset)
    .bind(market_type)
    .fetch_optional(pool)
    .await
    .map(|row| row.map(PolymarketMarketRecord::from))
}

/// List recent Polymarket markets for a base asset and market type.
///
/// # Errors
///
/// Returns an error when Postgres rejects the query.
pub async fn list_polymarket_markets(
    pool: &PgPool,
    base_asset: &str,
    market_type: &str,
    limit: i64,
) -> Result<Vec<PolymarketMarketRecord>, sqlx::Error> {
    sqlx::query_as::<_, PolymarketMarketRow>(
        r"
        SELECT
            market_id,
            slug,
            title,
            base_asset,
            market_type,
            up_token_id,
            down_token_id,
            start_ts,
            end_ts,
            status,
            source,
            raw_payload
        FROM polymarket_markets
        WHERE base_asset = $1 AND market_type = $2
        ORDER BY start_ts DESC, end_ts DESC, market_id ASC
        LIMIT $3
        ",
    )
    .bind(base_asset)
    .bind(market_type)
    .bind(limit.max(1))
    .fetch_all(pool)
    .await
    .map(|rows| rows.into_iter().map(PolymarketMarketRecord::from).collect())
}

async fn market_quotes_for_venue(
    pool: &PgPool,
    venue: MarketVenue,
    start: OffsetDateTime,
    end: OffsetDateTime,
) -> Result<Vec<MarketQuote>, sqlx::Error> {
    sqlx::query_as::<_, MarketQuoteReplayRow>(
        r"
        SELECT
            event_id,
            venue,
            source_event_id,
            instrument_id,
            symbol,
            best_bid,
            best_bid_size,
            best_ask,
            best_ask_size,
            exchange_ts,
            received_ts
        FROM market_quotes
        WHERE venue = $1 AND received_ts >= $2 AND received_ts < $3
        ORDER BY received_ts ASC, instrument_id ASC, source_event_id ASC
        ",
    )
    .bind(market_venue_as_str(venue))
    .bind(start)
    .bind(end)
    .fetch_all(pool)
    .await
    .and_then(|rows| rows.into_iter().map(MarketQuote::try_from).collect())
}

async fn market_trades_for_venue(
    pool: &PgPool,
    venue: MarketVenue,
    start: OffsetDateTime,
    end: OffsetDateTime,
) -> Result<Vec<MarketTrade>, sqlx::Error> {
    sqlx::query_as::<_, MarketTradeReplayRow>(
        r"
        SELECT
            event_id,
            venue,
            source_event_id,
            instrument_id,
            symbol,
            side,
            price,
            quantity,
            notional_usd,
            exchange_ts,
            received_ts
        FROM market_trades
        WHERE venue = $1 AND received_ts >= $2 AND received_ts < $3
        ORDER BY received_ts ASC, instrument_id ASC, source_event_id ASC
        ",
    )
    .bind(market_venue_as_str(venue))
    .bind(start)
    .bind(end)
    .fetch_all(pool)
    .await
    .and_then(|rows| rows.into_iter().map(MarketTrade::try_from).collect())
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

#[derive(sqlx::FromRow)]
struct SourceUsefulnessSummaryRow {
    source: String,
    symbols_csv: String,
    health_rows: i64,
    raw_events: i64,
    canonical_events: i64,
    max_notional_usd: Option<rust_decimal::Decimal>,
    median_latency_ms: Option<i64>,
    p95_latency_ms: Option<i64>,
    stale_health_rows: i64,
    overlap_buckets_with_primary: i64,
    liquidation_ready_buckets_without_primary: i64,
}

#[derive(sqlx::FromRow)]
struct MarketDataReadinessRow {
    polymarket_quotes: i64,
    polymarket_trades: i64,
    hyperliquid_quotes: i64,
    hyperliquid_trades: i64,
}

#[derive(sqlx::FromRow)]
struct PolymarketMarketRow {
    market_id: String,
    slug: Option<String>,
    title: Option<String>,
    base_asset: String,
    market_type: String,
    up_token_id: String,
    down_token_id: String,
    start_ts: OffsetDateTime,
    end_ts: OffsetDateTime,
    status: String,
    source: String,
    raw_payload: serde_json::Value,
}

impl From<PolymarketMarketRow> for PolymarketMarketRecord {
    fn from(row: PolymarketMarketRow) -> Self {
        Self {
            market_id: row.market_id,
            slug: row.slug,
            title: row.title,
            base_asset: row.base_asset,
            market_type: row.market_type,
            up_token_id: row.up_token_id,
            down_token_id: row.down_token_id,
            start_ts: row.start_ts,
            end_ts: row.end_ts,
            status: row.status,
            source: row.source,
            raw_payload: row.raw_payload,
        }
    }
}

#[derive(sqlx::FromRow)]
struct LiquidationReplayRow {
    event_id: uuid::Uuid,
    source: String,
    source_event_id: String,
    source_quality: String,
    symbol: String,
    side: String,
    price: rust_decimal::Decimal,
    quantity: rust_decimal::Decimal,
    notional_usd: rust_decimal::Decimal,
    exchange_ts: OffsetDateTime,
    received_ts: OffsetDateTime,
}

impl TryFrom<LiquidationReplayRow> for LiquidationEvent {
    type Error = sqlx::Error;

    fn try_from(row: LiquidationReplayRow) -> Result<Self, Self::Error> {
        Ok(Self {
            event_id: row.event_id,
            source: parse_source(&row.source)?,
            source_event_id: row.source_event_id,
            source_quality: parse_source_quality(&row.source_quality)?,
            symbol: row.symbol,
            side: parse_liquidation_side(&row.side)?,
            price: row.price,
            quantity: row.quantity,
            notional_usd: row.notional_usd,
            exchange_ts: row.exchange_ts,
            received_ts: row.received_ts,
        })
    }
}

#[derive(sqlx::FromRow)]
struct MarketQuoteReplayRow {
    event_id: uuid::Uuid,
    venue: String,
    source_event_id: String,
    instrument_id: String,
    symbol: String,
    best_bid: Option<rust_decimal::Decimal>,
    best_bid_size: Option<rust_decimal::Decimal>,
    best_ask: Option<rust_decimal::Decimal>,
    best_ask_size: Option<rust_decimal::Decimal>,
    exchange_ts: OffsetDateTime,
    received_ts: OffsetDateTime,
}

impl TryFrom<MarketQuoteReplayRow> for MarketQuote {
    type Error = sqlx::Error;

    fn try_from(row: MarketQuoteReplayRow) -> Result<Self, Self::Error> {
        Ok(Self {
            event_id: row.event_id,
            venue: parse_market_venue(&row.venue)?,
            source_event_id: row.source_event_id,
            instrument_id: row.instrument_id,
            symbol: row.symbol,
            best_bid: row.best_bid,
            best_bid_size: row.best_bid_size,
            best_ask: row.best_ask,
            best_ask_size: row.best_ask_size,
            exchange_ts: row.exchange_ts,
            received_ts: row.received_ts,
        })
    }
}

#[derive(sqlx::FromRow)]
struct MarketTradeReplayRow {
    event_id: uuid::Uuid,
    venue: String,
    source_event_id: String,
    instrument_id: String,
    symbol: String,
    side: String,
    price: rust_decimal::Decimal,
    quantity: rust_decimal::Decimal,
    notional_usd: Option<rust_decimal::Decimal>,
    exchange_ts: OffsetDateTime,
    received_ts: OffsetDateTime,
}

impl TryFrom<MarketTradeReplayRow> for MarketTrade {
    type Error = sqlx::Error;

    fn try_from(row: MarketTradeReplayRow) -> Result<Self, Self::Error> {
        Ok(Self {
            event_id: row.event_id,
            venue: parse_market_venue(&row.venue)?,
            source_event_id: row.source_event_id,
            instrument_id: row.instrument_id,
            symbol: row.symbol,
            side: parse_trade_side(&row.side)?,
            price: row.price,
            quantity: row.quantity,
            notional_usd: row.notional_usd,
            exchange_ts: row.exchange_ts,
            received_ts: row.received_ts,
        })
    }
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

impl SourceUsefulnessSummary {
    fn from_row(row: SourceUsefulnessSummaryRow, window_seconds: i64) -> Self {
        let policy = SourcePolicy::from_source(&row.source);
        let events_per_hour = per_hour(row.raw_events, window_seconds);
        let canonical_events_per_hour = per_hour(row.canonical_events, window_seconds);
        let stale_rate_bps = rate_bps(row.stale_health_rows, row.health_rows);
        let verdict =
            source_usefulness_verdict(&row, policy.participates_in_signals, stale_rate_bps);
        Self {
            source: row.source,
            symbols: split_symbols_csv(&row.symbols_csv),
            source_quality: policy.source_quality.to_owned(),
            coverage_role: policy.coverage_role.to_owned(),
            participates_in_signals: policy.participates_in_signals,
            health_rows: row.health_rows,
            raw_events: row.raw_events,
            canonical_events: row.canonical_events,
            events_per_hour,
            canonical_events_per_hour,
            max_notional_usd: row.max_notional_usd,
            median_latency_ms: row.median_latency_ms,
            p95_latency_ms: row.p95_latency_ms,
            stale_health_rows: row.stale_health_rows,
            stale_rate_bps,
            overlap_buckets_with_primary: row.overlap_buckets_with_primary,
            liquidation_ready_buckets_without_primary: row
                .liquidation_ready_buckets_without_primary,
            verdict,
        }
    }
}

fn split_symbols_csv(symbols: &str) -> Vec<String> {
    if symbols.is_empty() {
        return Vec::new();
    }

    symbols.split(',').map(str::to_owned).collect()
}

fn per_hour(count: i64, window_seconds: i64) -> rust_decimal::Decimal {
    if window_seconds <= 0 {
        return rust_decimal::Decimal::ZERO;
    }

    rust_decimal::Decimal::from(count) * rust_decimal::Decimal::from(3_600)
        / rust_decimal::Decimal::from(window_seconds)
}

fn rate_bps(numerator: i64, denominator: i64) -> i64 {
    if denominator <= 0 {
        return 0;
    }

    numerator.saturating_mul(10_000) / denominator
}

fn source_usefulness_verdict(
    row: &SourceUsefulnessSummaryRow,
    participates_in_signals: bool,
    stale_rate_bps: i64,
) -> String {
    if row.health_rows == 0 && row.raw_events == 0 && row.canonical_events == 0 {
        return "insufficient-data".to_owned();
    }
    if stale_rate_bps >= 5_000 {
        return "unreliable-stale".to_owned();
    }
    if participates_in_signals {
        return "strategy-primary".to_owned();
    }
    if row.liquidation_ready_buckets_without_primary > 0 {
        return "useful-diagnostic".to_owned();
    }
    if row.canonical_events > 0 {
        return "overlapping-diagnostic".to_owned();
    }
    if row.raw_events > 0 {
        return "raw-only-diagnostic".to_owned();
    }

    "healthy-but-empty".to_owned()
}

fn parse_source(value: &str) -> Result<Source, sqlx::Error> {
    match value {
        "bybit" => Ok(Source::Bybit),
        "binance" => Ok(Source::Binance),
        "okx" => Ok(Source::Okx),
        "bitget" => Ok(Source::Bitget),
        "polymarket" => Ok(Source::Polymarket),
        "hyperliquid" => Ok(Source::Hyperliquid),
        _ => Err(storage_decode_error("source", value)),
    }
}

fn parse_source_quality(value: &str) -> Result<SourceQuality, sqlx::Error> {
    match value {
        "all_events" => Ok(SourceQuality::AllEvents),
        "snapshot_only" => Ok(SourceQuality::SnapshotOnly),
        "derived" => Ok(SourceQuality::Derived),
        "websocket_only" => Ok(SourceQuality::WebsocketOnly),
        _ => Err(storage_decode_error("source_quality", value)),
    }
}

fn parse_liquidation_side(value: &str) -> Result<LiquidationSide, sqlx::Error> {
    match value {
        "long" => Ok(LiquidationSide::Long),
        "short" => Ok(LiquidationSide::Short),
        _ => Err(storage_decode_error("liquidation_side", value)),
    }
}

fn parse_market_venue(value: &str) -> Result<MarketVenue, sqlx::Error> {
    match value {
        "polymarket" => Ok(MarketVenue::Polymarket),
        "hyperliquid" => Ok(MarketVenue::Hyperliquid),
        _ => Err(storage_decode_error("market_venue", value)),
    }
}

fn parse_trade_side(value: &str) -> Result<TradeSide, sqlx::Error> {
    match value {
        "buy" => Ok(TradeSide::Buy),
        "sell" => Ok(TradeSide::Sell),
        "unknown" => Ok(TradeSide::Unknown),
        _ => Err(storage_decode_error("trade_side", value)),
    }
}

fn storage_decode_error(column: &'static str, value: &str) -> sqlx::Error {
    sqlx::Error::ColumnDecode {
        index: column.to_owned(),
        source: Box::new(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            format!("unsupported {column} value '{value}'"),
        )),
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
            "binance" | "bitget" => Self {
                source_quality: "snapshot_only",
                coverage_role: "diagnostic_only",
                participates_in_signals: false,
            },
            "okx" => Self {
                source_quality: "websocket_only",
                coverage_role: "diagnostic_only",
                participates_in_signals: false,
            },
            "polymarket" => Self {
                source_quality: "websocket_only",
                coverage_role: "market_data_leg",
                participates_in_signals: false,
            },
            "hyperliquid" => Self {
                source_quality: "websocket_only",
                coverage_role: "hedge_market_data",
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

fn market_venue_as_str(venue: MarketVenue) -> &'static str {
    venue.as_str()
}

fn trade_side_as_str(side: TradeSide) -> &'static str {
    match side {
        TradeSide::Buy => "buy",
        TradeSide::Sell => "sell",
        TradeSide::Unknown => "unknown",
    }
}
