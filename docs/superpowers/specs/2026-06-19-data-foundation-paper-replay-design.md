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
- `source_event_id`: optional venue-native event ID when the source provides
  one; it is retained separately from the project-owned `event_id`.
- `source`: exchange or provider name.
- `source_group`: aggregation group such as `cex_liquidations`, used by replay
  policies to decide whether sources are independent signals or alternatives.
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

`source_quality = derived` is reserved for events not received directly from a
venue feed, for example future synthesized aggregates or transformed data
products. MVP adapters should emit `all-events`, `snapshot-only`, or `unknown`;
derived events are recorded for diagnostics only and excluded from strategy
signals unless a replay profile explicitly enables them.

Money and sizes must not use `f64` in domain or database boundaries. Rust
domain types use decimal-safe representations.

Adapters must compute `notional_usd` from venue data, usually `quantity * price`
when the venue does not provide a notional directly. If price or quantity is
missing, the normalized event is persisted with validation status `invalid` and
an exclusion reason, but it is excluded from strategy aggregation.
Every adapter must include fixture tests for `notional_usd` semantics, including
venues where reported quantity is contracts or lots rather than base-asset
quantity.

Deduplication is source-local unless a source is a known mirror of another
source. Near-simultaneous liquidations on two venues are not duplicates; they
are independent venue events. Replay must record the aggregation policy used
for each signal so inflated or suppressed cross-source windows are auditable.

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

Strategy aggregation is policy-driven, not implicit summation:

- all-events venues may be summed as independent market-pressure signals when
  they are in the configured `source_group`;
- snapshot-only sources are diagnostic by default and must not be summed with
  all-events sources unless an explicit replay profile enables that behavior;
- fallback use of a lower-quality source is not part of the default MVP signal
  path and requires an explicit research replay profile;
- source priority, fallback decisions, and excluded sources are written to
  `strategy_signals` and `replay_runs`.

The MVP default aggregation configuration is intentionally conservative:

- `default_primary_source = "bybit"`;
- `default_fallback_sources = []`;
- `default_aggregation_policy = "primary_only"`;
- Bybit contributes to strategy signals when healthy;
- Binance is recorded and reported as diagnostic snapshot-only data. It is not
  used for MVP signals, even when Bybit is quiet, unless an explicit research
  replay profile enables and labels that behavior.

Each connector has a circuit breaker. If reconnects exceed the configured
threshold within a rolling window, the source is marked degraded, paused for a
cooldown such as 30 minutes or until manual reset, and a high-severity health
event is recorded. The initial default is `max_reconnects_per_5min = 5` per
source.

Initial backfill policy:

- Binance: disabled for market liquidation recovery because the available
  official force-order REST endpoint is authenticated USER_DATA.
- OKX: allowed as an experimental bounded backfill source after endpoint
  parameters, retention window, and duplication behavior are fixture-tested.
- Bybit: disabled until a current official public REST liquidation-history page
  and endpoint probe are added to the repository.

## Configuration

MVP configuration is file-first with environment overrides. Non-secret
parameters live in `config/default.toml` and optional local overrides such as
`config/local.toml`. Environment variables override file values for deployment.
Secrets do not live in TOML; they come from Infisical-provided environment
variables when needed.

Initial defaults:

```toml
[sources]
default_primary_source = "bybit"
default_fallback_sources = []
default_aggregation_policy = "primary_only"
primary_silence_window = "5m"

[recorder]
hot_raw_retention = "14d"
canonical_events_retention = "30d"
collector_health_retention = "7d"
queue_warning_pct = 80
queue_critical_pct = 95

[quality]
heartbeat_threshold = "2m"
latency_window = "5m"
latency_alert_share = 0.05
max_reconnects_per_5min = 5
circuit_breaker_cooldown = "30m"

[replay]
fill_validity_window = "5s"
order_cancel_window_before_expiry = "60s"
hedge_timeout = "10s"
```

Every replay run records the resolved configuration, not only the config file
path. This keeps historical results reproducible after defaults change.

`liq-cli` validates configuration at startup. Invalid values, such as zero or
negative retention windows, invalid percentages, unknown source names, or
fallback sources that are not enabled, produce a non-zero exit with a structured
list of problems. Silent fallback to defaults is not allowed after a config file
was explicitly provided.

## Recorder

TimescaleDB is the primary storage for MVP because the first problem is
time-series queryability, not cheap archival.

Tables:

