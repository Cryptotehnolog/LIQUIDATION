//! Recorder persistence integration tests.

use liq_domain::{LiquidationEvent, LiquidationSide, Source, SourceQuality};
use liq_recorder::{migrations, records::RawSourceEvent, repository, schema};
use rust_decimal::Decimal;
use serde_json::json;
use sqlx::postgres::PgPoolOptions;
use time::OffsetDateTime;
use uuid::Uuid;

#[test]
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

        let exchange_ts =
            OffsetDateTime::from_unix_timestamp(1_718_750_000).expect("fixture timestamp");
        let received_ts = exchange_ts + time::Duration::milliseconds(250);
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
    });
}

fn unique_suffix() -> String {
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .expect("system time must be after unix epoch")
        .as_nanos();
    format!("{}-{nanos}", std::process::id())
}
