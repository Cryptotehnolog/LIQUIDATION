# Дизайн: фундамент данных и paper replay

Дата: 2026-06-19
Статус: черновик для проверки пользователем

## Цель

Построить первый безопасный инкремент для проекта Liquidation Cascades Meet
Prediction Markets: фундамент данных на Rust и систему replay только для
бумажной торговли. Этот инкремент должен доказать, что мы умеем собирать
надежные данные ликвидаций и рыночные данные, измерять качество данных,
воспроизводить сигналы стратегии и оценивать бумажный PnL до того, как будет
разрешен любой код реальной торговли.

Это не live trading bot. Приватные торговые ключи, реальные ордера и
автоматическое исполнение не входят в scope этого инкремента.

## Решения

1. Язык реализации: Rust.
2. Первая система строится вокруг данных, а не вокруг исполнения сделок.
3. Реальная торговля заблокирована до тех пор, пока paper trading и replay
   reports не покажут стабильное качество данных, воспроизводимые сигналы и
   приемлемые риск-метрики.
4. Подключение к биржам реализуется через прямые WebSocket/HTTP-адаптеры там,
   где это практично, а не через зависимость от Moon Dev API как основного
   источника.
5. AI и RAG используются только в control plane. Они могут помогать с
   ingestion документации, резюмированием отчетов и review изменений, но не
   должны принимать решения об исполнении сделок.
6. Docker используется для инфраструктуры и воспроизводимых локальных сервисов.
   Rust-бинарники также должны запускаться вне Docker во время разработки.
7. Секреты позже хранятся в Infisical, но этот инкремент не должен требовать
   production trading secrets.

## Что я оспариваю

Pre-commit hooks полезны, но это не граница безопасности и не граница
корректности. Их можно пропустить. Надежный gate должен быть в CI: `cargo fmt`,
`cargo clippy`, tests, migration checks и secret scanning в GitHub Actions.

TimescaleDB и Parquet не должны быть двумя первичными hot query paths в первый
же день. Рекомендованный MVP-путь: TimescaleDB как primary query recorder для
canonical events, плюс простой scheduled Parquet archive для cold raw payloads.
Два primary query storage слишком рано создадут лишние проблемы reconciliation.

Generic exchange library не должна прятать семантику liquidation feed. Binance,
Bybit, OKX и Hyperliquid не дают одинаковых гарантий по ликвидациям. Normalizer
должен сохранять metadata качества источника: snapshot feed, all liquidations
feed, observed latency и adapter confidence.

Historical REST backfill нельзя считать гарантированным восстановлением
пропусков. Для каждой venue надо доказать, что REST endpoint является публичным,
market-wide и семантически эквивалентным WebSocket stream, прежде чем
использовать его для заполнения gaps. Например, Binance `GET /fapi/v1/forceOrders`
является USER_DATA endpoint для force orders конкретного authenticated user, а
не публичной историей рыночных ликвидаций.
OKX `GET /api/v5/public/liquidation-orders` является публичным кандидатом для
bounded backfill, но должен считаться ограниченной recent history. Bybit REST
liquidation history не считается verified, пока в репозиторий не добавлены
ссылка на official public endpoint и автоматический endpoint probe;
`/v5/market/liquidation-history` вернул 404 во время design review.

## Scope

### В scope

- Скелет Rust workspace.
- Типизированная domain model для liquidation events, market quotes, Polymarket
  market metadata, strategy signals, paper orders и paper fills.
- Интерфейс exchange/source adapter.
- Первые liquidation adapters для Binance USD-M futures и Bybit derivatives,
  потому что семантику их liquidation feed можно проверить по официальной
  документации.
- Нормализация в canonical liquidation events.
- Durable recording в TimescaleDB через SQL migrations.
- Data-quality jobs и daily reports.
- Paper-only strategy replay harness.
- CI gates для formatting, linting, tests, migrations и typo checks.
- Test support utilities для fixtures, mock sources и replay assertions.
- Mock load tests, которые нагружают collector и recorder выше normal event
  rates.
- Benchmark replay strategies, используемые только для сравнения с baseline.
- Development Docker Compose для TimescaleDB и supporting services.

### Вне scope

- Реальное размещение ордеров на Polymarket.
- Реальное размещение hedge на Hyperliquid.
- Работа с mainnet private keys.
- Production deployment Infisical.
- Полный deployment RAG.
- Оптимизация стратегии сверх paper/replay metrics.
- Масштабирование на ETH, SOL и XRP.

## Архитектура

Workspace делится на небольшие crates, чтобы каждую часть можно было тестировать
без загрузки всей системы.

- `liq-domain`: canonical types, enums, IDs, decimal-safe money/quantity types и
  validation rules.
- `liq-connectors`: exchange/source adapters для liquidation и market data.
- `liq-normalizer`: преобразует source payloads в canonical events и добавляет
  source quality.
- `liq-recorder`: пишет нормализованные данные в TimescaleDB и управляет
  migrations.
- `liq-quality`: считает latency, gaps, reconnects, duplicates и anomaly
  metrics.