- `raw_source_events`: immutable raw payload audit trail.
- `archive_manifests`: Parquet archive jobs, `parquet_schema_version`, row
  counts, time ranges, checksums, verification status, retry counts,
  `canonical_deletion_watermark`, and alert state.
- `liquidation_events`: canonical normalized liquidation events.
- `market_quotes`: Polymarket and futures quote snapshots/events.
- `collector_health`: reconnects, heartbeat gaps, adapter errors, lag.
- `strategy_signals`: replayed or paper-generated signals.
- `paper_orders`: simulated orders.
- `paper_fills`: simulated fills.
- `replay_runs`: deterministic replay configuration, initial state, strategy
  version, and fill model version.
- `daily_quality_reports`: materialized daily summaries.

The connector-to-recorder queue is bounded and configured per source. Queue
depth is exported as health data, with warnings above 80% and critical alerts
above 95%. The default behavior is backpressure or pausing reads where the
protocol allows it. Dropping old events is not an acceptable normal policy
because it breaks replay auditability; if an emergency drop mode is explicitly
enabled, the recorder must persist drop counters, affected time ranges, and
source IDs in `collector_health`. Reconnect bursts may be written with database
micro-batches, but raw liquidation events must not be aggregated before durable
storage.

For WebSocket protocols that do not support pausing reads, queue pressure above
`queue_critical_pct` triggers a controlled disconnect/reconnect with a critical
health event and a gap marker for the affected source window. If the source has
a documented bounded replay/backfill capability, the collector may attempt a
gap probe after reconnect. If not, the affected window remains marked degraded.
Emergency drop mode is a last resort and must produce explicit loss metrics.

Retention policies are part of the recorder design. Canonical events are kept
in TimescaleDB for queryability. Raw payloads are stored separately from
canonical event tables in a minimally indexed hot audit table:

- indexes are limited to event ID, source, and received time;
- payload bytes are compressed before storage;
- hot raw retention starts at 14 days for MVP and is configurable;
- a scheduled archive job exports cold raw payloads to Parquet on disk;
- after archive verification, old hot raw rows are eligible for deletion.

Canonical liquidation events have their own retention policy, initially 30
days. Deleting canonical events is allowed only after the affected time range is
covered by a verified archive and the corresponding `archive_manifests` row has
`canonical_deletion_watermark` set by the archive verifier. Manual deletion
outside that path requires an explicit operator override recorded in the audit
log. Long-horizon replay should move to Parquet-backed archive reads rather
than keeping all canonical events hot forever.

Detailed `collector_health` rows have their own retention policy, initially 7
days. Daily reports retain aggregated health summaries so long-term trends do
not require an unbounded health table.

Archive deletion is two-phase and verification-gated:

1. Export the selected raw payload time range to Parquet.
2. Write an `archive_manifests` row containing source range,
   `parquet_schema_version`, row count, min/max timestamps, payload byte count,
   file checksums, and expected Parquet metadata.
3. Re-open the Parquet output and verify row count, timestamp bounds, checksum
   values, Parquet schema version, file metadata, and column statistics against
   the manifest.
4. Read and validate the first 100 rows, last 100 rows, and a deterministic
   sample across row groups to catch row-level decode or validation failures.
5. Mark the manifest as verified only after readback succeeds.
6. Set `canonical_deletion_watermark` only after archive verification succeeds
   and the canonical time range coverage is confirmed.
7. Delete hot raw rows only for verified manifests.

If export or verification fails, hot raw rows are retained, the job records the
failure reason, and the archive is retried after the configured delay, initially
6 hours. After 3 failed attempts, the manifest records the failed file paths in
`corrupted_files`, marks the archive as corrupted, alerts the operator with the
affected time range, and blocks retention deletion. Manual recovery writes a new
archive file name rather than overwriting the corrupted file.

Archive repair is manual. A repair command rebuilds the archive for the same
time range from durable source rows, writes a new archive path, re-runs full
verification, and links the replacement manifest to the corrupted manifest.
Rows must not be silently excluded to make verification pass; if a source row is
invalid or unrecoverable, the repair report must list the row ID, reason, and
resulting coverage gap, and canonical deletion remains blocked for that gap.

If measured storage growth crosses the configured limit, a follow-up design
moves cold raw payload blobs from local Parquet to an S3-compatible object store
and keeps only content hashes and object references in TimescaleDB.

