# Strategy Readiness Runbook

Цель: отделить задачи, которые блокируют переход к strategy/replay, от
полезной, но неблокирующей шлифовки data reliability.

## Где уже лежит план

- Основной design: `docs/superpowers/specs/2026-06-19-data-foundation-paper-replay-design.md`.
- Русская копия design: `docs/superpowers/specs/2026-06-19-data-foundation-paper-replay-design-ru.md`.
- Foundation implementation plan: `docs/superpowers/plans/2026-06-19-data-foundation-increment-1.md`.
- Source addition checklist: `docs/runbooks/source-addition.md`.
- Fee model runbook: `docs/runbooks/fee-model.md`.
- Research refresh policy: `docs/runbooks/research-before-implementation.md`.

Отдельного strategy-readiness checklist до этого runbook не было. Это было
плохо: решение оставалось частично в чате и могло потеряться.

## Blocking Before Strategy

Переход к strategy implementation разрешен только после этих пунктов:

1. Polymarket market-data recorder.
   - Public market WebSocket подключается без trading credentials.
   - Записываются order book snapshots/changes и trades, достаточные для paper
     fill model.
   - Есть raw persistence и canonical market quote/trade model.
   - Есть bounded live probe и fixture regression tests.

2. Hyperliquid hedge market-data model.
   - Записываются best bid/ask или L2 snapshots для hedge simulation.
   - Fee/funding assumptions versioned and dated.
   - Есть hedge timeout, slippage model и failed/partial hedge states.
   - Реальные ордера запрещены.

3. Fee model.
   - Polymarket fees или explicit zero-fee assumption с source/date.
   - Hyperliquid maker/taker fees.
   - Funding/holding cost для hedge.
   - Replay report показывает gross PnL, fees, funding, slippage и net PnL.

4. Deterministic replay harness.
   - Есть `Strategy` trait.
   - Есть `input_hash` для replay inputs.
   - Повторный replay с теми же inputs воспроизводим.
   - Есть `replay dry-run` для проверки доступности данных.

5. Fill model.
   - MVP default: conservative `trade_cross`.
   - `book_touch` допускается только как optimistic diagnostic.
   - `book_depth_cross` не включается, пока не доказана полнота L2 depth.
   - Незаполненные ордера отменяются через `order_cancel_window`.

6. Paper-only safety.
   - Real Polymarket orders disabled.
   - Real Hyperliquid orders disabled.
   - Любая команда live execution должна fail-closed без explicit paper/live
     mode и safety confirmation.

## Nice To Have Before Strategy

Эти задачи полезны, но не блокируют начало strategy/replay:

- GitHub artifact trend comparator между nightly runs.
- Более красивые dashboard trend charts.
- Дополнительные diagnostic sources после OKX.
- Replay-from-archive по Parquet.
- Автоматическое создание GitHub issue при API docs changelog warning.

Все postponed идеи должны быть записаны в `docs/backlog/deferred-ideas.md`.
Если идея есть только в чате, она считается незаписанной.

## Когда возвращаться к Artifact Trend Comparator

`artifact trend comparator` нужно делать:

- после минимального Polymarket recorder и Hyperliquid paper hedge model, если
  цель - быстрее перейти к strategy replay;
- раньше, если nightly market-data diagnostics или API docs changelog начинают
  регулярно давать warnings;
- перед длительным paper soak, потому что там уже важны trends across days, а не
  только snapshot последнего запуска.

Сейчас он не является blocker для pre-strategy increment.
Подробная карточка задачи находится в `docs/backlog/deferred-ideas.md`.

## Выполненные Pre-Strategy Increments

Уже реализовано:

1. Polymarket public market-data connector и bounded probe.
2. Polymarket recorder schema/tests for market quotes/trades.
3. Hyperliquid market-data connector for hedge simulation.
4. Fee/funding/slippage model with versioned assumptions.
5. Replay harness foundation with `Strategy` trait and `input_hash`.
6. Baseline strategy port из Python в Rust.
7. Paper replay runner поверх сохранённых liquidation + Polymarket +
   Hyperliquid rows.