- `liq-replay`: воспроизводит записанные данные через state machine стратегии.
- `liq-test-utils`: общие test fixtures, mock event sources, deterministic
  clocks, load generators и replay assertion helpers.
- `liq-cli`: operator CLI для запуска collectors, reports и replay jobs.

Hot path:

source WebSocket/HTTP -> connector -> canonical event -> validator -> recorder
-> quality metrics -> replay harness.

Strategy path намеренно находится downstream от записанных данных. Если сигнал
нельзя воспроизвести из durable records, он не считается валидным.

## Модель данных

Canonical liquidation event включает:

- `event_id`: детерминированный hash по source, symbol, side, quantity, price,
  exchange event time и raw payload fingerprint.
- `source_event_id`: optional venue-native event ID, если source его дает; он
  хранится отдельно от project-owned `event_id`.
- `source`: название биржи или provider.
- `source_group`: aggregation group, например `cex_liquidations`, который
  replay policies используют для выбора independent signals или alternatives.
- `instrument`: нормализованный инструмент, например `BTC-USDT-PERP`.
- `base_asset`: `BTC` для первого инкремента.
- `side`: long-liquidated или short-liquidated, через собственный enum проекта.
- `quantity`: decimal quantity в base asset.
- `price`: decimal execution или bankruptcy price с указанием source price type.
- `notional_usd`: decimal notional. Он обязателен для liquidation events,
  которые могут участвовать в стратегии.
- `exchange_event_ts`: timestamp от venue.
- `received_ts`: локальный UTC capture timestamp.
- `receive_monotonic_ns`: локальный monotonic capture timestamp для latency и
  ordering diagnostics.
- `source_sequence`: optional sequence или stream offset, если доступно.
- `source_quality`: all-events, snapshot-only, derived, unknown.
- `raw_payload`: compressed JSON для audit и будущих parser upgrades.

`source_quality = derived` зарезервирован для events, которые не получены
напрямую из venue feed, например future synthesized aggregates или transformed
data products. MVP adapters должны emit `all-events`, `snapshot-only` или
`unknown`; derived events записываются только для diagnostics и исключаются из
strategy signals, если replay profile явно не включает их.

Money и sizes не должны использовать `f64` в domain или database boundaries. Rust
domain types используют decimal-safe representations.

Adapters должны вычислять `notional_usd` из venue data, обычно как
`quantity * price`, если venue не дает notional напрямую. Если price или
quantity отсутствует, normalized event сохраняется с validation status `invalid`
и exclusion reason, но исключается из strategy aggregation.
Каждый adapter должен иметь fixture tests для `notional_usd` semantics, включая
venues, где reported quantity является contracts или lots, а не base-asset
quantity.

Deduplication является source-local, кроме случаев, когда source является
известным mirror другого source. Почти одновременные liquidations на двух venue
не являются duplicates; это независимые venue events. Replay должен записывать
aggregation policy для каждого signal, чтобы cross-source windows можно было
аудировать.

## Стратегия источников

Phase 1 приоритизирует источники, которые можно быстро валидировать:

- Binance USD-M futures liquidation stream: полезен, но является snapshot-only
  для каждого symbol в интервале 1000 ms, поэтому его нельзя считать полным.
- Bybit all-liquidation stream: более сильное покрытие liquidation events и
  500 ms push frequency согласно официальной документации.
- Polymarket public market WebSocket: нужен для paper fills и market state.
  Authenticated user channels исключены до утверждения отдельного execution
  design.

OKX и Hyperliquid liquidation adapters добавляются после того, как их точная
официальная feed semantics будет задокументирована в репозитории. Если источник
нельзя доказать официальной документацией или наблюдаемыми raw payloads, он
помечается как experimental и по умолчанию исключается из strategy signals.

Backfill adapters являются source-specific. Их можно добавить для bootstrap или
diagnostics, но нельзя использовать для repair gaps, пока coverage и retention
endpoint не будут задокументированы и протестированы. Backfilled events должны
сохранять собственные source quality и ingestion mode.

Cross-source substitution не является backfill. Если Bybit WebSocket down, OKX
data может продолжать давать alternate venue signal, но ее нельзя использовать
для заполнения Bybit gaps или помечать как derived Bybit coverage. Strategy
reports должны показывать, какие sources были active в каждом signal window.

Strategy aggregation является policy-driven, а не implicit summation:

- all-events venues можно суммировать как independent market-pressure signals,
  если они входят в configured `source_group`;
- snapshot-only sources по умолчанию diagnostic и не должны суммироваться с
  all-events sources, если explicit replay profile не включает это поведение;
- fallback на source более низкого качества не входит в default MVP signal path
  и требует explicit research replay profile;
- source priority, fallback decisions и excluded sources записываются в
  `strategy_signals` и `replay_runs`.

MVP default aggregation configuration намеренно консервативная:

- `default_primary_source = "bybit"`;
- `default_fallback_sources = []`;
- `default_aggregation_policy = "primary_only"`;
- Bybit участвует в strategy signals, когда healthy;
- Binance записывается и репортится как diagnostic snapshot-only data. Он не
  используется для MVP signals, даже если Bybit quiet, если explicit research
  replay profile не включает и не маркирует это поведение.