Replay from archive is a planned post-MVP mode. `liq-replay` should eventually
read archived Parquet directly for deep backtests without rehydrating all cold
raw data into TimescaleDB. The MVP only has to keep archive manifests and
schemas compatible with this future mode. `parquet_schema_version` is stored in
`archive_manifests` and mirrored as a constant in `liq-replay` so readers can
reject unsupported archive schemas explicitly. `liq-replay` maintains a reader
registry and supports at least the latest two archive schema versions once a
second version exists. Unsupported versions fail with an explicit
unsupported-schema error rather than best-effort parsing. When support for an
older version is scheduled for removal, archives in that version must first be
converted with a reviewed schema-conversion job or kept readable by a pinned
fallback reader. MVP starts with a single version, but the compatibility policy
is versioned from the first archive.

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
   `notional_usd` tests must cover venue-specific quantity semantics, including
   contracts, lots, quote currency, and base-asset quantity when applicable.
6. Review and extend the domain model and database schema if the source exposes
   fields required for strategy logic or quality diagnostics.
7. Confirm `notional_usd` can be computed for strategy-eligible events.
8. Add collector health metrics and data-quality report fields for the source.
9. Add endpoint probes for any backfill candidate and mark backfill quality
   separately from WebSocket quality.
10. Validate backfill data against the source WebSocket stream over an
    overlapping time window before any backfill is used for diagnostics or
    replay bootstrap.
11. Add source fixtures to the CI regression test suite.
12. Run mock load tests with the source enabled alongside at least one existing
   source.
13. Keep the source excluded from strategy aggregation until the above evidence
    is committed.

## Paper Replay Harness

Replay must support three modes:

- Historical replay: read recorded events over a time window and replay the
  strategy deterministically.
- Paper-live: consume current recorded events with paper orders only.
- Replay-from-archive: future mode that reads archived Parquet directly for
  deep backtests after the MVP archive format is stable.

`liq-cli replay dry-run` checks whether the requested replay can start without
executing strategy state transitions. It validates the resolved config, required
tables, source coverage, time-range availability, archive schema compatibility
when relevant, and obvious missing inputs.

Replay determinism requires:

- every run records the strategy version, fill model version, input time window,
  initial balances, and initial positions;
- every run computes an `input_hash` from the resolved configuration,
  strategy/fill-model versions, ordered input event IDs and payload
  fingerprints, source set, time range, and archive manifest IDs when archives
  are used;
- `input_hash` includes only semantically relevant inputs. Runtime version,
  compiler version, host OS, wall-clock start time, and logging configuration do
  not affect the hash unless they change replay semantics;
- all inputs come from stored liquidation, quote, trade, and futures data;
- ordering uses recorded exchange timestamps with deterministic tie-breaking by
  receive timestamp and event ID;
- execution simulation rules are versioned and immutable for a completed run.

If a completed `replay_run` already exists with the same `input_hash`, the
default behavior is to reuse or report the existing result. A new run with the
same hash requires an explicit `--force-new-run` flag and must still preserve
both run IDs for audit.

Paper-live uses the same strategy state machine as historical replay, but its
clock advances from newly recorded data. The collector records normalized
events, a paper-live worker polls or subscribes to committed windows, evaluates
the strategy over deterministic window boundaries, writes `strategy_signals`,
creates simulated `paper_orders`, and records `paper_fills` using the current
paper fill model. Paper-live never submits real orders and every generated row
is marked simulated.

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
  backlog, Parquet archive size, archive verification failures, and percentage
  of allocated database and archive disk used. Parquet archive storage warns at
  80% of the configured budget.

Reports are generated by CLI and later scheduled by GitHub Actions or a server
cron/systemd timer. They should write Markdown and machine-readable JSON.

Daily reports are not enough for paper-live operation. `liq-quality` also has a
streaming monitor mode that reads collector health and recent event metrics:

- if a source is silent longer than `heartbeat_threshold`, initially 2 minutes,
  emit a high-severity alert and health row;
- if more than a configured share of events, initially 5% over the last 5
  minutes, exceeds the latency threshold, emit a latency alert;
- if queue depth, reconnect rate, or circuit-breaker state changes, emit a
  structured health event that daily reports later aggregate.

MVP alerts are structured JSON logs plus persisted `collector_health` rows.
External notification channels are a follow-up, not a blocker for the first
collector/replay increment.

A Data Quality Review Agent may summarize daily reports, compare them with
prior reports, and flag trends such as rising latency or source divergence. It
is advisory only and must not change collector settings, strategy thresholds, or
risk limits.

