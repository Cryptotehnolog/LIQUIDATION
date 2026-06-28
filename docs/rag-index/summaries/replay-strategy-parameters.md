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
- Не менять `pullback_pct` или верхний threshold, пока replay artifact не
  покажет entry-fill качество через `trades[].entry_fill_diagnostics`.

## Entry Fill Diagnostics

Дата добавления: 2026-06-25.

Практический bottleneck после первых real controlled replay windows -
Polymarket entry fill. Replay artifact теперь должен использовать
`trades[].entry_fill_diagnostics`, чтобы объяснять каждый сигнал:

- `signal_best_ask` - anchor price из первоисточника стратегии;
- `limit_price` - stink bid после `pullback_pct`;
- `seconds_to_order_expiry` - осталось времени до forced cancel;
- `trades_in_order_window` и `best_trade_price_in_window` - фактические trades
  внутри order window;
- `trade_distance_to_fill` - расстояние до fill по conservative `trade_cross`;
- `books_in_order_window` и `book_distance_to_fill` - optimistic book-touch
  диагностика.

Правило: если signals есть, но `polymarket_fills=0`, сначала анализировать
`trade_distance_to_fill`, `book_distance_to_fill`, `signal_best_ask` и
`seconds_to_order_expiry`. Только после серии окон с понятным pattern можно
обсуждать изменение `pullback_pct` или thresholds.

## Entry Diagnostics Smoke Result

Дата запуска: 2026-06-25.

Market `2657475`, `btc-updown-5m-1782327600`,
`2026-06-24T19:00:00Z..2026-06-24T19:05:00Z`.

Новый replay artifact показал:

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

Вывод: конкретное окно не поддерживает изменение threshold. Оно показывает
late signal плюс слишком далёкий stink bid относительно фактических Polymarket
trades. Следующий анализ должен агрегировать entry diagnostics по нескольким
окнам с нормальным временем до expiry.

## Entry Fill Aggregate Analyzer

Дата добавления: 2026-06-25.

Добавлен `scripts/analyze-entry-fill-diagnostics.ps1`. Он агрегирует
`trades[].entry_fill_diagnostics` из replay artifacts и пишет:

- `late_entry_ratio`;
- `average_seconds_to_order_expiry`;
- `average_trade_distance_to_fill`;
- `average_book_distance_to_fill`;
- `no_trade_liquidity`;
- `book_touch_reachable_without_trade`;
- `classification`.

Первый запуск по `.cache/replay` после добавления analyzer и одной короткой
controlled comparison series:

- `artifacts=9`;
- `entry_diagnostics=1`;
- `signals=1`;
- `polymarket_fills=0`;
- `late_entry_ratio=1`;
- `average_seconds_to_order_expiry=27`;
- `average_trade_distance_to_fill=0.1650`;
- `classification=late_signal_dominates`.

Короткая controlled series добавила окно без signals, где dominant blocker был
`liquidation_notional_below_threshold`. Вывод: текущая выборка слишком мала для
настройки `pullback_pct` или thresholds. Нужно накопить несколько новых
controlled replay windows после добавления diagnostics. Если analyzer продолжит
показывать `late_signal_dominates`, сначала исследовать timing/order_cancel_window,
а не liquidation thresholds.

## Entry Fill Diagnostics Batch Result

Дата запуска: 2026-06-25.

Добавлен `scripts/run-entry-fill-diagnostics-batch.ps1`: bounded wrapper,
который запускает controlled replay windows, сохраняет уникальные artifacts по
attempts, затем автоматически строит trade-path analysis и entry-fill analysis.
Скрипт имеет per-attempt timeout и чистит только наши
`D:\Liquidation\LIQUIDATION\target\debug\liq.exe`, чтобы не оставлять зависшие
collector-процессы.

Первый рабочий batch run: `20260625-022104`.

Market `2661331`, `2026-06-24T23:20:00Z..2026-06-24T23:25:00Z`:

- Binance collector: `received_messages=4`, `canonical_inserted=4`;
- replay preflight: `ready_for_replay=true`;
- `liquidations=4`;
- `signal_count=0`;
- `polymarket_orders=0`;
- `polymarket_fills=0`;
- trade path blocker: `signal_gate`;
- reasons: `liquidation_notional_below_threshold=3`,
  `order_cancel_window=1`;
- entry-fill classification: `no_signals_built`.

Вывод: это окно доказывает, что Binance liquidation path уже пишет canonical
events, но baseline не дошёл до entry-fill стадии. Нельзя делать выводы про
`pullback_pct` по этому окну. Следующий сбор должен продолжать искать windows,
где `signal_count > 0`, и только потом анализировать
`trade_distance_to_fill`/`seconds_to_order_expiry`.

## Until Signal Built Batch

Дата добавления: 2026-06-25.

