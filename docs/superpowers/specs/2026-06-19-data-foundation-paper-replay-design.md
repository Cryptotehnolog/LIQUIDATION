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

TimescaleDB and Parquet should not both be first-class hot query paths on day
one. The recommended MVP path is TimescaleDB as the primary query recorder for
canonical events, with a simple scheduled Parquet archive for cold raw payloads.
Dual primary query storage too early will create unnecessary reconciliation
problems.

A generic exchange library should not hide liquidation-feed semantics. Binance,
Bybit, OKX, and Hyperliquid do not expose identical liquidation guarantees. The
normalizer must preserve source quality metadata such as snapshot feed, all
liquidations feed, observed latency, and adapter confidence.

Historical REST backfill must not be treated as guaranteed gap recovery. Each
venue must prove that its REST endpoint is public, market-wide, and semantically
equivalent to the WebSocket stream before it can fill collector gaps. For
example, Binance `GET /fapi/v1/forceOrders` is a USER_DATA endpoint for the
authenticated user's force orders, not a public market liquidation history.
OKX `GET /api/v5/public/liquidation-orders` is a public candidate for bounded
backfill, but must be treated as limited recent history. Bybit REST liquidation
history is not considered verified until an official public endpoint is linked
and an automated endpoint probe passes; the named
`/v5/market/liquidation-history` endpoint returned 404 during design review.

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
- Test support utilities for fixtures, mock sources, and replay assertions.
- Mock load tests that stress the collector and recorder above normal event
  rates.
- Benchmark replay strategies used only for comparison against the baseline.
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
- `liq-test-utils`: shared test fixtures, mock event sources, deterministic
  clocks, load generators, and replay assertion helpers.
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
- `notional_usd`: decimal notional. It is required for strategy-eligible
  liquidation events.
- `exchange_event_ts`: timestamp from the venue.
- `received_ts`: local UTC capture timestamp.
- `receive_monotonic_ns`: local monotonic capture timestamp used for latency
  and ordering diagnostics.
- `source_sequence`: optional sequence or stream offset when available.
- `source_quality`: all-events, snapshot-only, derived, unknown.
- `raw_payload`: compressed JSON for audit and parser upgrades.

Money and sizes must not use `f64` in domain or database boundaries. Rust
domain types use decimal-safe representations.

Adapters must compute `notional_usd` from venue data, usually `quantity * price`
when the venue does not provide a notional directly. If price or quantity is
missing, the normalized event is persisted with validation status `invalid` and
an exclusion reason, but it is excluded from strategy aggregation.

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

Backfill adapters are source-specific. They may be added for bootstrap or
diagnostics, but they cannot be used to repair gaps unless the endpoint's
coverage and retention are documented and tested. Backfilled events must carry
their own source quality and ingestion mode.

Cross-source substitution is not backfill. If Bybit WebSocket is down, OKX data
may continue to provide an alternate venue signal, but it must not be used to
fill Bybit gaps or labeled as derived Bybit coverage. Strategy reports must show
which sources were active for each signal window.

Initial backfill policy:

- Binance: disabled for market liquidation recovery because the available
  official force-order REST endpoint is authenticated USER_DATA.
- OKX: allowed as an experimental bounded backfill source after endpoint
  parameters, retention window, and duplication behavior are fixture-tested.
- Bybit: disabled until a current official public REST liquidation-history page
  and endpoint probe are added to the repository.

## Recorder

TimescaleDB is the primary storage for MVP because the first problem is
time-series queryability, not cheap archival.

Tables:

- `raw_source_events`: immutable raw payload audit trail.
- `archive_manifests`: Parquet archive jobs, row counts, time ranges,
  checksums, verification status, retry counts, and alert state.
- `liquidation_events`: canonical normalized liquidation events.
- `market_quotes`: Polymarket and futures quote snapshots/events.
- `collector_health`: reconnects, heartbeat gaps, adapter errors, lag.
- `strategy_signals`: replayed or paper-generated signals.
- `paper_orders`: simulated orders.
- `paper_fills`: simulated fills.
- `replay_runs`: deterministic replay configuration, initial state, strategy
  version, and fill model version.
- `daily_quality_reports`: materialized daily summaries.

Retention policies are part of the recorder design. Canonical events are kept
in TimescaleDB for queryability. Raw payloads are stored separately from
canonical event tables in a minimally indexed hot audit table:

- indexes are limited to event ID, source, and received time;
- payload bytes are compressed before storage;
- hot raw retention starts at 14 days for MVP and is configurable;
- a scheduled archive job exports cold raw payloads to Parquet on disk;
- after archive verification, old hot raw rows are eligible for deletion.

Archive deletion is two-phase and verification-gated:

