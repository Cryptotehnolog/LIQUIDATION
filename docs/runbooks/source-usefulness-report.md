# Source Usefulness Report

Retrieval summary: `source-usefulness-report.ps1` measures diagnostic sources
with `liquidation_ready_buckets_without_primary` before any source can affect
strategy signals.

Цель: перед добавлением Hyperliquid/Bitget/Gate/HTX как liquidation sources
измерять реальную полезность источников, а не спорить по скриншотам Coinglass.

Отчёт read-only. Он не меняет source policy и не включает diagnostic sources в
strategy signals.

`diagnostic sources` в этом контексте - это Binance/OKX/Bitget/Gate и будущие
кандидаты, которые видны в отчётах, но не получают signal weight без отдельного
documented decision.

## Команда

```powershell
$env:DATABASE_URL="postgres://liquidation:liquidation@127.0.0.1:15433/liquidation"
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\source-usefulness-report.ps1 -WindowMinutes 120 -Json
```

По умолчанию JSON artifact пишется в:

```text
.cache/source-usefulness/latest.json
```

Для ответа на вопрос "нужен ли HTX сейчас" используйте current-source
signal-readiness wrapper:

```powershell
$env:DATABASE_URL="postgres://liquidation:liquidation@127.0.0.1:15433/liquidation"
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\source-signal-readiness-report.ps1 -WindowMinutes 120 -Json
```

Он запускает `source-usefulness-report.ps1`, затем пишет агрегированный artifact:

```text
.cache/source-usefulness/signal-readiness.json
```

Default source set намеренно ограничен текущими источниками:

```text
bybit, binance, okx, bitget, gate
```

HTX не входит в этот отчёт. Он остаётся deferred, пока текущие источники не
докажут coverage blocker.

## Метрики

Для каждого source отчёт считает:

- `events_per_hour`: raw rows per hour;
- `canonical_events_per_hour`: canonical liquidation rows per hour;
- `max_notional_usd`: крупнейшая canonical liquidation в USD;
- `median_latency_ms` и `p95_latency_ms`;
- `stale_rate_bps`: stale health rows в basis points;
- `overlap_buckets_with_primary`: buckets, где source и primary оба видели
  canonical liquidation events;
- `liquidation_ready_buckets_without_primary`: buckets, где diagnostic sources
  видели canonical liquidation events, а primary source молчал;
- `verdict`: диагностический вывод.

## Signal-Readiness Proxy

`source-signal-readiness-report.ps1` агрегирует поле
`liquidation_ready_buckets_without_primary` по текущим sources и называет это
`signal_ready_windows_proxy`.

Это не доказательство PnL и не полноценный replay signal. Это честный proxy:
сколько временных buckets могли стать replay-ready за счёт diagnostic source,
когда primary source (`bybit`) молчал.

Интерпретация:

- `signal_ready_windows_proxy > 0`: HTX не нужен прямо сейчас; сначала
  продолжать controlled replay, entry-fill, hedge-fill и net-PnL analysis.
- `signal_ready_windows_proxy = 0`, но canonical events есть: данных мало или
  diagnostic sources в основном overlap with primary; HTX только watchlist.
- Нет canonical events: сначала собрать больше окон текущими sources, а не
  сразу добавлять HTX.

Отчёт не переводит ни один diagnostic source в `participates_in_signals=true`.
Для этого всё ещё нужен отдельный documented decision.

## Verdict

- `strategy-primary`: текущий source участвует в strategy signals.
- `useful-diagnostic`: diagnostic source добавляет buckets, где primary молчал.
- `overlapping-diagnostic`: canonical events есть, но они пересекаются с primary.
- `raw-only-diagnostic`: raw payload есть, но canonical path пока не доказан.
- `healthy-but-empty`: health есть, событий нет.
- `unreliable-stale`: слишком много stale health rows.
- `insufficient-data`: нет данных за окно.

## Как использовать перед новыми sources

1. Запустить текущий collector window.
2. Запустить `source-usefulness-report.ps1`.
3. Сохранить artifact.
4. После добавления Hyperliquid/Bitget/Gate/HTX повторить тот же report.
5. Сравнивать не только `events/hour`, но и
   `liquidation_ready_buckets_without_primary`.

Для нескольких сохранённых artifacts можно запустить analyzer напрямую:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\analyze-source-signal-readiness.ps1 `
  -SourceUsefulnessArtifactPath .cache/source-usefulness/run-001.json,.cache/source-usefulness/run-002.json `
  -OutputPath .cache/source-usefulness/signal-readiness-aggregate.json `
  -Json
```

Нельзя переводить source из `diagnostic_only` в `signal_eligible` только по
одному отчёту. Нужно несколько окон, fixture tests, official docs review,
bounded live probe и отдельное documented decision.
