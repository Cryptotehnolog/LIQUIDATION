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
