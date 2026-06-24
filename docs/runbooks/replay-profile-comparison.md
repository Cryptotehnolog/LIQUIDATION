# Replay Profile Comparison Runbook

Цель: сравнить baseline replay и диагностический профиль
`research-wide-threshold` на одном и том же Polymarket market window.

## Почему это важно

Нельзя сравнивать baseline и research-профиль на разных 5-minute windows:
ликвидации, котировки Polymarket и Hyperliquid trades будут другими. Такое
сравнение покажет шум, а не эффект настройки стратегии.

Правильный порядок:

1. Найти replay-ready liquidation window.
2. Запустить baseline replay и сохранить artifact.
3. Использовать тот же `market_id`, `up_token_id`, `down_token_id`,
   `start_ts` и `end_ts`.
4. Запустить `research-wide-threshold` по тому же окну.
5. Сравнить `signal_count`, `polymarket_fills`, `fill_rate` и `net_pnl_usd`.

## Команда

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/compare-replay-profiles.ps1 `
  -DatabaseUrl "postgres://liquidation:liquidation@127.0.0.1:15433/liquidation" `
  -MaxWindows 6 `
  -MaxRuntimeSeconds 330 `
  -OutputPath ".cache/replay/profile-comparison.json"
```

Dry-run без запуска replay:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/compare-replay-profiles.ps1 `
  -DatabaseUrl "postgres://liquidation:liquidation@127.0.0.1:15433/liquidation" `
  -PrintCommandsOnly
```

## Что читает отчёт

Отчёт `.cache/replay/profile-comparison.json` содержит:

- `baseline_artifact_path`;
- `research_artifact_path`;
- `profiles[].strategy_parameters`;
- `profiles[].signal_count`;
- `profiles[].polymarket_orders`;
- `profiles[].polymarket_fills`;
- `profiles[].fill_rate`;
- `profiles[].net_pnl_usd`;
- `profiles[].signal_rejection_reasons`;
- `deltas`;
- `higher_net_pnl_profile`;
- `more_valid_signals_profile`;
- `more_entry_fills_profile`.

## Правила интерпретации

- `research-wide-threshold` является только diagnostic profile.
- Больше `signal_count` не означает, что strategy стала лучше.
- Без `polymarket_fills > 0` и hedge path нельзя делать вывод о прибыльности.
- Если `baseline` даёт `signal_count=0`, а `research-wide-threshold` даёт
  сигнал, это доказывает только влияние верхнего liquidation threshold.
- Если оба профиля дают `net_pnl_usd=0`, winner по PnL должен оставаться `tie`.

## Текущий вывод на 2026-06-24

Первое реальное сравнение на market `2657002`
(`btc-updown-5m-1782324300`, `2026-06-24T18:05:00Z..2026-06-24T18:10:00Z`)
показало:

- baseline: `liquidations=10`, `signal_count=0`;
- baseline blockers: `liquidation_notional_above_threshold=4`,
  `liquidation_notional_below_threshold=6`;
- research-wide-threshold: `signal_count=1`, `polymarket_orders=1`;
- research-wide-threshold blockers: `polymarket_entry_not_filled=1`;
- оба профиля: `polymarket_fills=0`, `net_pnl_usd=0`.

Вывод: верхний threshold `100000` действительно отсекает часть реальных
каскадов, но profitability не доказана, потому что entry fill не произошёл.

## Что улучшить или автоматизировать

Следующий полезный шаг - aggregate comparison over multiple windows:
одна команда запускает несколько profile comparisons и строит общий report по
частоте сигналов, fills, net PnL и главным blockers.
