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

## Следующий Pre-Strategy Increment

Правильный следующий инкремент:

1. Polymarket public market-data connector.
2. Polymarket recorder schema/tests for market quotes/trades.
3. Bounded Polymarket live probe without credentials.
4. Hyperliquid market-data connector for hedge simulation.
5. Fee/funding config with dated assumptions.
6. Replay harness skeleton with `Strategy` trait and `input_hash`.

Baseline strategy port из Python начинается только после этих foundations.

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

Это не значит, что strategy уже можно запускать. Gate намеренно оставляет
`ready_for_strategy = false`, пока не закрыты live-data blockers:

- public Polymarket market-data probe;
- Hyperliquid hedge market-data probe;
- Rust port of the baseline strategy.

После market-data legs proof increment первые два blockers закрываются
автоматически по фактическим rows в TimescaleDB:

- `polymarket_live_probe`: есть хотя бы одна строка `market_quotes` или
  `market_trades` с `venue = 'polymarket'` внутри readiness window;
- `hyperliquid_market_data_probe`: есть и quote rows, и trade rows с
  `venue = 'hyperliquid'` внутри readiness window.

Локальная проверка:

```powershell
cargo run -p liq-cli -- collector probe --database-url "postgres://liquidation:liquidation@127.0.0.1:15433/liquidation" --source polymarket --symbol <polymarket_asset_id> --max-messages 40 --min-messages 1 --read-timeout-seconds 60
cargo run -p liq-cli -- collector probe --database-url "postgres://liquidation:liquidation@127.0.0.1:15433/liquidation" --source hyperliquid --symbol BTC --max-messages 40 --min-messages 1 --read-timeout-seconds 60
cargo run -p liq-cli -- strategy readiness --database-url "postgres://liquidation:liquidation@127.0.0.1:15433/liquidation" --window-minutes 60 --json
```

## Что улучшить или автоматизировать

CLI gate уже добавлен:

```powershell
cargo run -p liq-cli -- strategy readiness --json
```

Команда должна проверять, что recorder, Polymarket data, Hyperliquid hedge data,
fees, replay config и safety mode готовы. Если хотя бы один blocker не закрыт,
strategy run должен быть запрещен.
