# Source Usefulness Report

Цель: перед добавлением Hyperliquid/Bitget/Gate/HTX как liquidation sources
измерять реальную полезность источников, а не спорить по скриншотам Coinglass.

Отчёт read-only. Он не меняет source policy и не включает diagnostic sources в
strategy signals.

## Команда

```powershell
$env:DATABASE_URL="postgres://liquidation:liquidation@127.0.0.1:15433/liquidation"
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\source-usefulness-report.ps1 -WindowMinutes 120 -Json
```

По умолчанию JSON artifact пишется в:

```text
.cache/source-usefulness/latest.json
```

## Метрики

Для каждого source отчёт считает:

- `events_per_hour`: raw rows per hour;
- `canonical_events_per_hour`: canonical liquidation rows per hour;
- `max_notional_usd`: крупнейшая canonical liquidation в USD;
- `median_latency_ms` и `p95_latency_ms`;
- `stale_rate_bps`: stale health rows в basis points;
- `overlap_buckets_with_primary`: buckets, где source и primary оба видели
  canonical liquidation events;
- `liquidation_ready_buckets_without_primary`: buckets, где diagnostic source
  видел canonical liquidation events, а primary source молчал;
- `verdict`: диагностический вывод.

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

Нельзя переводить source из `diagnostic_only` в `signal_eligible` только по
одному отчёту. Нужно несколько окон, fixture tests, official docs review,
bounded live probe и отдельное documented decision.
