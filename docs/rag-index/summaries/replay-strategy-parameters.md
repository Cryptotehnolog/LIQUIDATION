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

## Не делать

- Не снижать thresholds ради красивого `signal_count > 0`.
- Не считать `research-wide-threshold` заменой baseline.
- Не переходить к real trading на основе диагностического профиля.