У каждого connector есть circuit breaker. Если reconnects превышают configured
threshold внутри rolling window, source помечается degraded, ставится на паузу
на cooldown, например 30 minutes, или до manual reset, а high-severity health
event записывается. Initial default - `max_reconnects_per_5min = 5` per source.

Initial backfill policy:

- Binance: disabled для market liquidation recovery, потому что доступный
  official force-order REST endpoint является authenticated USER_DATA.
- OKX: allowed как experimental bounded backfill source после fixture-тестов
  endpoint parameters, retention window и duplication behavior.
- Bybit: disabled, пока current official public REST liquidation-history page и
  endpoint probe не будут добавлены в репозиторий.

## Configuration

MVP configuration является file-first с environment overrides. Non-secret
parameters живут в `config/default.toml` и optional local overrides, например
`config/local.toml`. Environment variables override file values для deployment.
Secrets не живут в TOML; когда они понадобятся, они приходят из
Infisical-provided environment variables.

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

Каждый replay run записывает resolved configuration, а не только путь к config
file. Это сохраняет historical results reproducible после изменения defaults.

`liq-cli` валидирует configuration при startup. Invalid values, например zero
или negative retention windows, invalid percentages, unknown source names или
fallback sources, которые не enabled, дают non-zero exit со structured list of
problems. Silent fallback to defaults запрещен после явного указания config
file.

## Recorder

TimescaleDB является primary storage для MVP, потому что первая проблема -
time-series queryability, а не дешевый архив.

Таблицы:

- `raw_source_events`: immutable audit trail raw payloads.
- `archive_manifests`: Parquet archive jobs, `parquet_schema_version`, row
  counts, time ranges, checksums, verification status, retry counts,
  `canonical_deletion_watermark` и alert state.
- `liquidation_events`: canonical normalized liquidation events.
- `market_quotes`: Polymarket и futures quote snapshots/events.
- `collector_health`: reconnects, heartbeat gaps, adapter errors, lag.
- `strategy_signals`: replayed или paper-generated signals.
- `paper_orders`: simulated orders.
- `paper_fills`: simulated fills.
- `replay_runs`: deterministic replay configuration, initial state, strategy
  version и fill model version.
- `daily_quality_reports`: materialized daily summaries.

Connector-to-recorder queue является bounded и configured per source. Queue
depth экспортируется как health data, с warnings выше 80% и critical alerts
выше 95%. Default behavior - backpressure или pause reads там, где protocol это
позволяет. Dropping old events не является acceptable normal policy, потому что
ломает replay auditability; если emergency drop mode явно включен, recorder
должен сохранять drop counters, affected time ranges и source IDs в
`collector_health`. Reconnect bursts можно писать database micro-batches, но
raw liquidation events нельзя агрегировать до durable storage.

Для WebSocket protocols, которые не поддерживают pausing reads, queue pressure
выше `queue_critical_pct` запускает controlled disconnect/reconnect с critical
health event и gap marker для affected source window. Если source имеет
documented bounded replay/backfill capability, collector может попытаться gap
probe после reconnect. Если нет, affected window остается marked degraded.
Emergency drop mode является last resort и обязан создавать explicit loss
metrics.

Retention policies являются частью recorder design. Canonical events хранятся в
TimescaleDB для queryability. Raw payloads хранятся отдельно от canonical event
tables в minimally indexed hot audit table:

- indexes ограничены event ID, source и received time;
- payload bytes сжимаются до записи;
- hot raw retention для MVP начинается с 14 days и является configurable;
- scheduled archive job экспортирует cold raw payloads в Parquet на диске;
- после archive verification старые hot raw rows можно удалять.

Canonical liquidation events имеют отдельную retention policy, изначально 30
days. Удалять canonical events можно только после того, как affected time range
покрыт verified archive и соответствующий `archive_manifests` row имеет
установленный `canonical_deletion_watermark`. Manual deletion вне этого пути
требует explicit operator override, записанный в audit log. Long-horizon replay
должен переходить на Parquet-backed archive reads, а не держать все canonical
events hot forever.

Detailed `collector_health` rows имеют отдельную retention policy, изначально 7
days. Daily reports сохраняют aggregated health summaries, чтобы long-term
trends не требовали unbounded health table.

Archive deletion является two-phase и verification-gated:

1. Export выбранного raw payload time range в Parquet.
2. Записать `archive_manifests` row с source range,
   `parquet_schema_version`, row count, min/max timestamps, payload byte count,
   file checksums и expected Parquet metadata.
3. Повторно открыть Parquet output и проверить row count, timestamp bounds,
   checksum values, Parquet schema version, file metadata и column statistics
   against manifest.
4. Прочитать и validate первые 100 rows, последние 100 rows и deterministic
   sample across row groups, чтобы поймать row-level decode или validation
   failures.
5. Пометить manifest как verified только после успешного readback.
6. Установить `canonical_deletion_watermark` только после successful archive
   verification и confirmed canonical time range coverage.