`scripts/run-entry-fill-diagnostics-batch.ps1` получил режим
`-UntilSignalBuilt`. Он останавливает bounded replay series, когда первый
completed attempt даёт `signal_count > 0`. Это снижает CPU/noise и отделяет
две разные задачи:

1. Сначала доказать, что baseline signal gate пропускает реальное окно.
2. Только потом анализировать Polymarket entry fill quality.

Первый запуск: `20260625-023637`.

- `MaxAttempts=2`, `MaxWindowsPerAttempt=3`;
- `attempts_total=2`;
- `attempts_completed=1`;
- `attempts_failed=1`;
- `stopped_reason=max_attempts_reached`;
- completed market: `2661409`,
  `2026-06-24T23:35:00Z..2026-06-24T23:40:00Z`;
- `liquidations=1`;
- `signal_count=0`;
- blocker: `signal_gate/liquidation_notional_below_threshold`;
- observed notional: `121.58340`, far below baseline minimum `25000`.

Вывод: режим работает, но серия не нашла baseline signal. Это не повод снижать
`liquidation_threshold_min_usd`: единственная completed liquidation была
слишком маленькой и похожа на noise. Следующий controlled run должен
продолжать искать replay-ready windows с реальным `signal_count > 0`.

## First Real Until-Signal Success

Дата запуска: 2026-06-25.

Добавлен лёгкий wrapper `scripts/run-until-signal-built.ps1`, который запускает
bounded controlled replay series с `-UntilSignalBuilt` без длинной ручной
команды. Практическое решение: запускать короткими контролируемыми циклами
примерно по одной replay window, а не одним слепым двухчасовым процессом.

Во время live run исправлены два operator-safety дефекта:

- wrapper не должен передавать absolute artifact prefixes в downstream scripts,
  иначе на Windows получается путь вида `D:\repo\D:\repo\...`;
- `no replay-ready liquidation window` является нормальным negative window,
  а не technical failure.

Успешный run: `20260625-095554`.

Market `2664770`, `2026-06-25T06:55:00Z..2026-06-25T07:00:00Z`
(`09:55..10:00` Minsk time):

- `ready_for_replay=true`;
- `liquidations=24`;
- Binance canonical events: `9`;
- Bybit canonical events: `6`;
- OKX canonical events: `9`;
- `signal_count=1`;
- `polymarket_orders=1`;
- `polymarket_fills=0`;
- `hedge_attempts=0`;
- stopped reason: `signal_built_observed`.

Signal details:

- source signal: `short_liquidation`;
- source notional: `36125.65980`;
- outcome: `up`;
- `signal_best_ask=0.53`;
- `limit_price=0.371`;
- `pullback_pct=0.3`;
- `seconds_to_order_expiry=138`;
- `trades_in_order_window=123`;
- `best_trade_price_in_window=0.52`;
- `trade_distance_to_fill=0.149`;
- `book_distance_to_fill=0.159`;
- entry classification: `pullback_too_deep_candidate`.

Вывод: baseline strategy уже строит сигнал на реальных данных. Следующий
блокер - entry fill на Polymarket. Это не late signal: времени до expiry было
достаточно. Но менять `pullback_pct` по одному signal window нельзя; нужен
aggregate по нескольким реальным signal windows или отдельный диагностический
pullback profile comparison.

## Until-Signal Aggregate Runner And 2026-06-28 Recovery

Добавлен `scripts/run-until-signal-built-aggregate.ps1` для накопления нескольких
реальных signal windows. Runner запускает короткие controlled cycles, считает
только `stopped_reason=signal_built_observed`, останавливается по умолчанию на
technical failure, пропускает слишком короткие tail cycles и строит combined
entry-fill analysis только по явно собранным replay artifacts. Старые cache
artifacts больше не подмешиваются: analyzer получил
`-DisableReplayArtifactDirectory`.

После разрыва 2026-06-28 TimescaleDB сначала был `unhealthy`, потому что Postgres
делал crash recovery и ещё не принимал соединения. После recovery `db
check-schema` вернул `schema ok`.

Свежие live windows 2026-06-28:

- `2712375` (`20:35Z..20:40Z`): `liquidations=2`, `signal_count=0`,
  notional около `118.95500`, ниже baseline minimum `25000`;
- `2712537` (`20:40Z..20:45Z`): `liquidations=2`, `signal_count=0`,
  notional около `179.64880`;
- `2712554` (`20:45Z..20:50Z`): `liquidations=1`, `signal_count=0`,
  notional около `179.72160`;
- `2712560` (`20:50Z..20:55Z`): `liquidations=2`, `signal_count=0`,
  blockers: below threshold and one `order_cancel_window`.

Вывод: pipeline live data работает, но окна 2026-06-28 не являются signal
windows. Нельзя менять thresholds или `pullback_pct` из этих результатов:
события слишком мелкие или поздние. Следующий шаг - продолжать
until-signal-built aggregate до нескольких реальных `signal_count > 0`, затем
сравнивать entry fill quality.
