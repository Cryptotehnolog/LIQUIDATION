//! Ignored recorder load checks for scheduled CI.

use liq_domain::{LiquidationEvent, LiquidationSide, Source, SourceQuality};
use liq_recorder::{migrations, records::RawSourceEvent, repository};
use rust_decimal::Decimal;
use serde_json::json;
use sqlx::postgres::PgPoolOptions;
use time::OffsetDateTime;
use uuid::Uuid;

#[test]
#[ignore = "scheduled heavy test; requires DATABASE_URL"]
fn burst_insert_raw_and_canonical_events() {
    let Ok(database_url) = std::env::var("DATABASE_URL") else {
        eprintln!("skipping recorder load test: DATABASE_URL is not set");
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

        let suffix = unique_suffix();
        let exchange_ts =
            OffsetDateTime::from_unix_timestamp(1_718_750_000).expect("fixture timestamp");
        let received_ts = exchange_ts + time::Duration::milliseconds(200);
        let mut raw_events = Vec::with_capacity(1_000);
        let mut canonical_events = Vec::with_capacity(1_000);

        for index in 0..1_000 {
            let source_event_id = format!("bybit:load:{suffix}:{index}");
            raw_events.push(RawSourceEvent {
                source: "bybit".to_owned(),
                source_event_id: source_event_id.clone(),
                source_quality: "all_events".to_owned(),
                symbol: "BTCUSDT".to_owned(),
                exchange_ts,
                received_ts,
                payload: json!({"load": suffix, "index": index}),
                payload_sha256: format!("{index:064x}"),
            });
            canonical_events.push(LiquidationEvent {
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
            });
        }

        let raw_inserted = repository::insert_raw_source_events(&pool, &raw_events)
            .await
            .expect("raw batch insert must succeed");
        let canonical_inserted = repository::insert_liquidation_events(&pool, &canonical_events)
            .await
            .expect("canonical batch insert must succeed");

        assert_eq!(raw_inserted, 1_000);
        assert_eq!(canonical_inserted, 1_000);
    });
}

fn unique_suffix() -> String {
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .expect("system time must be after unix epoch")
        .as_nanos();
    format!("{}-{nanos}", std::process::id())
}