7. Удалять hot raw rows только для verified manifests.

Если export или verification fails, hot raw rows сохраняются, job записывает
failure reason, а archive повторяется после configured delay, изначально через
6 hours. После 3 failed attempts manifest записывает failed file paths в
`corrupted_files`, помечает archive как corrupted, отправляет operator alert с
affected time range и блокирует retention deletion. Manual recovery пишет новый
archive file name, а не перезаписывает corrupted file.

Archive repair является manual operation. Repair command пересоздает archive
для того же time range из durable source rows, пишет новый archive path,
повторяет full verification и связывает replacement manifest с corrupted
manifest. Rows нельзя silently exclude, чтобы verification прошла. Если source
row invalid или unrecoverable, repair report должен указать row ID, reason и
resulting coverage gap, а canonical deletion остается blocked для этого gap.

Если measured storage growth пересечет configured limit, follow-up design
переносит cold raw payload blobs из local Parquet в S3-compatible object store,
а в TimescaleDB оставляет только content hashes и object references.

Replay from archive является planned post-MVP mode: `liq-replay` сможет читать
Parquet archives напрямую, минуя hot TimescaleDB tables. Это нужно для deep
backtests после истечения hot retention window, но не должно блокировать первый
collector/recorder increment. `parquet_schema_version` хранится в
`archive_manifests` и зеркалится как constant в `liq-replay`, чтобы readers
явно отклоняли unsupported archive schemas. `liq-replay` поддерживает reader
registry и минимум две последние archive schema versions после появления второй
версии. Unsupported versions fail с explicit unsupported-schema error, а не
через best-effort parsing. Когда поддержка older version запланирована к
удалению, archives этой версии сначала должны быть converted через reviewed
schema-conversion job или оставаться readable через pinned fallback reader. MVP
стартует с одной version, но compatibility policy версионируется с первого
archive.

## Source Addition Checklist

Каждый новый source должен пройти один и тот же checklist до того, как strategy
signals смогут его использовать:

1. Добавить ссылку на current official documentation для WebSocket и любых
   REST/backfill endpoints.
2. Задокументировать feed semantics: completeness, snapshot behavior,
   push frequency, retention, rate limits, covered symbols и timestamp meaning.
3. Захватить raw payload fixtures для normal events, edge cases, reconnects и
   malformed messages.
4. Реализовать connector за source adapter interface.
5. Добавить normalizer tests из fixtures, включая side mapping, price type,
   quantity, notional и validation status.
   `notional_usd` tests должны покрывать venue-specific quantity semantics,
   включая contracts, lots, quote currency и base-asset quantity where
   applicable.
6. Review and extend domain model и database schema, если source дает поля,
   нужные для strategy logic или quality diagnostics.
7. Подтвердить, что `notional_usd` можно вычислить для strategy-eligible events.
8. Добавить collector health metrics и data-quality report fields для source.
9. Добавить endpoint probes для любого backfill candidate и помечать backfill
   quality отдельно от WebSocket quality.
10. Validate backfill data against source WebSocket stream over overlapping
    time window before any backfill используется для diagnostics или replay
    bootstrap.
11. Добавить source fixtures в CI regression test suite.
12. Запустить mock load tests с новым source вместе минимум с одним existing
   source.
13. Держать source исключенным из strategy aggregation, пока эти evidence не
    закоммичены.

## Paper Replay Harness

Replay должен поддерживать три режима:

- Historical replay: читать recorded events за временное окно и
  детерминированно воспроизводить стратегию.
- Paper-live: потреблять текущие recorded events только с paper orders.
- Replay-from-archive: future mode для чтения Parquet archives напрямую для
  deep backtests после hot retention window.

`liq-cli replay dry-run` проверяет, что requested replay может стартовать без
execution strategy state transitions. Он валидирует resolved config, required
tables, source coverage, time-range availability, archive schema compatibility,
если relevant, и obvious missing inputs.

Для детерминизма replay требуется:

- каждый run записывает strategy version, fill model version, input time window,
  initial balances и initial positions;
- каждый run вычисляет `input_hash` из resolved configuration,
  strategy/fill-model versions, ordered input event IDs и payload fingerprints,
  source set, time range и archive manifest IDs, если archives используются;
- `input_hash` включает только semantically relevant inputs. Runtime version,
  compiler version, host OS, wall-clock start time и logging configuration не
  влияют на hash, если они не меняют replay semantics;
- все inputs берутся из stored liquidation, quote, trade и futures data;
- ordering использует recorded exchange timestamps с deterministic tie-breaking
  по receive timestamp и event ID;
- execution simulation rules версионируются и immutable для завершенного run.

Если completed `replay_run` уже существует с тем же `input_hash`, default
behavior - reuse или report existing result. Новый run с тем же hash требует
explicit `--force-new-run` flag и всё равно сохраняет оба run IDs для audit.

Paper-live использует тот же strategy state machine, что historical replay, но
его clock двигается от newly recorded data. Collector записывает normalized
events, paper-live worker poll или subscribe to committed windows, evaluates
strategy over deterministic window boundaries, пишет `strategy_signals`,
создает simulated `paper_orders` и записывает `paper_fills` через current paper
fill model. Paper-live никогда не отправляет real orders, и каждая generated
row маркируется simulated.

