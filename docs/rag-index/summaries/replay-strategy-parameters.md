# Replay Strategy Parameters Memory

Дата: 2026-06-24

## Ключевое решение

`liquidation_threshold_max_usd = 100000` не должен восприниматься как
жёсткая константа стратегии. Это операторский параметр baseline replay, такой
же как `liquidation_threshold_min_usd`, `pullback_pct`,
`polymarket_usd_per_position` и `order_cancel_window_seconds`.

## Текущие baseline defaults

- `liquidation_threshold_min_usd = 25000`
- `liquidation_threshold_max_usd = 100000`
- `pullback_pct = 0.30`
- `polymarket_usd_per_position = 15`
- `order_cancel_window_seconds = 60`

## Диагностический профиль

`research-wide-threshold` расширяет только верхний liquidation threshold до
`1000000`. Это не production strategy и не разрешение снижать качество
fill/hedge model. Профиль нужен для сравнения с baseline на real controlled
paper replay windows, когда aggregate analyzer показывает много rejection
reasons `liquidation_notional_above_threshold`.

## Реализация

- `liq replay run/preflight` принимает `--replay-profile` и явные overrides
  для strategy knobs.
- `scripts/controlled-replay.ps1`,
  `scripts/wait-for-liquidation-replay.ps1`,
  `scripts/collect-paper-replay-window.ps1` и
  `scripts/run-latest-polymarket-replay.ps1` прокидывают параметры до Rust
  replay.
- Replay artifact содержит `strategy_parameters`, чтобы dashboard, CI и
  оператор видели, какими ручками получен результат.
- `scripts/compare-replay-profiles.ps1` сравнивает baseline и
  `research-wide-threshold` на одном pinned Polymarket market window. Это
  обязательное правило: нельзя сравнивать профили на разных windows, иначе
  результат смешивает эффект threshold с разными рыночными условиями.

## Первое реальное сравнение профилей

Дата запуска: 2026-06-24.

Market: `2657002`, slug `btc-updown-5m-1782324300`,
`2026-06-24T18:05:00Z..2026-06-24T18:10:00Z`.

- baseline: `liquidations=10`, `signal_count=0`, `polymarket_fills=0`,
  `net_pnl_usd=0`.
- baseline blockers: `liquidation_notional_above_threshold=4`,
  `liquidation_notional_below_threshold=6`.
- `research-wide-threshold`: `signal_count=1`, `polymarket_orders=1`,
  `polymarket_fills=0`, `net_pnl_usd=0`.
- research blocker: `polymarket_entry_not_filled=1`.

Вывод: расширенный threshold даёт больше валидных signals на этом окне, но
не доказывает edge, потому что Polymarket entry не был filled.

## Первый aggregate comparison

Дата запуска: 2026-06-24.

`scripts/compare-replay-profiles-aggregate.ps1` был запущен на двух completed
comparisons. Итог:

- baseline: `signals=0`, `polymarket_fills=0`, `net_pnl_usd=0`;
- `research-wide-threshold`: `signals=0`, `polymarket_fills=0`,
  `net_pnl_usd=0`;
- delta research vs baseline: `signals=0`, `fills=0`, `net_pnl_usd=0`;
- dominant blocker: `order_cancel_window`, count `18` для обоих профилей;
- secondary blocker: `liquidation_notional_below_threshold`, count `2` для
  обоих профилей.

Вывод: aggregate-серия показала, что в этих windows проблема была не в
верхнем threshold, а в близости событий к экспирации Polymarket market.
Baseline defaults нельзя менять по этой серии.

## Aggregate smoke после добавления diagnostic summary

Дата запуска: 2026-06-24.

`MaxComparisons=1`, `MaxWindowsPerComparison=6`.

- baseline: `signals=1`, `polymarket_orders=1`, `polymarket_fills=0`,
  `net_pnl_usd=0`;
- `research-wide-threshold`: `signals=1`, `polymarket_orders=1`,
  `polymarket_fills=0`, `net_pnl_usd=0`;
- delta research vs baseline: `signals=0`, `fills=0`, `net_pnl_usd=0`;
- diagnostic summary: signals were observed, but no Polymarket entry filled.

Вывод: в этом окне расширенный threshold не дал преимущества над baseline.
Практический bottleneck - entry fill, а не изменение верхнего threshold.

## Не делать

- Не снижать thresholds ради красивого `signal_count > 0`.
- Не считать `research-wide-threshold` заменой baseline.
- Не переходить к real trading на основе диагностического профиля.
- Не менять baseline defaults по одному окну без aggregate comparison over
  multiple windows.
- Не интерпретировать `order_cancel_window` blockers как доказательство плохого
  liquidation threshold.