Agent-generated reports need their own quality gate before they become routine
operator inputs. The RAG/agent pipeline keeps a small set of golden report
fixtures for known datasets and compares generated summaries against expected
facts and required sections. If report quality falls below the configured
threshold, the report is marked for manual review instead of being published as
normal.

## CI And Developer Workflow

Required checks:

- `cargo fmt --check`
- `cargo clippy --workspace --all-targets --all-features -- -D warnings`
- `cargo test --workspace --all-features`
- `sqlx migrate run` against the development database, executed twice in a row
  on the same disposable database to catch non-idempotent migration side effects
- source fixture regression tests for every committed raw payload fixture
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

Schema-domain alignment is tested with a disposable database after migrations.
The first implementation should prefer `sqlx` checked queries and `query_as`
contract tests against domain row types. Money and quantity columns must map to
decimal-safe Rust types; a migration that forces `f64` at a domain boundary
fails CI. A broad reflection framework is not required for MVP.

For strategy-facing tables, `liq-test-utils` also exposes an
`assert_schema_contract` helper. It queries `information_schema.columns` for
table name, column name, nullability, numeric precision/scale, and data type,
then compares those values to the expected domain schema contract. This catches
schema changes that still compile but silently alter persistence semantics.

Schema migration policy is append-only for MVP. Adding nullable columns or
columns with explicit defaults is allowed. Dropping columns, renaming columns,
or changing column types is prohibited unless a new schema version, data
migration plan, backfill/replay compatibility note, and rollback plan are
approved in the repository.

Backfill data migrations are treated as explicit jobs, not hidden migration
side effects. A PR that adds a column and intends to populate old rows must
include the backfill command or script, batch size, expected runtime, resume
behavior, locking impact, verification query, and rollback/abort instructions.
Backfill jobs persist progress in a migration state table, for example by
`last_processed_id` or `last_processed_ts`, and must support stop/resume without
starting over. Long jobs expose progress, processed row counts, estimated
remaining work, and a configurable maximum runtime per invocation.

`cargo deny` is a follow-up before the dependency set grows materially. The
initial policy should be narrow: approved licenses and advisory checks only.
`cargo audit` checks advisories against the resolved lockfile, including
transitive dependencies; `cargo deny` remains useful as a broader policy layer
for licenses, duplicate versions, bans, and advisory enforcement. Making it
mandatory before the workspace is scaffolded would add noise without improving
the first design decision.

## Deployment Model

Local development:

- Windows host is acceptable for editing and tests.
- Docker Compose provides TimescaleDB and optional support services.
- Compose project name must be `liquidation`, and all project-owned containers,
  networks, and volumes must use a `liquidation` prefix.
- Docker commands must not target existing `aperag-*`, `stat-arb-*`,
  `free_*`, or `omniroute` containers, networks, or volumes.
- Destructive Docker commands such as `docker system prune`, `docker volume
  prune`, or unscoped `docker compose down --remove-orphans` are prohibited.
- The development database uses a persistent volume by default.
- Adminer or pgAdmin may be exposed behind a dev-only Compose profile, never in
  the default service set.
- Rust binaries run from the host during development.

Server/paper-live:

- Linux VPS or dedicated server.
- systemd or Docker Compose can run collectors.
- Infisical is introduced before any private keys or authenticated trading
  credentials are needed.
- MVP collector deployment is single-writer per source. On startup, collector
  processes acquire a Postgres advisory lock or equivalent database-backed
  lease for each `(source, instrument)` they write. A second instance exits with
  a clear error instead of duplicating writes. Redis-based leader election is a
  follow-up only if the deployment outgrows the database-backed lease.

Production live trading is intentionally excluded.

## Dashboard And Visualization

The project needs an operational dashboard, but it must be read-only for MVP.
The dashboard is not a marketing surface; it is an operator workspace for
understanding data quality, replay behavior, and paper risk.

Initial dashboard scope:

- source health, heartbeat gaps, reconnects, and circuit-breaker state;
- exchange-to-receive latency and stale/offline states;
- liquidation notional by source, symbol, side, and time window;
- strategy signals, skipped-signal reasons, and paper-live state;
- paper orders, paper fills, fill model, fill rate, and unhedged exposure;
- fee-adjusted paper PnL, slippage, and hedge penalties;
- TimescaleDB storage, Parquet archive storage, archive verification status,
  and canonical deletion watermarks.