`liq-replay` предоставляет минимальный `Strategy` interface. Strategy потребляет
deterministically ordered event stream и выдает strategy signals, paper orders и
state transitions. Первая реализация - baseline liquidation stink-bid strategy;
будущие варианты должны подключаться к тому же replay engine, а не форкать
replay logic.

Первая реализация стратегии повторяет исходную идею только как baseline:

- агрегировать liquidation notional в configurable rolling window;
- определять доминирующую сторону long или short liquidations;
- применять min/max thresholds;
- вычислять pullback bid от observed Polymarket price;
- cancel unfilled limit orders при достижении `order_cancel_window`, изначально
  60 seconds before market expiry, и логировать result как expired;
- симулировать fill по recorded order book/trade data;
- симулировать inverse hedge price по recorded futures data;
- считать paper PnL, fill rate, hedge slippage и unhedged exposure time.

Dynamic `PULLBACK_PCT` не включается, пока replay не докажет static baseline.
Дизайн должен сделать его pluggable, но не оптимизировать до появления данных.

Benchmark strategies включаются только для сравнения:

- `naive_no_pullback`: реагирует на тот же liquidation signal, но сразу
  пересекает Polymarket spread в paper model;
- `futures_only_directional`: выражает liquidation signal только через futures
  leg в paper replay.

Эти benchmarks не являются кандидатами для live trading в этом инкременте; они
нужны, чтобы проверить, добавляет ли pullback logic ценность по сравнению с
простыми альтернативами.

MVP paper-fill model является explicit и versioned:

- `trade_cross`: default conservative model. Polymarket buy limit fills только
  если recorded trade произошел at or below limit price в configured validity
  window. Sell limit fills только если recorded trade произошел at or above
  limit price.
- `book_touch`: optimistic diagnostic model. Buy может fill, когда best ask
  touches или crosses limit; sell может fill, когда best bid touches или crosses
  limit. Эта model reported separately и не является default, потому что не
  доказывает queue position.
- `book_depth_cross`: future model, не MVP. Ее можно включить только после
  доказательства, что Polymarket L2 depth capture достаточно полный для target
  markets, и после документирования queue-position assumptions.

Fill validity window configurable, initial replay default - 5 seconds.
Hyperliquid hedge fills симулируются из recorded best bid/ask плюс configurable
slippage model и `hedge_timeout`, изначально 10 seconds. Если hedge fill не
доказан до timeout, replay помечает hedge как failed или partial according to
versioned fill model, применяет configured penalty и включает unhedged exposure
time в risk metrics.

## Data Quality Reports

Daily reports включают:

- events by source and symbol;
- duplicate rate;
- missing heartbeat/gap intervals;
- adapter reconnect count;
- exchange event time to local receive latency;
- normalization errors by type;
- unknown-side или unknown-price events;
- source coverage warning, особенно для snapshot-only feeds;
- paper signal count и skipped-signal reasons.
- anomaly warnings, когда event counts materially отличаются от rolling
  baseline;
- latency warnings, когда больше configured share событий превышают allowed
  exchange-to-receive delay;
- outage warnings, когда source молчит дольше configured heartbeat threshold.
- storage warnings, включая TimescaleDB size, raw hot table size, archive
  backlog, Parquet archive size, archive verification failures и percentage of
  allocated database and archive disk used. Parquet archive storage warns at
  80% of configured budget.

Reports генерируются через CLI, а позже планируются через GitHub Actions или
server cron/systemd timer. Они должны записываться в Markdown и machine-readable
JSON.

Daily reports недостаточны для paper-live operation. `liq-quality` также имеет
streaming monitor mode, который читает collector health и recent event metrics:

- если source молчит дольше `heartbeat_threshold`, изначально 2 minutes,
  emit high-severity alert и health row;
- если больше configured share событий, изначально 5% за последние 5 minutes,
  превышает latency threshold, emit latency alert;
- если queue depth, reconnect rate или circuit-breaker state меняется, emit
  structured health event, который daily reports позже агрегируют.

MVP alerts - это structured JSON logs плюс persisted `collector_health` rows.
External notification channels являются follow-up, а не blocker для первого
collector/replay increment.

Data Quality Review Agent может summarize daily reports, сравнивать их с prior
reports и flag trends, например rising latency или source divergence. Он только
advisory и не должен менять collector settings, strategy thresholds или risk
limits.

Agent-generated reports требуют собственного quality gate, прежде чем стать
routine operator inputs. RAG/agent pipeline хранит небольшой набор golden report
fixtures для known datasets и сравнивает generated summaries с expected facts и
required sections. Если report quality ниже configured threshold, report
маркируется для manual review, а не публикуется как normal.

## CI и Developer Workflow

Обязательные checks:

- `cargo fmt --check`
- `cargo clippy --workspace --all-targets --all-features -- -D warnings`
- `cargo test --workspace --all-features`
- `sqlx migrate run` против development database, executed twice in a row on
  the same disposable database, чтобы поймать non-idempotent migration side
  effects
