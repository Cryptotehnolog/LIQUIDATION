# Data Foundation and Paper Replay Design

Date: 2026-06-19
Status: Draft for user review

## Purpose

Build the first safe increment for the Liquidation Cascades Meet Prediction
Markets project: a Rust data foundation and paper-only replay system. This
increment must prove that we can collect reliable liquidation and market data,
measure data quality, replay strategy signals, and estimate paper PnL before
any real trading code is allowed.

This is not a live trading bot. No private trading keys, no real orders, and no
automated execution are in scope for this increment.

## Decisions

1. The implementation language is Rust.
2. The first system is data-first, not execution-first.
3. Real trading is blocked until paper trading and replay reports demonstrate
   stable data quality, reproducible signals, and acceptable risk metrics.
4. Exchange connectivity is implemented with direct WebSocket/HTTP adapters
   where practical, not by depending on Moon Dev API as the core source.
5. AI and RAG are control-plane tools only. They may help ingest documentation,
   summarize reports, and review changes, but they must not make trade
   execution decisions.
6. Docker is used for infrastructure and reproducible local services. The Rust
   binaries must also be runnable outside Docker for development.
7. Secrets are stored in Infisical later, but this increment must not require
   production trading secrets.

## What I Am Pushing Back On

Pre-commit hooks are useful, but they are not a security or correctness
boundary. They can be skipped. The reliable gate must be CI: `cargo fmt`,
`cargo clippy`, tests, migrations checks, and secret scanning in GitHub Actions.

TimescaleDB and Parquet should not both be first-class write paths on day one.
The recommended MVP path is TimescaleDB as the primary durable recorder, with
Parquet export added after the schema stabilizes. Dual primary storage too early
will create unnecessary reconciliation problems.

A generic exchange library should not hide liquidation-feed semantics. Binance,
Bybit, OKX, and Hyperliquid do not expose identical liquidation guarantees. The
normalizer must preserve source quality metadata such as snapshot feed, all
liquidations feed, observed latency, and adapter confidence.

## Scope

### In Scope

- Rust workspace skeleton.
- Typed domain model for liquidation events, market quotes, Polymarket market
  metadata, strategy signals, paper orders, and paper fills.
- Exchange/source adapter interface.
- Initial liquidation adapters for Binance USD-M futures and Bybit derivatives,
  because their liquidation feed semantics can be validated from official docs.
- Normalization into canonical liquidation events.
- Durable recording into TimescaleDB via SQL migrations.
- Data-quality jobs and daily reports.
- Paper-only strategy replay harness.
- CI gates for formatting, linting, tests, migrations, and typo checks.
- Development Docker Compose for TimescaleDB and supporting services.

### Out Of Scope

- Real Polymarket order placement.
- Real Hyperliquid hedge placement.
- Mainnet private key handling.
- Production Infisical deployment.
- Full RAG deployment.
- Strategy optimization beyond paper/replay metrics.
- ETH, SOL, and XRP scaling.

## Architecture

The workspace is split into small crates so each piece can be tested without
loading the whole system.

- `liq-domain`: canonical types, enums, IDs, decimal-safe money/quantity types,
  and validation rules.
- `liq-connectors`: exchange/source adapters for liquidation and market data.
- `liq-normalizer`: maps source payloads into canonical events and annotates
  source quality.
- `liq-recorder`: writes normalized data to TimescaleDB and manages migrations.
- `liq-quality`: computes latency, gap, reconnect, duplicate, and anomaly
  metrics.
- `liq-replay`: replays recorded data through the strategy state machine.
- `liq-cli`: operator CLI for running collectors, reports, and replay jobs.

The hot path is:

source WebSocket/HTTP -> connector -> canonical event -> validator -> recorder
-> quality metrics -> replay harness.

The strategy path is deliberately downstream from recorded data. If a signal
cannot be reproduced from durable records, it does not count.

## Data Model

The canonical liquidation event includes:

- `event_id`: deterministic hash over source, symbol, side, quantity, price,
  exchange event time, and raw payload fingerprint.
- `source`: exchange or provider name.
- `instrument`: normalized instrument such as `BTC-USDT-PERP`.
- `base_asset`: `BTC` for the first increment.
- `side`: long-liquidated or short-liquidated, using a project-owned enum.
- `quantity`: decimal quantity in base asset.
- `price`: decimal execution or bankruptcy price, with source price type.
- `notional_usd`: decimal notional when computable.
- `exchange_event_ts`: timestamp from the venue.
- `received_ts`: local UTC capture timestamp.
- `receive_monotonic_ns`: local monotonic capture timestamp used for latency
  and ordering diagnostics.
- `source_sequence`: optional sequence or stream offset when available.
- `source_quality`: all-events, snapshot-only, derived, unknown.
- `raw_payload`: compressed JSON for audit and parser upgrades.

Money and sizes must not use `f64` in domain or database boundaries. Rust
domain types use decimal-safe representations.

