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

## Entry Fill Diagnostics

После появления signals с `polymarket_fills=0` нельзя сразу менять
`liquidation_threshold_max_usd` или `pullback_pct`. Сначала нужно смотреть
`trades[].entry_fill_diagnostics` в replay artifact.

Ключевые поля:

- `signal_best_ask` - цена Polymarket, от которой стратегия считала stink bid;
- `limit_price` - фактическая цена лимитного entry;
- `pullback_pct` - использованный pullback;
- `seconds_to_order_expiry` - сколько секунд оставалось до forced cancel;
- `trades_in_order_window` и `best_trade_price_in_window` - были ли реальные
  trades около лимита;
- `trade_distance_to_fill` - насколько лучшая trade price не дошла до лимита;
- `books_in_order_window`, `best_book_touch_price_in_window` и
  `book_distance_to_fill` - оптимистичная book-touch диагностика.

Интерпретация:

- `trade_distance_to_fill = 0` означает, что `trade_cross` доказал fill.
- Малый `trade_distance_to_fill` при большом `book_distance_to_fill` указывает
  на проблему trade liquidity/print coverage.
- Большой `trade_distance_to_fill` при нормальном времени до экспирации
  указывает, что pullback может быть слишком глубоким для этого окна.
- Малый `seconds_to_order_expiry` указывает, что сигнал пришёл поздно, и
  менять threshold/pullback по такому окну нельзя.

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

## Entry Diagnostics Smoke

Дата запуска: 2026-06-25.

Pinned market: `2657475`, `btc-updown-5m-1782327600`,
`2026-06-24T19:00:00Z..2026-06-24T19:05:00Z`.

Baseline replay с новым `trades[].entry_fill_diagnostics` показал:

- `signal_count=1`;
- `polymarket_fills=0`;
- `signal_best_ask=0.55`;
- `limit_price=0.3850`;
- `seconds_to_order_expiry=27`;
- `trades_in_order_window=57`;
- `best_trade_price_in_window=0.55`;
- `trade_distance_to_fill=0.1650`;
- `books_in_order_window=3073`;
- `book_distance_to_fill=0.1650`.

Вывод: это окно не доказывает плохой threshold. Сигнал пришёл поздно
относительно 5-minute expiry, а Polymarket не торговался близко к stink bid.
Для настройки `pullback_pct` нужна серия окон с нормальным
`seconds_to_order_expiry`, а не одиночный late signal.

## Entry Diagnostics Aggregate Analyzer

Чтобы не читать replay JSON руками, используйте:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/analyze-entry-fill-diagnostics.ps1 `
  -ReplayArtifactDirectory ".cache/replay" `
  -OutputPath ".cache/replay/entry-fill-diagnostics-analysis.json"
```

Analyzer читает replay artifacts, ищет `trades[].entry_fill_diagnostics` и
считает:

- `late_entries` и `late_entry_ratio`;
- `average_seconds_to_order_expiry`;
- `average_trade_distance_to_fill`;
- `average_book_distance_to_fill`;
- `no_trade_liquidity`;
- `book_touch_reachable_without_trade`;
- итоговую `classification`.

Классификации:

- `late_signal_dominates` - большинство сигналов пришли слишком поздно;
- `no_signals_built` - replay прошёл, но signals не построились; сначала
  смотреть `signal_gate` и `expiry`, а не entry fill;
- `polymarket_trade_liquidity_gap` - внутри order window не было Polymarket
  trades;
- `trade_cross_conservative` - book touch был достижим, но trade_cross не
  доказал fill;
- `pullback_too_deep_candidate` - средняя дистанция до fill слишком большая;
- `needs_more_windows` - данных мало или pattern не доминирует;
- `entry_fill_observed` - хотя бы один entry fill доказан.

Первый запуск analyzer по `.cache/replay` после добавления diagnostics и
одной короткой controlled comparison series:

- `artifacts=9`;
- `entry_diagnostics=1`;
- `signals=1`;
- `polymarket_fills=0`;
- `late_entry_ratio=1`;
- `average_seconds_to_order_expiry=27`;
- `average_trade_distance_to_fill=0.1650`;
- `classification=late_signal_dominates`.

Короткая controlled series добавила окно без signals: dominant blocker был
`liquidation_notional_below_threshold`. Вывод: это пока только smoke по одному
новому diagnostic row. Нельзя менять baseline/pullback по такой выборке. Нужно
накопить серию новых controlled replay windows с текущим кодом.

## Entry Fill Diagnostics Batch

Для серии controlled replay windows и автоматического отчёта:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/run-entry-fill-diagnostics-batch.ps1 `
  -DatabaseUrl "postgres://liquidation:liquidation@127.0.0.1:15433/liquidation" `
  -MaxAttempts 1 `
  -MaxWindowsPerAttempt 3 `
  -MaxRuntimeSeconds 260
```

