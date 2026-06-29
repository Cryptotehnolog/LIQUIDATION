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

**Статус:** promoted to scoped source-expansion design.

**Что это:** добавление новых diagnostic liquidation sources сверх Bybit,
Binance и OKX.

**Новое решение от 2026-06-29:** после real controlled replay windows и
наблюдений через Coinglass приоритет расширения зафиксирован так:
`Hyperliquid research/probe -> Bitget diagnostic -> Gate diagnostic`, а HTX
отложен до доказанного coverage blocker.

**Почему это не удалено из backlog:** сам пункт больше не является расплывчатой
идеей, но реализация остается staged. Новые источники нельзя сразу включать в
strategy signals; они идут через diagnostic-only gates и source usefulness
report.

**Связанные файлы:**

- `docs/runbooks/source-addition.md`
- `docs/runbooks/strategy-readiness.md`
- `docs/research/liquidation-source-expansion-2026-06-29.md`

### HTX Diagnostic Source

**Статус:** deferred.

**Что это:** добавить HTX USDT-M liquidation_orders как diagnostic-only source
для BTC liquidation coverage.

**Почему не сейчас:** Bitget и Gate уже добавлены как diagnostic-only источники.
Следующий bottleneck нужно искать в controlled replay, entry fill, hedge fill,
fees/slippage и net PnL. Добавление HTX сейчас может затянуть нас в бесконечное
расширение collector coverage до проверки экономики стратегии.

**Когда возвращаемся:**

- controlled replay series по текущим sources не набирает достаточно
  `signal_count > 0` окон;
- source usefulness report показывает мало
  `liquidation_ready_buckets_without_primary`;
- несколько независимых наблюдений Coinglass показывают material HTX BTC
  liquidations, когда Binance/Bybit/OKX/Bitget/Gate молчат;
- перед server/paper-soak source coverage окажется главным bottleneck.

**Готовность начать:**

- official HTX docs/changelog review;
- fixture payload для USDT-M BTC liquidation_orders;
- parser/normalizer test с доказанным `notional_usd`;
- bounded live probe и dashboard/source policy visibility.

**Связанные файлы:**

- `docs/runbooks/source-addition.md`
- `docs/research/bitget-gate-htx-liquidation-feeds-2026-06-29.md`
- `docs/rag-index/summaries/liquidation-source-expansion.md`

### Hyperliquid Market-Wide Liquidations

**Статус:** deferred.

**Что это:** получение market-wide liquidation events с Hyperliquid через
official node output / `hl-visor`, а не через обычный public WebSocket channel.

**Почему не сейчас:** официальный путь слишком тяжелый для быстрой локальной
итерации: node output требует отдельного runner, больших ресурсов и может
создавать очень большие логи. Короткий 60-секундный probe докажет schema, но не
покажет реальную полезность источника для стратегии.

**Когда возвращаемся:**

- после того как cheap public feeds `bitget`, `gate`, `htx` дадут достаточно
  controlled replay windows;
- если paper replay покажет edge и станет понятно, что именно Hyperliquid
  coverage нужен для масштабирования;
- при переносе node-output research на сервер.

**Готовность начать:**

- есть сервер или изолированная Ubuntu 24.04 среда с verified `hl-visor`;
- `scripts/preflight-hyperliquid-node-runner.ps1` возвращает
  `ready-for-bounded-run=true`;
- есть лимиты времени/байт и cleanup policy;
- после raw output готов Rust parser fixture и dedup policy test.

**Связанные файлы:**

- `docs/runbooks/hyperliquid-node-output-probe.md`
- `docs/rag-index/summaries/hyperliquid-node-data.md`
- `docs/rag-index/summaries/liquidation-source-expansion.md`

### Replay Market Quotes Query Optimization

**Статус:** deferred.

**Что это:** оптимизировать чтение `market_quotes` в replay: проверить запросы,
индексы и explain plan для окон Polymarket, где batch comparison читает много
quotes/books.

**Почему не сейчас:** slow SQL warnings появились во время paper-analysis, но
текущие controlled windows и aggregate pullback comparison уже проходят. Сейчас
важнее собрать больше signal windows и понять entry fill/PnL, чем преждевременно
переписывать replay query path.

**Когда возвращаемся:** перед крупными batch/backtest runs, scheduled replay
artifacts или если controlled replay начинает регулярно упираться в timeout.

**Готовность начать:**

- есть несколько replay artifacts с slow query warnings;
- есть representative Polymarket windows с плотными `market_quotes`;
- можно сравнить latency до/после через один и тот же pinned market window.

**Ожидаемый результат:**

- индекс или запрос, который снижает latency чтения `market_quotes`;
- regression test или smoke benchmark на pinned fixture/window;
- runbook note, когда warning считается критичным.

**Связанные файлы:**

- `crates/liq-cli/src/replay.rs`
- `docs/runbooks/replay-profile-comparison.md`

## Что улучшить или автоматизировать

Добавить guard, который ищет слова `later`, `deferred`, `postponed`, `nice to
have`, `parking lot` в docs и требует ссылку на этот backlog или явный reason в
том же файле.