- source fixture regression tests для каждого committed raw payload fixture
- `typos`
- secret scanning через `gitleaks` или equivalent scanner
- `cargo audit`

Pre-commit hooks могут запускать те же local checks для удобства. CI остается
source of truth.

`sqlx` является рекомендованным migration/query layer для первого инкремента. Он
легче Diesel для этого use case, хорошо работает с async Rust и поддерживает
compile-time query checking после настройки database workflow.
CI workflow должен поднимать disposable database для migrations и integration
tests. `sqlx` offline metadata можно добавить после стабилизации queries, чтобы
обычные builds не требовали live database.

CI также должен проверять migration ordering conflicts: migration filenames
должны быть unique, strictly increasing и accepted by `sqlx migrate info`.
Ambiguous ordering или duplicate timestamp blocks PR, потому что schema drift в
recorder dangerous для replay reproducibility.

Schema-domain alignment проверяется через disposable database после migrations.
Первая реализация должна предпочитать `sqlx` checked queries и `query_as`
contract tests против domain row types. Money и quantity columns должны
маппиться в decimal-safe Rust types; migration, которая вынуждает `f64` на
domain boundary, падает в CI. Broad reflection framework не требуется для MVP.

Для strategy-facing tables `liq-test-utils` также предоставляет
`assert_schema_contract` helper. Он делает query в `information_schema.columns`
для table name, column name, nullability, numeric precision/scale и data type,
затем сравнивает значения с expected domain schema contract. Это ловит schema
changes, которые compile, но тихо меняют persistence semantics.

Schema migration policy для MVP является append-only. Разрешено добавлять
nullable columns или columns с explicit defaults. Drop columns, rename columns
или type changes запрещены без approved new schema version, data migration
plan, backfill/replay compatibility note и rollback plan в репозитории.

Backfill data migrations являются explicit jobs, а не hidden migration side
effects. PR, который добавляет column и хочет populate old rows, должен
содержать backfill command или script, batch size, expected runtime, resume
behavior, locking impact, verification query и rollback/abort instructions.
Backfill jobs сохраняют progress в migration state table, например через
`last_processed_id` или `last_processed_ts`, и должны поддерживать stop/resume
без начала с нуля. Long jobs expose progress, processed row counts, estimated
remaining work и configurable maximum runtime per invocation.

`cargo deny` является follow-up до существенного роста dependency set. Initial
policy должна быть узкой: approved licenses и advisory checks only.
`cargo audit` проверяет advisories against resolved lockfile, включая
transitive dependencies; `cargo deny` остается полезным broader policy layer
для licenses, duplicate versions, bans и advisory enforcement. Делать его
обязательным до scaffold workspace добавит noise без улучшения первого design
decision.

## Deployment Model

Local development:

- Windows host подходит для editing и tests.
- Docker Compose предоставляет TimescaleDB и optional support services.
- Compose project name должен быть `liquidation`, а все принадлежащие проекту
  containers, networks и volumes должны использовать prefix `liquidation`.
- Docker commands не должны target существующие `aperag-*`, `stat-arb-*`,
  `free_*` или `omniroute` containers, networks или volumes.
- Destructive Docker commands, например `docker system prune`, `docker volume
  prune` или unscoped `docker compose down --remove-orphans`, запрещены.
- Development database по умолчанию использует persistent volume.
- Adminer или pgAdmin можно открыть только через dev-only Compose profile, но не
  в default service set.
- Rust binaries запускаются с host во время разработки.

Server/paper-live:

- Linux VPS или dedicated server.
- systemd или Docker Compose могут запускать collectors.
- Infisical вводится до того, как потребуются private keys или authenticated
  trading credentials.
- MVP collector deployment является single-writer per source. При startup
  collector processes берут Postgres advisory lock или equivalent
  database-backed lease для каждого `(source, instrument)`, в который пишут.
  Второй instance exits with clear error, вместо duplicated writes.
  Redis-based leader election является follow-up только если deployment
  перерастет database-backed lease.

Production live trading намеренно исключен.

## Dashboard и визуализация

Проекту нужен operational dashboard, но в MVP он должен быть read-only.
Dashboard не является marketing surface; это operator workspace для понимания
data quality, replay behavior и paper risk.

Initial dashboard scope:

- source health, heartbeat gaps, reconnects и circuit-breaker state;
- exchange-to-receive latency и stale/offline states;
- liquidation notional по source, symbol, side и time window;
- strategy signals, skipped-signal reasons и paper-live state;
- paper orders, paper fills, fill model, fill rate и unhedged exposure;
- fee-adjusted paper PnL, slippage и hedge penalties;
- TimescaleDB storage, Parquet archive storage, archive verification status и
  canonical deletion watermarks.

Dashboard implementation должен использовать те же persisted data и quality
reports, что replay. Он не должен создавать second source of truth и не должен
submit real orders или менять strategy/risk settings в MVP.