1. Export the selected raw payload time range to Parquet.
2. Write an `archive_manifests` row containing source range, row count,
   min/max timestamps, payload byte count, and file checksums.
3. Re-open the Parquet output and verify row count, timestamp bounds, and
   checksum values against the manifest.
4. Mark the manifest as verified only after readback succeeds.
5. Delete hot raw rows only for verified manifests.

If export or verification fails, hot raw rows are retained, the job records the
failure reason, and the archive is retried after the configured delay, initially
6 hours. After 3 failed attempts, the manifest records the failed file paths in
`corrupted_files`, marks the archive as corrupted, alerts the operator with the
affected time range, and blocks retention deletion. Manual recovery writes a new
archive file name rather than overwriting the corrupted file.

If measured storage growth crosses the configured limit, a follow-up design
moves cold raw payload blobs from local Parquet to an S3-compatible object store
and keeps only content hashes and object references in TimescaleDB.

Replay from archive is a planned post-MVP mode. `liq-replay` should eventually
read archived Parquet directly for deep backtests without rehydrating all cold
raw data into TimescaleDB. The MVP only has to keep archive manifests and
schemas compatible with this future mode.

## Source Addition Checklist

Every new source must pass the same checklist before strategy signals can use
it:

1. Link the current official documentation for WebSocket and any REST/backfill
   endpoints.
2. Document feed semantics: completeness, snapshot behavior, push frequency,
   retention, rate limits, symbols covered, and timestamp meaning.
3. Capture raw payload fixtures for normal events, edge cases, reconnects, and
   malformed messages.
4. Implement the connector behind the source adapter interface.
5. Add normalizer tests from fixtures, including side mapping, price type,
   quantity, notional, and validation status.
6. Review and extend the domain model and database schema if the source exposes
   fields required for strategy logic or quality diagnostics.
7. Confirm `notional_usd` can be computed for strategy-eligible events.
8. Add collector health metrics and data-quality report fields for the source.
9. Add endpoint probes for any backfill candidate and mark backfill quality
   separately from WebSocket quality.
10. Run mock load tests with the source enabled alongside at least one existing
   source.
11. Keep the source excluded from strategy aggregation until the above evidence
    is committed.

## Paper Replay Harness

Replay must support two modes:

- Historical replay: read recorded events over a time window and replay the
  strategy deterministically.
- Paper-live: consume current recorded events with paper orders only.
- Replay-from-archive: future mode that reads archived Parquet directly for
  deep backtests after the MVP archive format is stable.

Replay determinism requires:

- every run records the strategy version, fill model version, input time window,
  initial balances, and initial positions;
- all inputs come from stored liquidation, quote, trade, and futures data;
- ordering uses recorded exchange timestamps with deterministic tie-breaking by
  receive timestamp and event ID;
- execution simulation rules are versioned and immutable for a completed run.

`liq-replay` exposes a minimal `Strategy` interface. A strategy consumes a
deterministically ordered event stream and emits strategy signals, paper orders,
and state transitions. The first implementation is the baseline liquidation
stink-bid strategy; later variants must plug into the same replay engine rather
than forking replay logic.

The first strategy implementation mirrors the original idea only as a baseline:

- aggregate liquidation notional over a configurable rolling window;
- detect dominant long or short liquidation side;
- apply min/max thresholds;
- compute a pullback bid from observed Polymarket price;
- cancel unfilled limit orders when `order_cancel_window` is reached, initially
  60 seconds before market expiry, and log the result as expired;
- simulate fill using recorded order book/trade data;
- simulate inverse hedge price using recorded futures data;
- calculate paper PnL, fill rate, hedge slippage, and unhedged exposure time.

Dynamic `PULLBACK_PCT` is not enabled until replay proves the static baseline.
The design should make it pluggable, but not optimize before there is data.

Benchmark strategies are included only for comparison:

- `naive_no_pullback`: reacts to the same liquidation signal but crosses the
  Polymarket spread immediately in the paper model;
- `futures_only_directional`: expresses the liquidation signal only through the
  futures leg in paper replay.

These benchmarks are not candidates for live trading in this increment; they
exist to test whether the pullback logic adds value over simpler alternatives.

The MVP paper-fill model is explicit and versioned:

- `trade_cross`: default conservative model. A Polymarket buy limit fills only
  if a recorded trade occurs at or below the limit price within the configured
  validity window. A sell limit fills only if a recorded trade occurs at or
  above the limit price.
- `book_touch`: optimistic diagnostic model. A buy can fill when best ask
  touches or crosses the limit; a sell can fill when best bid touches or
  crosses the limit. This model is reported separately and is not the default
  because it cannot prove queue position.