Dashboard implementation must use the same persisted data and quality reports
as replay. It must not create a second source of truth, and it must not submit
real orders or mutate strategy/risk settings in MVP.

Dashboard work should use Superpowers, design-engineer, data-visualization, and
browser/visual checks. Required guards include responsive desktop/mobile
screens, no overlapping text, readable stale/offline states, and tests for
empty, loading, partial-data, and error states.

## Fee Model

Paper PnL is not decision-grade unless fees and other execution costs are
included. MVP fee modeling starts with Polymarket and Hyperliquid because they
are the first venues used by the strategy path.

The first fee model includes:

- Polymarket trading fees or explicit zero-fee assumption with source and date;
- Hyperliquid taker/maker fees for hedge simulation;
- funding or holding cost where applicable;
- slippage model for both Polymarket paper fills and Hyperliquid hedge fills;
- failed hedge, partial hedge, and timeout penalties;
- configurable fee schedule version recorded in every `replay_run`.

Fee schedules must be versioned and dated. A replay result must report gross
PnL, fees, slippage, funding/holding costs, penalties, and net PnL separately.
Real trading remains blocked until net paper PnL is stable after costs.

## Research Before Implementation

Before the implementation plan, run a short research pass to validate current
assumptions that may change quickly: exchange APIs, fee schedules, Polymarket
market-data behavior, Hyperliquid execution/funding details, and recent
community reports about feed reliability.

Research outputs must be committed as Markdown notes under `docs/research/`.
They should include source links, dates checked, caveats, and design decisions
that changed because of the research. Research does not replace official docs
or fixtures; it only informs what to verify.

## RAG And Agents

RAG is useful but not blocking for the first collector/replay increment.
Repository documentation is the source of truth. LightRAG is a development
memory and semantic index over that source of truth; it must never become the
only place where design decisions, incidents, or runbooks live.

Recommended path:

- Run a separate LightRAG Dev Memory stack for this project. Do not reuse or
  mutate the existing ApeRAG/Omniroute containers that support another project.
  Docker names, networks, volumes, ports, and compose project names must use a
  `liquidation` prefix.
- Ingest repo-owned documentation first: `docs/`, specs, runbooks, research
  notes, incident reports, replay reports, and strategy notes. Official
  exchange documentation snapshots may be indexed after they are normalized and
  committed under `docs/snapshots/`.
- Store LightRAG index metadata: indexed Git commit hash, branch, ingestion
  timestamp, indexed paths, ingestion config version, and evaluation result.
- Provide project commands:
  - `liq-rag ingest docs/`;
  - `liq-rag eval`;
  - `liq-rag health`;
  - `liq-rag status --check-commit`.
- A stale index is not trusted. If the indexed commit hash does not match the
  current Git commit for tracked docs, tooling must warn or fail closed and use
  repository docs directly.
- Run a daily LightRAG health check that verifies service availability,
  freshness, evaluation score, and storage health. Alert when LightRAG is stale,
  unavailable, or below the retrieval-quality threshold.
- `liq-rag health` must distinguish `ok`, `degraded-but-usable`, and `failed`.
  `ok` means `liquidation-omniroute` and the Kiro combo are working.
  `degraded-but-usable` means `liquidation-omniroute` is unavailable but
  `liquidation-free-deepseek` answers directly. `failed` means neither
  `liquidation-omniroute` nor `liquidation-free-deepseek` works, or
  LightRAG/index/eval is unusable.
- Add automatic quality checks for retrieval using known question/answer pairs.
  A refresh fails or alerts when top-5 recall or simple answer accuracy drops
  below 80% on the tracked evaluation set. Mean reciprocal rank is reported as
  a trend metric so a correct document falling from rank 1 to rank 5 is visible.
  The first implementation may use a small project script; RAGAS is a follow-up
  candidate, not an MVP dependency.
- Rebuild or refresh RAG indexes after commits that change tracked
  documentation sources, and keep a weekly scheduled rebuild as a fallback.
- Provide a manual RAG refresh command for operator-triggered rebuilds after
  urgent API announcements.
- Exclude secrets, `.env` files, Infisical exports, private keys, exchange
  credentials, and large raw market-data blobs from ingestion.
- If LightRAG or its LLM provider is unavailable, development continues from
  repository docs. RAG downtime must not block collector, replay, CI, or paper
  trading work.
- Add an API documentation change detector that snapshots official source docs,
  diffs the snapshots outside the RAG index, and flags terms such as breaking,
  deprecated, removed, new required field, and payload format changes. RAG may
  index the snapshots, but it is not the source of truth for change detection.