Dashboard work должен использовать Superpowers, design-engineer,
data-visualization и browser/visual checks. Required guards: responsive
desktop/mobile screens, отсутствие overlapping text, readable stale/offline
states и tests для empty, loading, partial-data и error states.

## Fee Model

Paper PnL нельзя считать decision-grade, если fees и execution costs не учтены.
MVP fee modeling начинается с Polymarket и Hyperliquid, потому что это первые
venues в strategy path.

Первая fee model включает:

- Polymarket trading fees или explicit zero-fee assumption с source и date;
- Hyperliquid taker/maker fees для hedge simulation;
- funding или holding cost, где применимо;
- slippage model для Polymarket paper fills и Hyperliquid hedge fills;
- failed hedge, partial hedge и timeout penalties;
- configurable fee schedule version, записанный в каждый `replay_run`.

Fee schedules должны быть versioned и dated. Replay result должен отдельно
показывать gross PnL, fees, slippage, funding/holding costs, penalties и net
PnL. Real trading остается blocked, пока net paper PnL после costs не станет
stable.

## Research Before Implementation

Перед implementation plan нужен короткий research pass для проверки assumptions,
которые быстро меняются: exchange APIs, fee schedules, Polymarket market-data
behavior, Hyperliquid execution/funding details и recent community reports о
feed reliability.

Research outputs должны быть committed как Markdown notes в `docs/research/`.
Они должны включать source links, dates checked, caveats и design decisions,
которые изменились из-за research. Research не заменяет official docs или
fixtures; он только показывает, что нужно verify.

## RAG и Agents

RAG полезен, но не блокирует первый collector/replay increment.
Repository documentation является source of truth. LightRAG является
development memory и semantic index поверх этого source of truth; он не должен
становиться единственным местом, где живут design decisions, incidents или
runbooks.

Рекомендованный путь:

- Запустить отдельный LightRAG Dev Memory stack для этого проекта. Не
  переиспользовать и не менять существующие ApeRAG/Omniroute containers,
  которые обслуживают другой проект. Docker names, networks, volumes, ports и
  compose project names должны использовать prefix `liquidation`.
- Сначала ingest только repo-owned documentation: `docs/`, specs, runbooks,
  research notes, incident reports, replay reports и strategy notes. Official
  exchange documentation snapshots можно индексировать после normalization и
  commit в `docs/snapshots/`.
- Хранить LightRAG index metadata: indexed Git commit hash, branch, ingestion
  timestamp, indexed paths, ingestion config version и evaluation result.
- Предоставить project commands:
  - `liq-rag ingest docs/`;
  - `liq-rag eval`;
  - `liq-rag health`;
  - `liq-rag status --check-commit`.
- Stale index не считается надежным. Если indexed commit hash не совпадает с
  current Git commit для tracked docs, tooling должен warn или fail closed и
  использовать repository docs напрямую.
- Запускать daily LightRAG health check, который проверяет service
  availability, freshness, evaluation score и storage health. Alert нужен, если
  LightRAG stale, unavailable или ниже retrieval-quality threshold.
- `liq-rag health` должен различать `ok`, `degraded-but-usable` и `failed`.
  `ok` означает, что `liquidation-omniroute` и Kiro combo работают.
  `degraded-but-usable` означает, что `liquidation-omniroute` недоступен, но
  `liquidation-free-deepseek` отвечает напрямую. `failed` означает, что не
  работают ни `liquidation-omniroute`, ни `liquidation-free-deepseek`, или
  LightRAG/index/eval непригодны.
- Добавить automatic quality checks для retrieval через known question/answer
  pairs. Refresh fails или alerts, если top-5 recall или simple answer accuracy
  падает ниже 80% на tracked evaluation set. Mean reciprocal rank reported как
  trend metric, чтобы было видно падение correct document с rank 1 до rank 5.
  Первая реализация может быть небольшим project script; RAGAS является
  follow-up candidate, а не MVP dependency.
- Rebuild или refresh RAG indexes после commits, которые меняют tracked
  documentation sources, а weekly scheduled rebuild оставить как fallback.
- Предоставить manual RAG refresh command для operator-triggered rebuilds после
  срочных API announcements.
- Исключить из ingestion secrets, `.env` files, Infisical exports, private keys,
  exchange credentials и large raw market-data blobs.
- Если LightRAG или его LLM provider unavailable, разработка продолжается по
  repository docs. RAG downtime не должен блокировать collector, replay, CI или
  paper trading work.
- Добавить API documentation change detector, который сравнивает versioned
  official documentation snapshots outside the RAG index. Detector ищет
  breaking/deprecated/new required field signals, создает issue или alert и не
  использует RAG retrieval как source of truth.
- Хранить normalized documentation snapshots как JSON в `docs/snapshots/`.
  Snapshots должны содержать source URL, fetch timestamp, content hash,
  extracted endpoint/schema facts и relevant text excerpts, а не большие raw
  HTML dumps. Scheduled jobs могут открывать PR, когда snapshots меняются.
- Scheduled snapshot jobs генерируют machine-readable diff against previous
  snapshot. Critical changes, например breaking, deprecated, removed, new
  required field и payload format changes, открывают issue или alert;
  noncritical changes идут как normal snapshot update PR.
