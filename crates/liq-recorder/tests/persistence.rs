//! Recorder persistence integration tests.

use liq_domain::{
    LiquidationEvent, LiquidationSide, MarketQuote, MarketTrade, MarketVenue, Source,
    SourceQuality, TradeSide,
};
use liq_recorder::{
    migrations,
    records::{CollectorHealthRecord, PolymarketMarketRecord, RawSourceEvent},
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

        let later_health = CollectorHealthRecord {
            checked_at: received_ts + time::Duration::seconds(2),
            messages_received: 3,
            normalized_events: 2,
            raw_inserted: 2,
            canonical_inserted: 2,
            last_latency_ms: Some(750),
            max_latency_ms: 750,
            ..health.clone()
        };
        let inserted = repository::insert_collector_health(&pool, &later_health)
            .await
            .expect("second collector health insert must succeed");
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
        assert_eq!(persisted, (3, 2, Some(750), 750));

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
            && row.source_quality == "all_events"
            && row.coverage_role == "strategy_primary"
            && row.participates_in_signals
            && row.last_payload_ts.is_some()
            && row.freshness_ms.is_some()
            && row.latency_bucket_lt_100_ms == 0
            && row.latency_bucket_100_500_ms >= 1
            && row.max_reconnects_5m >= 1));
        assert!(dashboard.storage.total_bytes > 0);
        assert!(dashboard.storage.raw_rows_window >= 1);

        let history =
            repository::collector_dashboard_history(&pool, repository::MetricsWindow::minutes(60))
                .await
                .expect("collector dashboard history must be queryable");
        assert!(history.window_seconds > 0);
        assert!(history.samples.iter().any(|row| row.source == "bybit"
            && row.symbol == health.symbol
            && row.last_latency_ms == Some(750)
            && row.messages_received == 3));

        let okx_raw = RawSourceEvent {
            source: "okx".to_owned(),
            source_event_id: format!("okx:test:{suffix}"),
            source_quality: "websocket_only".to_owned(),
            symbol: "BTC-USDT-SWAP".to_owned(),
            exchange_ts,
            received_ts,
            payload: json!({"fixture": suffix, "source": "okx"}),
            payload_sha256: "2".repeat(64),
        };
        let inserted = repository::insert_raw_source_event(&pool, &okx_raw)
            .await
            .expect("okx raw event insert must succeed");
        assert_eq!(inserted, 1);

        let okx_health = CollectorHealthRecord {
            source: "okx".to_owned(),
            symbol: "BTC-USDT-SWAP".to_owned(),
            status: "ok".to_owned(),
            reconnects_5m: 0,
            last_payload_ts: Some(received_ts),
            last_event_ts: None,
            checked_at: received_ts + time::Duration::seconds(3),
            messages_received: 1,
            normalized_events: 0,
            raw_inserted: 1,
            canonical_inserted: 0,
            last_latency_ms: None,
            max_latency_ms: 0,
        };
        let inserted = repository::insert_collector_health(&pool, &okx_health)
            .await
            .expect("okx health insert must succeed");
        assert_eq!(inserted, 1);

        let bitget_exchange_ts = exchange_ts + time::Duration::minutes(2);
        let bitget_received_ts = received_ts + time::Duration::minutes(2);
        let bitget_source_event_id = format!("bitget:test:{suffix}");
        let bitget_raw = RawSourceEvent {
            source: "bitget".to_owned(),
            source_event_id: bitget_source_event_id.clone(),
            source_quality: "snapshot_only".to_owned(),
            symbol: "BTCUSDT".to_owned(),
            exchange_ts: bitget_exchange_ts,
            received_ts: bitget_received_ts,
            payload: json!({"fixture": suffix, "source": "bitget"}),
            payload_sha256: "3".repeat(64),
        };
        let inserted = repository::insert_raw_source_event(&pool, &bitget_raw)
            .await
            .expect("bitget raw event insert must succeed");
        assert_eq!(inserted, 1);

        let bitget_canonical = LiquidationEvent {
            event_id: Uuid::new_v5(&Uuid::NAMESPACE_URL, bitget_source_event_id.as_bytes()),
            source: Source::Bitget,
            source_event_id: bitget_source_event_id,
            source_quality: SourceQuality::SnapshotOnly,
            symbol: "BTCUSDT".to_owned(),
            side: LiquidationSide::Long,
            price: Decimal::new(5_000_000, 2),
            quantity: Decimal::new(5, 1),
            notional_usd: Decimal::new(25_000, 0),
            exchange_ts: bitget_exchange_ts,
            received_ts: bitget_received_ts,
        };
        let inserted = repository::insert_liquidation_event(&pool, &bitget_canonical)
            .await
            .expect("bitget canonical event insert must succeed");
        assert_eq!(inserted, 1);

        let overlap = repository::source_overlap_report(
            &pool,
            "bybit",
            "okx",
            repository::MetricsWindow::minutes(60),
            60,
        )
        .await
        .expect("source overlap report must be queryable");
        assert_eq!(overlap.primary.source, "bybit");
        assert_eq!(overlap.diagnostic.source, "okx");
        assert!(overlap.primary.canonical_events >= 1);
        assert!(overlap.diagnostic.raw_events >= 1);
        assert_eq!(overlap.diagnostic.canonical_events, 0);
        assert!(overlap.buckets.iter().any(
            |bucket| bucket.primary_canonical_events >= 1 && bucket.diagnostic_raw_events >= 1
        ));

        let usefulness = repository::source_usefulness_report(
            &pool,
            "bybit",
            repository::MetricsWindow::minutes(60),
            60,
            time::Duration::seconds(120),
        )
        .await
        .expect("source usefulness report must be queryable");
        assert_eq!(usefulness.primary_source, "bybit");
        let bybit_usefulness = usefulness
            .sources
            .iter()
            .find(|row| row.source == "bybit")
            .expect("bybit usefulness row must exist");
        assert_eq!(bybit_usefulness.coverage_role, "strategy_primary");
        assert!(bybit_usefulness.participates_in_signals);
        assert!(bybit_usefulness.raw_events >= 2);
        assert!(bybit_usefulness.canonical_events >= 1);
        assert_eq!(
            bybit_usefulness.max_notional_usd,
            Some(Decimal::new(650_000, 2))
        );
        assert_eq!(bybit_usefulness.stale_health_rows, 0);
        assert!(bybit_usefulness.median_latency_ms.is_some());
        assert!(bybit_usefulness.p95_latency_ms.is_some());
        assert!(
            bybit_usefulness.liquidation_ready_buckets_without_primary == 0,
            "primary source should not count as additive diagnostic coverage"
        );

        let okx_usefulness = usefulness
            .sources
            .iter()
            .find(|row| row.source == "okx")
            .expect("okx usefulness row must exist");
        assert_eq!(okx_usefulness.coverage_role, "diagnostic_only");
        assert!(!okx_usefulness.participates_in_signals);
        assert!(okx_usefulness.raw_events >= 1);

        let bitget_usefulness = usefulness
            .sources
            .iter()
            .find(|row| row.source == "bitget")
            .expect("bitget usefulness row must exist");
        assert_eq!(bitget_usefulness.coverage_role, "diagnostic_only");
        assert!(!bitget_usefulness.participates_in_signals);
        assert!(bitget_usefulness.raw_events >= 1);
        assert!(bitget_usefulness.canonical_events >= 1);
        assert!(
            bitget_usefulness
                .max_notional_usd
                .is_some_and(|value| value >= Decimal::new(25_000, 0))
        );
        assert!(bitget_usefulness.liquidation_ready_buckets_without_primary >= 1);

        let quote_source_event_id = format!("polymarket:quote:{suffix}");
        let quote = MarketQuote {
            event_id: Uuid::new_v5(&Uuid::NAMESPACE_URL, quote_source_event_id.as_bytes()),
            venue: MarketVenue::Polymarket,
            source_event_id: quote_source_event_id,
            instrument_id: "pm-token-up".to_owned(),
            symbol: "btc-up-jun-2026".to_owned(),
            best_bid: Some(Decimal::new(49, 2)),
            best_bid_size: Some(Decimal::new(100, 0)),
            best_ask: Some(Decimal::new(51, 2)),
            best_ask_size: Some(Decimal::new(80, 0)),
            exchange_ts,
            received_ts,
        };
        let inserted = repository::insert_market_quote(&pool, &quote)
            .await
            .expect("market quote insert must succeed");
        assert_eq!(inserted, 1);
        let duplicate = repository::insert_market_quote(&pool, &quote)
            .await
            .expect("duplicate market quote insert must not fail");
        assert_eq!(duplicate, 0);

        let pm_trade_source_event_id = format!("polymarket:trade:{suffix}");
        let pm_trade = MarketTrade {
            event_id: Uuid::new_v5(&Uuid::NAMESPACE_URL, pm_trade_source_event_id.as_bytes()),
            venue: MarketVenue::Polymarket,
            source_event_id: pm_trade_source_event_id,
            instrument_id: "pm-token-up".to_owned(),
            symbol: "btc-up-jun-2026".to_owned(),
            side: TradeSide::Buy,
            price: Decimal::new(50, 2),
            quantity: Decimal::new(20, 0),
            notional_usd: Some(Decimal::new(10, 0)),
            exchange_ts,
            received_ts,
        };
        let inserted = repository::insert_market_trade(&pool, &pm_trade)
            .await
            .expect("polymarket market trade insert must succeed");
        assert_eq!(inserted, 1);

        let hyper_quote_source_event_id = format!("hyperliquid:quote:{suffix}");
        let hyper_quote = MarketQuote {
            event_id: Uuid::new_v5(&Uuid::NAMESPACE_URL, hyper_quote_source_event_id.as_bytes()),
            venue: MarketVenue::Hyperliquid,
            source_event_id: hyper_quote_source_event_id,
            instrument_id: "BTC".to_owned(),
            symbol: "BTC-PERP".to_owned(),
            best_bid: Some(Decimal::new(6_499_000, 2)),
            best_bid_size: Some(Decimal::new(5, 0)),
            best_ask: Some(Decimal::new(6_501_000, 2)),
            best_ask_size: Some(Decimal::new(5, 0)),
            exchange_ts,
            received_ts,
        };
        let inserted = repository::insert_market_quote(&pool, &hyper_quote)
            .await
            .expect("hyperliquid market quote insert must succeed");
        assert_eq!(inserted, 1);

        let trade_source_event_id = format!("hyperliquid:trade:{suffix}");
        let trade = MarketTrade {
            event_id: Uuid::new_v5(&Uuid::NAMESPACE_URL, trade_source_event_id.as_bytes()),
            venue: MarketVenue::Hyperliquid,
            source_event_id: trade_source_event_id,
            instrument_id: "BTC".to_owned(),
            symbol: "BTC-PERP".to_owned(),
            side: TradeSide::Buy,
            price: Decimal::new(6_500_000, 2),
            quantity: Decimal::new(1, 2),
            notional_usd: Some(Decimal::new(65_000, 2)),
            exchange_ts,
            received_ts,
        };
        let inserted = repository::insert_market_trade(&pool, &trade)
            .await
            .expect("market trade insert must succeed");
        assert_eq!(inserted, 1);
        let duplicate = repository::insert_market_trade(&pool, &trade)
            .await
            .expect("duplicate market trade insert must not fail");
        assert_eq!(duplicate, 0);

        let readiness =
            repository::market_data_readiness(&pool, repository::MetricsWindow::minutes(60))
                .await
                .expect("market-data readiness must be queryable");
        assert!(readiness.polymarket_quotes >= 1);
        assert!(readiness.polymarket_trades >= 1);
        assert!(readiness.hyperliquid_quotes >= 1);
        assert!(readiness.hyperliquid_trades >= 1);

        let replay_data = repository::paper_replay_data(
            &pool,
            received_ts - time::Duration::seconds(1),
            received_ts + time::Duration::seconds(1),
        )
        .await
        .expect("paper replay data must be queryable");
        assert!(
            replay_data
                .liquidations
                .iter()
                .any(|row| row.source_event_id == canonical.source_event_id)
        );
        assert!(
            replay_data
                .polymarket_quotes
                .iter()
                .any(|row| row.source_event_id == quote.source_event_id)
        );
        assert!(
            replay_data
                .polymarket_trades
                .iter()
                .any(|row| row.source_event_id == pm_trade.source_event_id)
        );
        assert!(
            replay_data
                .hyperliquid_quotes
                .iter()
                .any(|row| row.source_event_id == hyper_quote.source_event_id)
        );
        assert!(
            replay_data
                .hyperliquid_trades
                .iter()
                .any(|row| row.source_event_id == trade.source_event_id)
        );

        let market = PolymarketMarketRecord {
            market_id: format!("btc-5m-{suffix}"),
            slug: Some(format!("btc-updown-{suffix}")),
            title: Some("BTC Up or Down - 5m fixture".to_owned()),
            base_asset: "BTC".to_owned(),
            market_type: "btc_5m".to_owned(),
            up_token_id: "pm-token-up".to_owned(),
            down_token_id: "pm-token-down".to_owned(),
            start_ts: received_ts - time::Duration::minutes(5),
            end_ts: received_ts,
            status: "closed".to_owned(),
            source: "fixture".to_owned(),
            raw_payload: json!({"fixture": suffix}),
        };
        let inserted = repository::upsert_polymarket_market(&pool, &market)
            .await
            .expect("polymarket market metadata upsert must succeed");
        assert_eq!(inserted, 1);

        let latest = repository::latest_polymarket_market(&pool, "BTC", "btc_5m")
            .await
            .expect("latest market metadata must be queryable")
            .expect("latest market metadata must exist");
        assert_eq!(latest.market_id, market.market_id);
        assert_eq!(latest.up_token_id, "pm-token-up");
        assert_eq!(latest.down_token_id, "pm-token-down");
    });
}

fn unique_suffix() -> String {
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .expect("system time must be after unix epoch")
        .as_nanos();
    format!("{}-{nanos}", std::process::id())
}