- Store normalized documentation snapshots as JSON under `docs/snapshots/`.
  These snapshots should contain source URL, fetch timestamp, content hash,
  extracted endpoint/schema facts, and relevant text excerpts, not large raw
  HTML dumps. Scheduled jobs may open PRs when snapshots change.
- Scheduled snapshot jobs generate a machine-readable diff against the previous
  snapshot. Critical changes such as breaking, deprecated, removed, new
  required field, and payload format changes open an issue or alert; noncritical
  changes can be handled as a normal snapshot update PR.
- Re-evaluate ApeRAG only later if we need a heavier RAG portal, MCP-first
  workflows, or built-in multi-user management. The existing ApeRAG stack is not
  a project dependency for this repository.

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
- `liq-cli` rejects invalid configuration with actionable errors;
- `liq-cli replay dry-run` validates inputs without executing strategy
  transitions;
- archive manifests record `parquet_schema_version` and verification metadata;
- archive manifests expose `canonical_deletion_watermark` before canonical
  retention deletion can run;
- collector startup refuses a second active writer for the same
  `(source, instrument)` lease;
- quality reports run over a recorded time window;
- replay produces deterministic paper signals from stored data;
- replay runs record strategy version, fill model version, initial state, and
  `input_hash`;
- mock load tests show the recorder can absorb the required scenarios without
  data loss:
  - 100 liquidation events in 1 second;
  - a weekly 24-hour stability simulation averaging 10 events per second with
    bursts to 100 events per second, tracking memory growth, RSS start/end, and
    write latency. The default failure threshold is no unbounded RSS growth and
    no more than 10% growth unless an explicit fixed-memory budget is configured;
  - Linux-only file descriptor tracking during long-running tests via
    `/proc/<pid>/fd` or an equivalent tool. Open descriptors must not grow
    without bound across reconnect cycles;
  - adapter metrics assert that active WebSocket connection count returns to
    the expected value after reconnect cycles. Stale active connections fail
    the test even if file descriptor counts look stable;
  - TimescaleDB restart mid-write: the collector reconnects, records the error,
    preserves queued events that have not been acknowledged as written, and
    resumes writes without silent loss;
  - a multi-hour synthetic run with periodic reconnects;
  - two concurrent sources writing to the same database;
  - bounded channel overflow behavior that records drops explicitly rather than
    losing events silently;
- strategy corruption tests cover duplicate events, missing windows, invalid
  prices, impossible notionals, and out-of-order inputs without panics. The
  strategy must skip or mark invalid data and emit diagnostics;
- all generated paper orders/fills are clearly marked as simulated;
- dashboard requirements are documented and remain read-only for MVP;
- replay reports include gross PnL, fees, slippage, penalties, and net PnL;
- Docker Compose usage is scoped to project name `liquidation` and does not
  affect existing containers from other projects;
- pre-implementation research notes are committed for time-sensitive
  assumptions;
- no production trading secret is required or accepted by default.

## Next Improvements To Automate

- Nightly data-quality report generation.
- Automatic source-feed regression tests from captured raw payload fixtures.
- Source aggregation policy tests for all-events, snapshot-only, fallback, and
  excluded-source windows.
- Strategy corruption tests for duplicates, gaps, invalid prices, and
  out-of-order events.
- Streaming quality alerts for heartbeat gaps, queue pressure, latency, and
  circuit-breaker transitions.
- Configuration validation and resolved-config snapshots for replay runs.
- Schema contract checks from `information_schema.columns`.
- Backfill data migration runners with resume and verification support.
- Documentation snapshot refresh jobs that open reviewable PRs.
- Documentation snapshot diff jobs that classify critical vs noncritical API
  changes.
- RAG retrieval-quality checks with an 80% minimum score gate.
- Agent report quality checks against golden report fixtures.
- Adapter connection leak checks in long-running load tests.
- DB restart mid-write load test.
- Single-writer source lease check for collector startup.
- Replay `input_hash` reuse and `replay dry-run` checks.
- Parquet schema reader registry compatibility tests.
- Signal weighting research for future all-events sources only; snapshot-only
  Binance must not receive a production signal weight in MVP.
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
- Read-only operational dashboard with visual and responsive QA.
- Fee schedule ingestion and fee-adjusted replay reports.
- Docker safety checks for compose project name, ports, networks, and volumes.
- Pre-implementation research checklist and report template.