- Переоценить ApeRAG только позже, если понадобится более тяжелый RAG portal,
  MCP-first workflows или built-in multi-user management. Существующий ApeRAG
  stack не является project dependency для этого repository.

Разрешенные agents:

- Documentation ingestion agent.
- Data-quality report analyst.
- Data-quality review agent.
- Backtest/replay analyst.
- Risk review assistant.
- Release/runbook assistant.

Запрещено на этом этапе:

- Autonomous trade execution agent.
- Agent, который меняет risk limits без явного human approval.

## Acceptance Criteria

Первый инкремент завершен, когда:

- Rust workspace собирается и проходит CI;
- migrations создают required TimescaleDB schema;
- как минимум два liquidation sources можно collect и normalize;
- raw payloads и canonical events persisted durably;
- `liq-cli` rejects invalid configuration with actionable errors;
- `liq-cli replay dry-run` validates inputs без execution strategy transitions;
- archive manifests записывают `parquet_schema_version` и verification
  metadata;
- archive manifests expose `canonical_deletion_watermark` до запуска canonical
  retention deletion;
- collector startup refuses second active writer для same `(source, instrument)`
  lease;
- quality reports запускаются по recorded time window;
- replay производит deterministic paper signals из stored data;
- replay runs записывают strategy version, fill model version, initial state и
  `input_hash`;
- mock load tests показывают, что recorder выдерживает required scenarios без
  data loss:
  - 100 liquidation events in 1 second;
  - weekly long-running 24-hour simulation с average 10 events/second,
    periodic bursts to 100 events/second, memory growth, RSS start/end и write
    latency tracking. Default failure threshold - отсутствие unbounded RSS
    growth и не больше 10% growth, если explicit fixed-memory budget не
    configured;
  - Linux-only file descriptor tracking во время long-running tests через
    `/proc/<pid>/fd` или equivalent tool. Open descriptors не должны расти
    without bound across reconnect cycles;
  - adapter metrics assert, что active WebSocket connection count возвращается
    к expected value после reconnect cycles. Stale active connections fail test,
    даже если file descriptor counts выглядят stable;
  - TimescaleDB restart mid-write: collector reconnects, records error,
    preserves queued events, которые еще не acknowledged as written, и resumes
    writes без silent loss;
  - multi-hour synthetic run с periodic reconnects;
  - two concurrent sources writing to the same database;
  - bounded channel overflow behavior, который records drops explicitly, а не
    теряет events silently;
- strategy corruption tests покрывают duplicate events, missing windows,
  invalid prices, impossible notionals и out-of-order inputs без panics.
  Strategy должна skip или mark invalid data и emit diagnostics;
- все generated paper orders/fills явно помечены как simulated;
- dashboard requirements documented и остаются read-only для MVP;
- replay reports включают gross PnL, fees, slippage, penalties и net PnL;
- Docker Compose usage scoped to project name `liquidation` и не влияет на
  existing containers других проектов;
- pre-implementation research notes committed для time-sensitive assumptions;
- production trading secret не требуется и не принимается by default.

## Следующие улучшения для автоматизации

- Nightly data-quality report generation.
- Automatic source-feed regression tests из captured raw payload fixtures.
- Source aggregation policy tests для all-events, snapshot-only, fallback и
  excluded-source windows.
- Strategy corruption tests для duplicates, gaps, invalid prices и out-of-order
  events.
- Streaming quality alerts для heartbeat gaps, queue pressure, latency и
  circuit-breaker transitions.
- Configuration validation и resolved-config snapshots для replay runs.
- Schema contract checks из `information_schema.columns`.
- Backfill data migration runners с resume и verification support.
- Documentation snapshot refresh jobs, которые открывают reviewable PRs.
- Documentation snapshot diff jobs, которые классифицируют critical и
  noncritical API changes.
- RAG retrieval-quality checks с 80% minimum score gate.
- Agent report quality checks against golden report fixtures.
- Adapter connection leak checks в long-running load tests.
- DB restart mid-write load test.
- Single-writer source lease check для collector startup.
- Replay `input_hash` reuse и `replay dry-run` checks.
- Parquet schema reader registry compatibility tests.
- Signal weighting research только для future all-events sources; snapshot-only
  Binance не должен получать production signal weight в MVP.
- Replay-from-archive для deep backtests over Parquet.
- RAG ingestion official docs и generated reports.
- API documentation change detection with operator alerts.
- Parquet export после schema stabilization.
- Retention и compression policy checks для TimescaleDB hypertables.
- Archive manifest verification и retry alerts.
- Storage budget reporting для database и Parquet archives.
- English/Russian spec synchronization check.
- Scheduled RAG index refresh и retrieval-quality checks.
- Alerting для collector downtime, feed gaps и abnormal source divergence.
- Read-only operational dashboard с visual и responsive QA.
- Fee schedule ingestion и fee-adjusted replay reports.
- Docker safety checks для compose project name, ports, networks и volumes.
- Pre-implementation research checklist и report template.