## Source Strategy

Phase 1 prioritizes sources that can be validated quickly:

- Binance USD-M futures liquidation stream: useful but snapshot-only for each
  symbol within a 1000 ms interval, so it must not be treated as complete.
- Bybit all-liquidation stream: stronger liquidation coverage and 500 ms push
  frequency according to official docs.
- Polymarket public market WebSocket: needed for paper fills and market state.
  Authenticated user channels are excluded until a separate execution design is
  approved.

OKX and Hyperliquid liquidation adapters are added after their exact official
feed semantics are documented in the repository. If a source cannot be proven
from official docs or observed raw payloads, it is marked experimental and
excluded from strategy signals by default.

## Recorder

TimescaleDB is the primary storage for MVP because the first problem is
time-series queryability, not cheap archival.

Tables:

- `raw_source_events`: immutable raw payload audit trail.
- `liquidation_events`: canonical normalized liquidation events.
- `market_quotes`: Polymarket and futures quote snapshots/events.
- `collector_health`: reconnects, heartbeat gaps, adapter errors, lag.
- `strategy_signals`: replayed or paper-generated signals.
- `paper_orders`: simulated orders.
- `paper_fills`: simulated fills.
- `daily_quality_reports`: materialized daily summaries.

Parquet export is a follow-up once table schemas are stable.

## Paper Replay Harness

Replay must support two modes:

- Historical replay: read recorded events over a time window and replay the
  strategy deterministically.
- Paper-live: consume current recorded events with paper orders only.

The first strategy implementation mirrors the original idea only as a baseline:

- aggregate liquidation notional over a configurable rolling window;
- detect dominant long or short liquidation side;
- apply min/max thresholds;
- compute a pullback bid from observed Polymarket price;
- simulate fill using recorded order book/trade data;
- simulate inverse hedge price using recorded futures data;
- calculate paper PnL, fill rate, hedge slippage, and unhedged exposure time.

Dynamic `PULLBACK_PCT` is not enabled until replay proves the static baseline.
The design should make it pluggable, but not optimize before there is data.

## Data Quality Reports

Daily reports include:

- events by source and symbol;
- duplicate rate;
- missing heartbeat/gap intervals;
- adapter reconnect count;
- exchange event time to local receive latency;
- normalization errors by type;
- unknown-side or unknown-price events;
- source coverage warning, especially snapshot-only feeds;
- paper signal count and skipped-signal reasons.

Reports are generated by CLI and later scheduled by GitHub Actions or a server
cron/systemd timer. They should write Markdown and machine-readable JSON.

## CI And Developer Workflow

Required checks:

- `cargo fmt --check`
- `cargo clippy --workspace --all-targets --all-features -- -D warnings`
- `cargo test --workspace --all-features`
- `sqlx migrate run` against the development database
- `typos`
- secret scanning

Pre-commit hooks may run the same local checks for convenience. CI remains the
source of truth.

`sqlx` is the recommended migration/query layer for the first increment. It is
lighter than Diesel for this use case, works well with async Rust, and supports
compile-time query checking once the database workflow is established.

## Deployment Model

Local development:

- Windows host is acceptable for editing and tests.
- Docker Compose provides TimescaleDB and optional support services.
- Rust binaries run from the host during development.

Server/paper-live:

- Linux VPS or dedicated server.
- systemd or Docker Compose can run collectors.
- Infisical is introduced before any private keys or authenticated trading
  credentials are needed.

Production live trading is intentionally excluded.

## RAG And Agents

RAG is useful but not blocking for the first collector/replay increment.

Recommended path:

- Start with LightRAG for a lightweight documentation/research knowledge base.
- Ingest official exchange docs, architecture docs, runbooks, incident reports,
  replay reports, and strategy notes.
- Add automatic quality checks for retrieval using known question/answer pairs.
- Re-evaluate ApeRAG if we need a heavier RAG portal, MCP-first workflows, or
  built-in multi-user management.

Allowed agents:

- Documentation ingestion agent.
- Data-quality report analyst.
- Backtest/replay analyst.
- Risk review assistant.
- Release/runbook assistant.

Disallowed in this stage:

- Autonomous trade execution agent.
- Agent that changes risk limits without explicit human approval.

## Acceptance Criteria

The first increment is complete when:

- the Rust workspace builds and passes CI;
- migrations create the required TimescaleDB schema;
- at least two liquidation sources can be collected and normalized;
- raw payloads and canonical events are persisted durably;
- quality reports run over a recorded time window;
- replay produces deterministic paper signals from stored data;
- all generated paper orders/fills are clearly marked as simulated;
- no production trading secret is required or accepted by default.

## Next Improvements To Automate

- Nightly data-quality report generation.
- Automatic source-feed regression tests from captured raw payload fixtures.
- RAG ingestion of official docs and generated reports.
- Parquet export after schema stabilization.
- Alerting for collector downtime, feed gaps, and abnormal source divergence.