Batch wrapper делает:

- запускает bounded `controlled-replay.ps1`;
- пишет уникальные artifacts по попыткам: `attempt-001/replay.json`,
  `attempt-001/market.json`;
- строит `analyze-controlled-replay.ps1` report;
- строит `analyze-entry-fill-diagnostics.ps1` report;
- чистит зависшие `target/debug/liq.exe` при attempt timeout.

Чтобы сначала искать не entry fill, а хотя бы один построенный сигнал,
используйте режим `-UntilSignalBuilt`:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/run-entry-fill-diagnostics-batch.ps1 `
  -DatabaseUrl "postgres://liquidation:liquidation@127.0.0.1:15433/liquidation" `
  -UntilSignalBuilt `
  -MaxAttempts 2 `
  -MaxWindowsPerAttempt 3 `
  -MaxRuntimeSeconds 260
```

Этот режим останавливает серию, когда replay artifact впервые показывает
`signal_count > 0`. Это дешевле и честнее, чем сразу искать entry fill:
сначала нужно доказать, что signal gate вообще пропускает окно.

## Controlled Batch Result 2026-06-25

Run id: `20260625-022104`.

Market: `2661331`, `2026-06-24T23:20:00Z..2026-06-24T23:25:00Z`.

Collector facts:

- Binance: `received_messages=4`, `canonical_inserted=4`;
- Bybit: `received_messages=12`, `canonical_inserted=0`;
- OKX: `received_messages=3`, `canonical_inserted=0`;
- Polymarket quotes/trades and Hyperliquid quotes/trades were present.

Replay facts:

- `ready_for_replay=true`;
- `liquidations=4`;
- `signal_count=0`;
- `polymarket_orders=0`;
- `polymarket_fills=0`;
- dominant blocker: `signal_gate/liquidation_notional_below_threshold`
  count `3`;
- secondary blocker: `expiry/order_cancel_window` count `1`.

Entry-fill conclusion:

- classification: `no_signals_built`;
- entry fill was not tested in this window because baseline did not build a
  signal;
- do not tune `pullback_pct` from this run;
- lowering `liquidation_threshold_min_usd` is not recommended from this run
  alone because below-threshold events are likely noise unless a research
  profile proves otherwise across many windows.

## Until Signal Built Batch Result 2026-06-25

Run id: `20260625-023637`.

Параметры: `MaxAttempts=2`, `MaxWindowsPerAttempt=3`,
`MaxRuntimeSeconds=260`, `UntilSignalBuilt=true`.

Результат:

- `attempts_total=2`;
- `attempts_completed=1`;
- `attempts_failed=1`;
- `stopped_reason=max_attempts_reached`;
- completed market: `2661409`,
  `2026-06-24T23:35:00Z..2026-06-24T23:40:00Z`;
- `liquidations=1`;
- `signal_count=0`;
- `polymarket_orders=0`;
- `polymarket_fills=0`;
- blocker: `signal_gate/liquidation_notional_below_threshold`;
- detail: `dominant_notional_usd=121.58340`, при baseline minimum `25000`.

Вторая попытка завершилась без replay-ready liquidation window в пределах
bounded scan. Это полезный отрицательный результат: режим поиска первого
сигнала работает, но в этой серии baseline не должен был строить сигнал.
Снижать `liquidation_threshold_min_usd` по одной крошечной ликвидации нельзя.
