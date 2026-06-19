# Rust Data Stack Research

Дата проверки: 2026-06-19.

## Что проверяли

- WebSocket crate direction.
- TimescaleDB/Postgres access.
- Parquet/Arrow archive.
- Load/reliability testing.
- Recent community signals через `last30days`.

## `last30days` result

Raw output:
[rust-websocket-parquet-timescaledb-crypto-market-data-pipeline-raw-rust-data-stack.md](raw/rust-websocket-parquet-timescaledb-crypto-market-data-pipeline-raw-rust-data-stack.md)

Community results were broad Rust activity, not directly market-data pipeline
specific. Useful signal: Rust ecosystem remains active, but current social layer
did not provide strong evidence for choosing specialized collector crates.

## Official/ecosystem findings

Sources:
[tokio-tungstenite docs](https://docs.rs/tokio-tungstenite),
[tokio-tungstenite crate](https://crates.io/crates/tokio-tungstenite),
[sqlx docs](https://docs.rs/sqlx/latest/sqlx/),
[sqlx CLI README](https://github.com/launchbadge/sqlx/blob/main/sqlx-cli/README.md),
[parquet crate](https://docs.rs/parquet),
[Apache Arrow Rust](https://github.com/apache/arrow-rs),
[TimescaleDB/TigerData](https://www.tigerdata.com/).

`tokio-tungstenite` is the conservative WebSocket choice for Tokio-based async
collectors. It integrates with Tokio streams/sinks and keeps us close to the
Rust async ecosystem.

`sqlx` is suitable for Postgres/TimescaleDB access and migrations. TimescaleDB is
Postgres-compatible, so the Postgres driver path is straightforward.

`parquet` is the official native Rust implementation from Apache Arrow. Use it
for archive writer/reader instead of inventing a custom cold-storage format.

TimescaleDB remains suitable for hot time-series storage, but archive verification
and retention gates are still mandatory.

## Design impact

- MVP Rust stack should use:
  - `tokio`;
  - `tokio-tungstenite`;
  - `sqlx` with Postgres;
  - `rust_decimal` or fixed decimal newtypes for money/notional;
  - `parquet`/`arrow-rs` for cold archive;
  - `tracing` for structured logs.
- Do not adopt a generic exchange library as the core collector abstraction if it
  hides source-specific liquidation semantics.
- Load tests must focus on reconnect, backpressure, bounded channels and DB
  restart behavior.

## Что улучшить или автоматизировать

- Add crate decision record before implementation.
- Add synthetic WebSocket source in `liq-test-utils`.
- Add long-running load test outside normal PR CI.
- Add archive readback test with row count, schema version and checksum.
