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
  --json
```

Что делает команда:

- читает `liquidation_events`, `market_quotes`, `market_trades` из TimescaleDB
  за указанный interval;
- строит active `BaselineMarket` из явно переданных `market_id`,
  `up_token_id`, `down_token_id`;
- прогоняет `BaselineStinkBidStrategy`;
- проверяет Polymarket entry через выбранный fill model:
  `trade_cross` по умолчанию, `book_touch` только diagnostic;
- после Polymarket fill пытается смоделировать Hyperliquid hedge по первой
  recorded trade внутри hedge window;
- считает `gross_pnl_usd`, `fees`, `funding`, `slippage`, `net_pnl_usd`,
  `max_drawdown_usd`, `fill counts` и `unhedged_signals`.

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

Следующая автоматизация: добавить market metadata store для Polymarket 5-minute
BTC рынков, чтобы `market_id`, `up_token_id`, `down_token_id` не передавались
вручную в `replay run`.
