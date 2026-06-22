# Dashboard Runbook

Цель: зафиксировать требования к read-only operational dashboard до начала
реализации UI.

## Назначение

Dashboard нужен не для презентации проекта, а для ежедневного понимания:

- работают ли источники данных;
- есть ли gaps, latency spikes и reconnects;
- что происходит с liquidation flow;
- какие paper signals и paper orders генерируются;
- как выглядит paper PnL после fees, slippage и penalties;
- в порядке ли storage и archive verification.

## MVP scope

Dashboard read-only. Он не должен:

- отправлять real orders;
- менять strategy thresholds;
- менять risk limits;
- запускать destructive archive/delete operations.

## Основные виджеты

- Source health: status, heartbeat, reconnects, circuit breaker.
- Latency: exchange timestamp to receive timestamp.
- Liquidations: notional by source, side, symbol, rolling window.
- Signals: accepted/skipped signals and reasons.
- Paper orders/fills: fill model, fill rate, unhedged exposure.
- PnL: gross PnL, fees, slippage, penalties, net PnL.
- Storage: TimescaleDB, raw hot table, Parquet archive size.
- Archive: verification status, corrupted files, deletion watermark.

## Collector Data Contract

Первый машинный контракт для dashboard:

```powershell
$env:DATABASE_URL="postgres://liquidation:liquidation@127.0.0.1:15433/liquidation"
cargo run -p liq-cli -- collector status --json --window-minutes 60
```

Dashboard не должен парсить табличный `collector status`. Используйте только
JSON-режим. Поля времени приходят как RFC3339 strings или `null`.

## Local Dashboard Server

Первый dashboard skeleton запускается как read-only локальный HTTP server из
`liq-cli`. Браузер не ходит напрямую в TimescaleDB и не запускает shell-команды.
Он читает только `/api/collector/status`, который возвращает тот же JSON
contract, что и `collector status --json`.

```powershell
$env:DATABASE_URL="postgres://liquidation:liquidation@127.0.0.1:15433/liquidation"
cargo run -p liq-cli -- collector dashboard --bind 127.0.0.1:18080 --window-minutes 60 --poll-seconds 5
```

Открыть в браузере:

```text
http://127.0.0.1:18080/
```

Development-only fixture mode используется только для smoke tests и UI
проверок edge states:

```powershell
cargo run -p liq-cli -- collector dashboard --bind 127.0.0.1:18080 --fixture-path tests/fixtures/dashboard/collector-status-edge-cases.json --poll-seconds 1
```

Smoke test:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test-dashboard-smoke.ps1
```

Smoke test проверяет:

- `null` timestamps и отсутствие payload у Binance;
- stale/degraded source;
- latency buckets;
- storage signal;
- mobile viewport без horizontal overflow;
- отсутствие browser console errors.

Минимальные поля для первой версии dashboard:

- `sources[].source`, `sources[].symbol`, `sources[].status`;
- `sources[].freshness_ms`;
- `sources[].latency_bucket_lt_100_ms`;
- `sources[].latency_bucket_100_500_ms`;
- `sources[].latency_bucket_500_1000_ms`;
- `sources[].latency_bucket_ge_1000_ms`;
- `sources[].reconnects_5m`, `sources[].max_reconnects_5m`;
- `sources[].last_payload_ts`, `sources[].last_event_ts`;
- `storage.total_bytes`, `storage.raw_rows_window`,
  `storage.canonical_rows_window`.

## Design workflow

Dashboard work should use:

- Superpowers for requirements and implementation discipline;
- `design-engineer` for interaction and UI polish;
- `data-visualization` for chart choices and dashboard layout;
- browser visual checks for desktop and mobile.

## Visual guards

Before dashboard work is accepted:

- no overlapping text;
- all cards/widgets readable on desktop and mobile;
- stale/offline/partial states visible without hover;
- empty/loading/error states covered;
- charts have direct labels or clear legends;
- critical alerts remain visible when viewport narrows.

## Test guards

Add tests or fixtures for:

- no data;
- partial source outage;
- high latency;
- archive verification failure;
- negative net PnL after fees;
- stale paper-live worker.
