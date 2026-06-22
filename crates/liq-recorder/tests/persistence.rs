//! Recorder persistence integration tests.

use liq_domain::{LiquidationEvent, LiquidationSide, Source, SourceQuality};
use liq_recorder::{
    migrations,
    records::{CollectorHealthRecord, RawSourceEvent},
    repository, schema,
};
use rust_decimal::Decimal;
use serde_json::json;
use sqlx::postgres::PgPoolOptions;
use time::OffsetDateTime;
use uuid::Uuid;

#[test]
#[allow(clippy::too_many_lines)]
fn persists_raw_and_canonical_events_when_database_url_is_set() {
    let Ok(database_url) = std::env::var("DATABASE_URL") else {
        eprintln!("skipping recorder persistence test: DATABASE_URL is not set");
        return;
    };

    let runtime = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
        .expect("tokio runtime must build");

    runtime.block_on(async {
        let pool = PgPoolOptions::new()
            .max_connections(5)
            .connect(&database_url)
            .await
            .expect("database must be reachable");

        migrations::run(&pool).await.expect("migrations must run");
        migrations::run(&pool)
            .await
            .expect("migrations must be idempotent");

        let violations = schema::assert_schema_contract(&pool)
            .await
            .expect("schema contract query must succeed");
        assert_eq!(violations, Vec::new());

        let received_ts = OffsetDateTime::now_utc();
        let exchange_ts = received_ts - time::Duration::milliseconds(250);
        let suffix = unique_suffix();
        let source_event_id = format!("bybit:test:{suffix}");

        let raw = RawSourceEvent {
            source: "bybit".to_owned(),
            source_event_id: source_event_id.clone(),
            source_quality: "all_events".to_owned(),
            symbol: "BTCUSDT".to_owned(),
            exchange_ts,
            received_ts,
            payload: json!({"fixture": suffix}),
            payload_sha256: "0".repeat(64),
        };

        let inserted = repository::insert_raw_source_event(&pool, &raw)
            .await
            .expect("raw event insert must succeed");
        assert_eq!(inserted, 1);
        let duplicate = repository::insert_raw_source_event(&pool, &raw)
            .await
            .expect("duplicate raw event insert must not fail");
        assert_eq!(duplicate, 0);

        let second_raw = RawSourceEvent {
            source_event_id: format!("bybit:test:{suffix}:second"),
            payload: json!({"fixture": suffix, "sequence": 2}),
            payload_sha256: "1".repeat(64),
            ..raw.clone()
        };
        let batch_inserted =
            repository::insert_raw_source_events(&pool, &[raw.clone(), second_raw.clone()])
                .await
                .expect("raw event batch insert must succeed");
        assert_eq!(batch_inserted, 1);
        let duplicate_batch_inserted = repository::insert_raw_source_events(&pool, &[second_raw])
            .await
            .expect("duplicate raw event batch insert must not fail");
        assert_eq!(duplicate_batch_inserted, 0);

        let canonical = LiquidationEvent {
            event_id: Uuid::new_v5(&Uuid::NAMESPACE_URL, source_event_id.as_bytes()),
            source: Source::Bybit,
            source_event_id,
            source_quality: SourceQuality::AllEvents,
            symbol: "BTCUSDT".to_owned(),
            side: LiquidationSide::Long,
            price: Decimal::new(6_500_000, 2),
            quantity: Decimal::new(100, 3),
            notional_usd: Decimal::new(650_000, 2),
            exchange_ts,
            received_ts,
        };

        let inserted = repository::insert_liquidation_event(&pool, &canonical)
            .await
            .expect("canonical event insert must succeed");
        assert_eq!(inserted, 1);
        let duplicate = repository::insert_liquidation_event(&pool, &canonical)
            .await
            .expect("duplicate canonical event insert must not fail");
        assert_eq!(duplicate, 0);

        let health = CollectorHealthRecord {
            source: "bybit".to_owned(),
            symbol: format!("BTCUSDT-{suffix}"),
            status: "ok".to_owned(),
            reconnects_5m: 1,
            last_payload_ts: Some(received_ts),
            last_event_ts: Some(received_ts),
            checked_at: received_ts + time::Duration::seconds(1),
            messages_received: 2,
            normalized_events: 1,
            raw_inserted: 1,
            canonical_inserted: 1,
            last_latency_ms: Some(250),
            max_latency_ms: 250,
        };
        let inserted = repository::insert_collector_health(&pool, &health)
            .await
            .expect("collector health insert must succeed");
        assert_eq!(inserted, 1);

        let persisted: (i64, i64, Option<i64>, i64) = sqlx::query_as(
            r"
            SELECT messages_received, normalized_events, last_latency_ms, max_latency_ms
            FROM collector_health
            WHERE source = $1 AND symbol = $2
            ORDER BY checked_at DESC
            LIMIT 1
            ",
        )
        .bind("bybit")
        .bind(&health.symbol)
        .fetch_one(&pool)
        .await
        .expect("collector health row must be readable");
        assert_eq!(persisted, (2, 1, Some(250), 250));

        let latest_health = repository::list_collector_health(&pool, Some("bybit"), 500)
            .await
            .expect("collector health rows must be listable");
        assert!(
            latest_health
                .iter()
                .any(|row| row.source == "bybit" && row.symbol == health.symbol)
        );

        let dashboard =
            repository::collector_dashboard_metrics(&pool, repository::MetricsWindow::minutes(60))
                .await
                .expect("collector dashboard metrics must be queryable");
        assert!(dashboard.sources.iter().any(|row| row.source == "bybit"
            && row.symbol == health.symbol
            && row.last_payload_ts.is_some()
            && row.freshness_ms.is_some()
            && row.latency_bucket_lt_100_ms == 0
            && row.latency_bucket_100_500_ms >= 1
            && row.max_reconnects_5m >= 1));
        assert!(dashboard.storage.total_bytes > 0);
        assert!(dashboard.storage.raw_rows_window >= 1);
    });
}

fn unique_suffix() -> String {
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .expect("system time must be after unix epoch")
        .as_nanos();
    format!("{}-{nanos}", std::process::id())
}
