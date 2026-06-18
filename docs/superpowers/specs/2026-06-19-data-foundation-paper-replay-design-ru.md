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
- `source`: название биржи или provider.
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

Money и sizes не должны использовать `f64` в domain или database boundaries. Rust
domain types используют decimal-safe representations.

Adapters должны вычислять `notional_usd` из venue data, обычно как
`quantity * price`, если venue не дает notional напрямую. Если price или
quantity отсутствует, normalized event сохраняется с validation status `invalid`
и exclusion reason, но исключается из strategy aggregation.

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

Initial backfill policy:

- Binance: disabled для market liquidation recovery, потому что доступный
  official force-order REST endpoint является authenticated USER_DATA.
- OKX: allowed как experimental bounded backfill source после fixture-тестов
  endpoint parameters, retention window и duplication behavior.
- Bybit: disabled, пока current official public REST liquidation-history page и
  endpoint probe не будут добавлены в репозиторий.

## Recorder

TimescaleDB является primary storage для MVP, потому что первая проблема -
time-series queryability, а не дешевый архив.

Таблицы:

- `raw_source_events`: immutable audit trail raw payloads.
- `liquidation_events`: canonical normalized liquidation events.
- `market_quotes`: Polymarket и futures quote snapshots/events.
- `collector_health`: reconnects, heartbeat gaps, adapter errors, lag.
- `strategy_signals`: replayed или paper-generated signals.
- `paper_orders`: simulated orders.
- `paper_fills`: simulated fills.
- `replay_runs`: deterministic replay configuration, initial state, strategy
  version и fill model version.
- `daily_quality_reports`: materialized daily summaries.

Retention policies являются частью recorder design. Canonical events хранятся в
TimescaleDB для queryability. Raw payloads хранятся отдельно от canonical event
tables в minimally indexed hot audit table:

- indexes ограничены event ID, source и received time;
- payload bytes сжимаются до записи;
- hot raw retention для MVP начинается с 7 days и является configurable;
- scheduled archive job экспортирует cold raw payloads в Parquet на диске;
- после archive verification старые hot raw rows можно удалять.

Если measured storage growth пересечет configured limit, follow-up design
переносит cold raw payload blobs из local Parquet в S3-compatible object store,
а в TimescaleDB оставляет только content hashes и object references.

## Paper Replay Harness

Replay должен поддерживать два режима:

- Historical replay: читать recorded events за временное окно и
  детерминированно воспроизводить стратегию.
- Paper-live: потреблять текущие recorded events только с paper orders.

Для детерминизма replay требуется:

- каждый run записывает strategy version, fill model version, input time window,
  initial balances и initial positions;
- все inputs берутся из stored liquidation, quote, trade и futures data;
- ordering использует recorded exchange timestamps с deterministic tie-breaking
  по receive timestamp и event ID;
- execution simulation rules версионируются и immutable для завершенного run.

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
slippage model.

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

Reports генерируются через CLI, а позже планируются через GitHub Actions или
server cron/systemd timer. Они должны записываться в Markdown и machine-readable
JSON.

Data Quality Review Agent может summarize daily reports, сравнивать их с prior
reports и flag trends, например rising latency или source divergence. Он только
advisory и не должен менять collector settings, strategy thresholds или risk
limits.

## CI и Developer Workflow

Обязательные checks:

- `cargo fmt --check`
- `cargo clippy --workspace --all-targets --all-features -- -D warnings`
- `cargo test --workspace --all-features`
- `sqlx migrate run` против development database
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
`cargo deny` является follow-up до существенного роста dependency set. Initial
policy должна быть узкой: approved licenses и advisory checks only. Делать его
обязательным до scaffold workspace добавит noise без улучшения первого design
decision.

## Deployment Model

Local development:

- Windows host подходит для editing и tests.
- Docker Compose предоставляет TimescaleDB и optional support services.
- Development database по умолчанию использует persistent volume.
- Adminer или pgAdmin можно открыть только через dev-only Compose profile, но не
  в default service set.
- Rust binaries запускаются с host во время разработки.

Server/paper-live:

- Linux VPS или dedicated server.
- systemd или Docker Compose могут запускать collectors.
- Infisical вводится до того, как потребуются private keys или authenticated
  trading credentials.

Production live trading намеренно исключен.

## RAG и Agents

RAG полезен, но не блокирует первый collector/replay increment.

Рекомендованный путь:

- Начать с LightRAG как lightweight documentation/research knowledge base.
- Ingest official exchange docs, architecture docs, runbooks, incident reports,
  replay reports и strategy notes.
- Добавить automatic quality checks для retrieval через known question/answer
  pairs.
- Rebuild или refresh RAG indexes по расписанию, изначально weekly, и после
  commits, которые меняют tracked documentation sources.
- Предоставить manual RAG refresh command для operator-triggered rebuilds после
  срочных API announcements.
- Переоценить ApeRAG, если понадобится более тяжелый RAG portal,
  MCP-first workflows или built-in multi-user management.

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
- quality reports запускаются по recorded time window;
- replay производит deterministic paper signals из stored data;
- replay runs записывают strategy version, fill model version и initial state;
- mock load tests показывают, что recorder выдерживает required scenarios без
  data loss:
  - 100 liquidation events in 1 second;
  - multi-hour synthetic run с periodic reconnects;
  - two concurrent sources writing to the same database;
  - bounded channel overflow behavior, который records drops explicitly, а не
    теряет events silently;
- все generated paper orders/fills явно помечены как simulated;
- production trading secret не требуется и не принимается by default.

## Следующие улучшения для автоматизации

- Nightly data-quality report generation.
- Automatic source-feed regression tests из captured raw payload fixtures.
- RAG ingestion official docs и generated reports.
- Parquet export после schema stabilization.
- Retention и compression policy checks для TimescaleDB hypertables.
- English/Russian spec synchronization check.
- Scheduled RAG index refresh и retrieval-quality checks.
- Alerting для collector downtime, feed gaps и abnormal source divergence.
