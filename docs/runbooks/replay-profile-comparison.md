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

## Aggregate comparison

Для серии сравнений на нескольких реальных windows:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/compare-replay-profiles-aggregate.ps1 `
  -DatabaseUrl "postgres://liquidation:liquidation@127.0.0.1:15433/liquidation" `
  -MaxComparisons 2 `
  -MaxWindowsPerComparison 6 `
  -OutputPath ".cache/replay/profile-comparison-aggregate.json"
```

Aggregate report содержит:

- `completed_comparisons`;
- `failed_comparisons`;
- `profile_totals`;
- `rejection_reasons_by_profile`;
- `dominant_rejection_reasons`;
- `baseline_vs_research_delta`;
- `diagnostic_summary`.

Этот режим всё ещё paper-only. Он не должен менять baseline defaults
автоматически.

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

## Первый aggregate run

Дата запуска: 2026-06-24.

Параметры: `MaxComparisons=2`, `MaxWindowsPerComparison=6`.

Результат:

- `completed_comparisons=2`;
- `failed_comparisons=0`;
- baseline: `signals=0`, `fills=0`, `net_pnl_usd=0`;
- research-wide-threshold: `signals=0`, `fills=0`, `net_pnl_usd=0`;
- delta между research и baseline: `signals=0`, `fills=0`, `net_pnl_usd=0`;
- dominant blockers: `order_cancel_window=18` для обоих профилей,
  `liquidation_notional_below_threshold=2` для обоих профилей.

Вывод: в этой серии проблема не в верхнем liquidation threshold, а в том, что
события приходили слишком близко к экспирации market. Нельзя менять baseline
threshold по этой серии.

## Aggregate smoke after diagnostic summary

Дата запуска: 2026-06-24.

Параметры: `MaxComparisons=1`, `MaxWindowsPerComparison=6`.

Результат:

- `completed_comparisons=1`;
- `failed_comparisons=0`;
- baseline: `signals=1`, `orders=1`, `fills=0`, `net_pnl_usd=0`;
- research-wide-threshold: `signals=1`, `orders=1`, `fills=0`,
  `net_pnl_usd=0`;
- delta между research и baseline: `signals=0`, `fills=0`, `net_pnl_usd=0`;
- diagnostic summary: signals были, но Polymarket entry не filled.

Вывод: это окно не поддерживает изменение threshold. Текущий практический
barrier - entry fill на Polymarket.