## Current Code Gate

Команда:

```powershell
cargo run -p liq-cli -- strategy readiness --json
```

показывает текущий fail-closed статус. После pre-strategy foundation increment
в коде уже есть:

- canonical `MarketQuote` / `MarketTrade` domain types for Polymarket and
  Hyperliquid;
- TimescaleDB tables and insert boundaries for `market_quotes` and
  `market_trades`;
- deterministic `ReplayInput` and `input_hash`;
- `Strategy` trait skeleton;
- MVP fill models: conservative `trade_cross` and diagnostic `book_touch`;
- explicit fee/funding/slippage model for Polymarket + Hyperliquid;
- paper-only safety gate that rejects live mode by default.

После baseline port code gate включает:

- `BaselineStinkBidStrategy` с static Python-compatible parameters:
  `25_000..100_000` USD liquidation band, `10m` rolling window, `30%`
  pullback, `$15` Polymarket paper notional and `60s` order cancel window;
- long liquidations -> DOWN stink bid on Polymarket and LONG Hyperliquid hedge
  intent;
- short liquidations -> UP stink bid on Polymarket and SHORT Hyperliquid hedge
  intent;
- no live order placement: generated output is a deterministic paper
  `StrategySignal`.

Это не значит, что strategy можно запускать по stale данным. Gate намеренно
оставляет `ready_for_strategy = false`, если не закрыты актуальные live-data
conditions внутри выбранного окна:

- public Polymarket market-data probe;
- Hyperliquid hedge market-data probe;

После market-data legs proof increment эти conditions закрываются автоматически
по фактическим rows в TimescaleDB:

- `polymarket_live_probe`: есть хотя бы одна строка `market_quotes` или
  `market_trades` с `venue = 'polymarket'` внутри readiness window;
- `hyperliquid_market_data_probe`: есть и quote rows, и trade rows с
  `venue = 'hyperliquid'` внутри readiness window.
- `baseline_strategy_port`: code capability present.

Локальная проверка:

```powershell
cargo run -p liq-cli -- collector probe --database-url "postgres://liquidation:liquidation@127.0.0.1:15433/liquidation" --source polymarket --symbol <polymarket_asset_id> --max-messages 40 --min-messages 1 --read-timeout-seconds 60
cargo run -p liq-cli -- collector probe --database-url "postgres://liquidation:liquidation@127.0.0.1:15433/liquidation" --source hyperliquid --symbol BTC --max-messages 40 --min-messages 1 --read-timeout-seconds 60
cargo run -p liq-cli -- strategy readiness --database-url "postgres://liquidation:liquidation@127.0.0.1:15433/liquidation" --window-minutes 60 --json
cargo run -p liq-cli -- strategy readiness explain --database-url "postgres://liquidation:liquidation@127.0.0.1:15433/liquidation" --window-minutes 60 --json
```

`strategy readiness explain --json` нужен для отладки перед paper replay: он
печатает raw counts и per-condition pass/fail, например
`polymarket_quotes > 0 OR polymarket_trades > 0` и observed
`quotes=N trades=M`.

## Paper Replay Run

Перед replay нужно сохранить metadata выбранного BTC 5-minute рынка Polymarket.
Это отдельная таблица `polymarket_markets`; она нужна, чтобы оператор не
передавал `market_id`, `up_token_id`, `down_token_id` руками при каждом run.

Рекомендуемый путь - safe fetcher из Polymarket Gamma API:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/fetch-polymarket-markets.ps1 `
  -OutputPath ".cache/polymarket/selected-markets.json" `
  -Json
```

По умолчанию это dry-run: команда скачивает metadata, валидирует:

- `market_id`;
- `up_token_id`;
- `down_token_id`;
- `startDate/endDate`;
- ровно 5-minute window для `btc_5m`;
- текстовый фильтр `bitcoin` + `up or down`;
- outcomes `Up` и `Down`.

Запись в TimescaleDB разрешена только через явный `-Apply`. Скрипт сначала
делает dry-run и только после успешной валидации запускает apply:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/fetch-polymarket-markets.ps1 `
  -DatabaseUrl "postgres://liquidation:liquidation@127.0.0.1:15433/liquidation" `
  -Apply `
  -Json
