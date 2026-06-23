# Deferred Ideas Backlog

Цель: хранить все решения формата "не делаем сейчас, но не забыть" вне чата.
Если идея отложена, она должна попасть сюда или в более конкретный runbook с
ссылкой из этого файла.

## Правило

Нельзя оставлять postponed/parking-lot идеи только в чате. Для каждой идеи нужно
записать:

- что именно отложено;
- почему сейчас не делаем;
- когда возвращаемся;
- что будет считаться готовностью начать;
- связанный runbook/spec.

## Backlog

### GitHub Artifact Trend Comparator

**Статус:** deferred.

**Что это:** сравнение nightly GitHub Actions artifacts между датами, чтобы
видеть тренд качества источников: OKX usefulness, stale/ok status, raw/canonical
events, overlap buckets, metadata validity, API docs changelog warnings.

**Почему не сейчас:** это полезный reliability/ops слой, но он не блокирует
переход к pre-strategy increment. Сейчас главный bottleneck - отсутствие
Polymarket market-data recorder, Hyperliquid hedge/paper model, fee/funding
model и deterministic replay harness.

**Когда возвращаемся:**

- после минимального Polymarket recorder, Hyperliquid paper hedge model и replay
  foundation;
- раньше, если nightly market-data diagnostics или API docs changelog начинают
  регулярно давать warnings;
- обязательно перед длительным paper soak, потому что там нужен trend across
  days, а не только последний snapshot.

**Готовность начать:**

- есть несколько nightly artifacts в GitHub Actions;
- `scripts/market-data-report-history.ps1` стабильно строит локальный trend;
- `scripts/gh-project.ps1` умеет читать runs/artifacts через project-local GitHub
  auth.

**Ожидаемый результат:**

- `scripts/market-data-report-history-from-github.ps1` или аналогичный wrapper;
- краткий Markdown/JSON report по нескольким GitHub artifact runs;
- warning, если OKX/source coverage ухудшается;
- dashboard/future alerting могут читать JSON без парсинга Markdown.

**Связанные файлы:**

- `docs/runbooks/strategy-readiness.md`
- `docs/runbooks/source-addition.md`
- `scripts/market-data-report-history.ps1`
- `.github/workflows/nightly-market-data.yml`

### Replay From Archive

**Статус:** deferred.

**Что это:** режим replay, который читает Parquet archives напрямую, минуя hot
TimescaleDB.

**Почему не сейчас:** сначала нужен минимальный deterministic replay over hot
data. Archive replay важен для глубоких backtests, но не блокирует первый
strategy replay.

**Когда возвращаемся:** после появления archive export/verification и первого
рабочего replay harness.

**Связанные файлы:**

- `docs/superpowers/specs/2026-06-19-data-foundation-paper-replay-design.md`
- `docs/runbooks/rag-operations.md`

### Dashboard Trend Charts

**Статус:** deferred.

**Что это:** визуальные trend charts в dashboard для latency, freshness,
reconnects, source coverage и replay artifacts over time.

**Почему не сейчас:** текущий dashboard уже читает `collector status --json`,
history endpoint и latest replay artifact. До первого качественного paper replay
важнее корректность data/replay gates, чем дополнительная визуальная шлифовка.

**Когда возвращаемся:** после нескольких реальных paper replay windows и
nightly diagnostics, когда появятся данные для meaningful trend, а не просто
один snapshot.

**Готовность начать:**

- есть несколько replay/market-data artifacts за разные окна;
- `scripts/market-data-report-history.ps1` стабильно строит trend JSON;
- dashboard smoke tests готовы проверять desktop/mobile screenshots.

**Связанные файлы:**

- `docs/runbooks/dashboard.md`
- `scripts/market-data-report-history.ps1`
- `.github/workflows/nightly-market-data.yml`

### Collector Run Minimum Useful Data Policy

**Статус:** deferred.

**Что это:** для long-running `collector run` добавить source-specific minimum
useful data policy: `min_messages`, `min_raw_events`, `min_canonical_events` или
`min_market_events` за окно, чтобы source не считался healthy, если WebSocket
жил, но не дал replay-useful data.

**Почему не сейчас:** bounded probes и replay preflight уже fail-closed по
данным. Long-running service semantics надо проектировать аккуратно: для
snapshot-only/diagnostic sources и тихих market windows ноль canonical events не
всегда означает failure.

**Когда возвращаемся:** перед длительным paper soak или перед первым
автоматическим collector service, который должен работать часами без оператора.

**Готовность начать:**

- source coverage policy явно разделяет signal source, diagnostic source и
  snapshot-only source;
- dashboard умеет показывать `empty`/`stale` отдельно от `failed`;
- есть fixture tests для quiet-but-connected source и broken source.

**Связанные файлы:**

- `crates/liq-collector/src/runtime.rs`
- `crates/liq-cli/src/main.rs`
- `docs/runbooks/dashboard.md`

### Raw Diagnostics For Ignored Source Payloads

**Статус:** deferred.

**Что это:** сохранять diagnostic raw rows для subscription acks, source errors,
ignored market-data message types и unsupported payloads, не превращая их в
canonical events.

**Почему не сейчас:** текущий recorder уже сохраняет raw/canonical для полезных
events и OKX raw-only cases. Расширение raw diagnostics требует отдельного
schema/source_quality решения, чтобы не раздувать hot storage шумом.

**Когда возвращаемся:** перед длительным live collection или если dashboard
показывает stale/empty source без понятной причины.

**Готовность начать:**

- определены `source_quality`/`diagnostic_kind` значения для ack/error/ignored;
- retention для diagnostic raw rows не конфликтует с hot raw retention;
- dashboard/quality reports умеют показать diagnostic payload counts.

**Связанные файлы:**

- `crates/liq-collector/src/runtime.rs`
- `crates/liq-collector/src/source.rs`
- `docs/runbooks/dashboard.md`

### GitHub Issue For API Changelog Warnings

**Статус:** deferred.

**Что это:** автоматическое создание GitHub issue, если nightly API docs
changelog detector находит breaking/deprecated/required-field warning.

**Почему не сейчас:** detector уже может формировать warning, но автоматическое
создание issue требует стабильного project-scoped GitHub auth и защиты от
noise/spam. Пока достаточно artifact/report warning.

**Когда возвращаемся:** после стабилизации scheduled nightly jobs и пары недель
наблюдения за false-positive rate.

**Готовность начать:**

- changelog detector стабильно отличает critical warning от информационного
  изменения;
- `scripts/gh-project.ps1` проходит `api user`, `repo view` и `run list`;
- есть runbook policy, когда issue открывается, обновляется или закрывается.

**Связанные файлы:**

- `scripts/check-api-docs-changelog.ps1`
- `docs/runbooks/source-addition.md`
- `.github/workflows/nightly-market-data.yml`

### Extra Diagnostic Exchanges After OKX

**Статус:** deferred.

**Что это:** добавление новых diagnostic liquidation sources сверх Bybit,
Binance и OKX.

**Почему не сейчас:** текущий bottleneck не в количестве liquidation sources, а
в отсутствии второй стороны стратегии: Polymarket data, Hyperliquid hedge model,
fees/funding и replay.

**Когда возвращаемся:** после strategy replay foundation или если current source
coverage деградирует по nightly diagnostics.

**Связанные файлы:**

- `docs/runbooks/source-addition.md`
- `docs/runbooks/strategy-readiness.md`

## Что улучшить или автоматизировать

Добавить guard, который ищет слова `later`, `deferred`, `postponed`, `nice to
have`, `parking lot` в docs и требует ссылку на этот backlog или явный reason в
том же файле.