- `book_depth_cross`: future model, not MVP. It can be enabled only after we
  prove that Polymarket L2 depth capture is complete enough for the target
  markets and after queue-position assumptions are documented.

The fill validity window is configurable, with 5 seconds as the initial replay
default. Hyperliquid hedge fills are simulated from recorded best bid/ask plus a
configurable slippage model and a `hedge_timeout`, initially 10 seconds. If the
hedge cannot be simulated within the timeout, the fill model records either a
failed hedge or a partial/penalized hedge according to the selected hedge model,
and risk metrics must include unhedged exposure time.

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
- anomaly warnings when event counts diverge materially from the rolling
  baseline;
- latency warnings when more than a configured share of events exceed the
  allowed exchange-to-receive delay;
- outage warnings when a source is silent longer than the configured heartbeat
  threshold.
- storage warnings including TimescaleDB size, raw hot table size, archive
  backlog, archive verification failures, and percentage of allocated disk used.

Reports are generated by CLI and later scheduled by GitHub Actions or a server
cron/systemd timer. They should write Markdown and machine-readable JSON.

A Data Quality Review Agent may summarize daily reports, compare them with
prior reports, and flag trends such as rising latency or source divergence. It
is advisory only and must not change collector settings, strategy thresholds, or
risk limits.

## CI And Developer Workflow

Required checks:

- `cargo fmt --check`
- `cargo clippy --workspace --all-targets --all-features -- -D warnings`
- `cargo test --workspace --all-features`
- `sqlx migrate run` against the development database
- `typos`
- secret scanning with `gitleaks` or an equivalent scanner
- `cargo audit`

Pre-commit hooks may run the same local checks for convenience. CI remains the
source of truth.

`sqlx` is the recommended migration/query layer for the first increment. It is
lighter than Diesel for this use case, works well with async Rust, and supports
compile-time query checking once the database workflow is established.
The CI workflow should run a disposable database for migrations and integration
tests. `sqlx` offline metadata can be added once queries stabilize so ordinary
builds do not require a live database.
Migration checks must also detect ordering conflicts: migration filenames must
be strictly increasing and unique, `sqlx migrate info` must match the expected
applied set on a fresh database, and CI must fail if two pending migrations
would apply in an ambiguous order.
`cargo deny` is a follow-up before the dependency set grows materially. The
initial policy should be narrow: approved licenses and advisory checks only.
Making it mandatory before the workspace is scaffolded would add noise without
improving the first design decision.

## Deployment Model

Local development:

- Windows host is acceptable for editing and tests.
- Docker Compose provides TimescaleDB and optional support services.
- The development database uses a persistent volume by default.
- Adminer or pgAdmin may be exposed behind a dev-only Compose profile, never in
  the default service set.
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
- Rebuild or refresh RAG indexes on a schedule, initially weekly, and after
  commits that change tracked documentation sources.
- Provide a manual RAG refresh command for operator-triggered rebuilds after
  urgent API announcements.
- Add an API documentation change detector that snapshots official source docs,
  diffs the snapshots outside the RAG index, and flags terms such as breaking,
  deprecated, removed, new required field, and payload format changes. RAG may
  index the snapshots, but it is not the source of truth for change detection.
- Re-evaluate ApeRAG if we need a heavier RAG portal, MCP-first workflows, or
  built-in multi-user management.

Allowed agents:

- Documentation ingestion agent.
- Data-quality report analyst.
- Data-quality review agent.
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
- replay runs record strategy version, fill model version, and initial state;
- mock load tests show the recorder can absorb the required scenarios without
  data loss:
  - 100 liquidation events in 1 second;
  - a weekly 24-hour stability simulation averaging 10 events per second with
    bursts to 100 events per second, tracking memory growth and write latency;
  - a multi-hour synthetic run with periodic reconnects;
  - two concurrent sources writing to the same database;
  - bounded channel overflow behavior that records drops explicitly rather than
    losing events silently;
- all generated paper orders/fills are clearly marked as simulated;
- no production trading secret is required or accepted by default.

## Next Improvements To Automate

- Nightly data-quality report generation.
- Automatic source-feed regression tests from captured raw payload fixtures.
- RAG ingestion of official docs and generated reports.
- Parquet export after schema stabilization.
- Retention and compression policy checks for TimescaleDB hypertables.
- Archive manifest verification and retry alerts.
- Storage budget reporting for database and Parquet archives.
- Replay-from-archive for deep backtests over Parquet.
- API documentation change detection with operator alerts.
- English/Russian spec synchronization check.
- Scheduled RAG index refresh and retrieval-quality checks.
- Alerting for collector downtime, feed gaps, and abnormal source divergence.