```

Если Gamma API меняет выдачу или нужный рынок не попадает в default endpoint,
разрешено передать explicit endpoint/query:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/fetch-polymarket-markets.ps1 `
  -EndpointUrl "https://gamma-api.polymarket.com/markets?active=true&closed=false" `
  -OutputPath ".cache/polymarket/selected-markets.json" `
  -Json
```

Пример upsert metadata:

```powershell
cargo run -p liq-cli -- replay market upsert `
  --database-url "postgres://liquidation:liquidation@127.0.0.1:15433/liquidation" `
  --market-id "<polymarket-market-id-or-slug>" `
  --slug "<optional-polymarket-slug>" `
  --title "<optional-question-title>" `
  --base-asset BTC `
  --market-type btc_5m `
  --up-token-id "<polymarket-up-token-id>" `
  --down-token-id "<polymarket-down-token-id>" `
  --start-unix-ms <start_ms> `
  --end-unix-ms <end_ms> `
  --status open `
  --source manual
```

Проверить последние рынки:

```powershell
cargo run -p liq-cli -- replay market list `
  --database-url "postgres://liquidation:liquidation@127.0.0.1:15433/liquidation" `
  --base-asset BTC `
  --market-type btc_5m `
  --json
```

Перед первым реальным paper replay обязательно запускать preflight:

```powershell
cargo run -p liq-cli -- replay preflight `
  --database-url "postgres://liquidation:liquidation@127.0.0.1:15433/liquidation" `
  --strategy baseline `
  --latest-polymarket-market `
  --fill-model trade_cross `
  --hedge-notional-usd 15 `
  --hyperliquid-taker-bps 5 `
  --hyperliquid-funding-bps-per-hour 1 `
  --hedge-slippage-usd 0.10 `
  --funding-hours 1 `
  --market-stale-after-minutes 15 `
  --json
```

`replay preflight` возвращает non-zero exit code, если replay window нельзя
считать качественным. Он блокирует:

- stale Polymarket market metadata;
- не-5-minute market window;
- пустые liquidation rows;
- пустые Polymarket quote/trade rows;
- пустые Hyperliquid quote/trade rows;
- optimistic `book_touch` вместо conservative `trade_cross`;
- полностью нулевые cost assumptions;
- non-zero Hyperliquid funding без положительного `funding-hours`.

Для сбора одного свежего BTC 5-minute окна без ручного ввода market id и token
id используем:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/collect-paper-replay-window.ps1 `
  -DatabaseUrl "postgres://liquidation:liquidation@127.0.0.1:15433/liquidation" `
  -MaxRuntimeSeconds 330 `
  -RunReplay
```

Скрипт делает:

- fetch/upsert свежего Polymarket BTC 5-minute market metadata;
- ожидание следующего окна, если текущий рынок почти завершился;
- параллельный read-only сбор Bybit/Binance/OKX liquidation feeds;
- параллельный read-only сбор Polymarket UP/DOWN token market data;
- параллельный read-only сбор Hyperliquid BTC market data;
- `replay preflight` перед запуском `replay run`.

Важно: если в окне нет liquidation events, preflight обязан упасть. Это не
ошибка инфраструктуры, а корректный отказ от пустого strategy replay без
signal source. В таком случае запускаем следующий window, а не снижаем gate.

Чтобы автоматизировать ожидание окна с liquidation events, используйте bounded
wrapper:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/wait-for-liquidation-replay.ps1 `
  -DatabaseUrl "postgres://liquidation:liquidation@127.0.0.1:15433/liquidation" `
  -MaxWindows 6 `
  -MaxRuntimeSeconds 330
```

Wrapper продолжает следующий Polymarket 5-minute window только если preflight
упал по причине `liquidations=0`. Любая другая ошибка collector/replay
останавливает процесс, чтобы не маскировать инфраструктурный сбой.

Команда:

```powershell
cargo run -p liq-cli -- replay run `
  --database-url "postgres://liquidation:liquidation@127.0.0.1:15433/liquidation" `
  --strategy baseline `
  --market-id "<polymarket-market-id-or-slug>" `
  --up-token-id "<polymarket-up-token-id>" `
  --down-token-id "<polymarket-down-token-id>" `
  --start-unix-ms <start_ms> `
  --end-unix-ms <end_ms> `
  --fill-model trade_cross `
  --hedge-notional-usd 15 `
  --hyperliquid-taker-bps 5 `
  --hyperliquid-funding-bps-per-hour 1 `
  --hedge-slippage-usd 0.10 `
  --funding-hours 1 `
  --market-stale-after-minutes 15 `
  --json
```

Auto mode по последнему известному рынку:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/run-latest-polymarket-replay.ps1 `
  -DatabaseUrl "postgres://liquidation:liquidation@127.0.0.1:15433/liquidation" `
  -ArtifactPath ".cache/replay/latest-polymarket-baseline.json" `
  -FetchMetadataFirst
```

Auto mode fail-closed:

- `scripts/run-latest-polymarket-replay.ps1` сначала запускает
  `replay preflight`; если есть blockers, replay не стартует и artifact не
  создаётся;
- если preflight или replay падает, старый replay artifact удаляется до запуска,
  чтобы dashboard не показывал stale success;
- `scripts/collect-paper-replay-window.ps1 -RunReplay` после выбора market
  запускает preflight/replay по pinned `market_id`, `up_token_id`,
  `down_token_id`, `start_unix_ms` и `end_unix_ms`; он не проверяет другой
  "latest" market в конце окна;
- нельзя смешивать `--latest-polymarket-market` с ручными
  `--market-id/--up-token-id/--down-token-id/--start-unix-ms/--end-unix-ms`;
- если metadata для `base_asset + market_type` отсутствует, replay не
  запускается;
- artifact является JSON contract для dashboard/CI и не требует парсинга
  консольного вывода.
- scheduled GitHub workflow `Replay Artifact` запускается каждые 6 часов, но
  делает реальный replay только если в GitHub secrets задан
  `REPLAY_DATABASE_URL`. Без этого secret workflow честно пропускает runtime
  replay, чтобы не создавать пустой псевдо-отчёт.

Что делает команда:

- читает `liquidation_events`, `market_quotes`, `market_trades` из TimescaleDB
  за указанный interval;
- строит active `BaselineMarket` из явно переданных полей или из последней
  строки `polymarket_markets`;
- прогоняет `BaselineStinkBidStrategy`;
- проверяет Polymarket entry через выбранный fill model:
  `trade_cross` по умолчанию, `book_touch` только diagnostic;
- после Polymarket fill пытается смоделировать Hyperliquid hedge по первой
  recorded BTC hedge trade внутри hedge window;
- считает `gross_pnl_usd`, `fees`, `funding`, `slippage`,
  `net_unsettled_pnl_usd`, `max_drawdown_usd`, `fill counts` и
  `unhedged_signals`.

Важное ограничение: `settlement_status = unsettled`. MVP paper replay не
моделирует финальное settlement Polymarket outcome, потому что в текущей схеме
нет outcome-resolution feed. Поэтому этот отчёт доказывает execution/cost/risk
часть стратегии, но ещё не является полным историческим PnL по экспирации.

## Что улучшить или автоматизировать

CLI gate уже добавлен:

```powershell
cargo run -p liq-cli -- strategy readiness --json
```

Команда проверяет, что recorder, Polymarket data, Hyperliquid hedge data, fees,
replay config, baseline strategy и safety mode готовы. Если хотя бы один
condition не закрыт в текущем readiness window, strategy run должен быть
запрещен.

Следующая автоматизация: trend comparator для scheduled replay artifacts и
отдельный warning, если scheduled replay workflow несколько запусков подряд
пропущен из-за отсутствующего `REPLAY_DATABASE_URL`.
