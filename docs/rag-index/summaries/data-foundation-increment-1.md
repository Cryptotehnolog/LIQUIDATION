# Summary: Data Foundation Increment 1

Source document:

- `docs/superpowers/plans/2026-06-19-data-foundation-increment-1.md`

## Цель

Первый Rust foundation increment должен создать основу, на которой можно
строить collector, recorder и replay без реальной торговли.

## Scope

- Rust workspace.
- Config validation.
- Connector traits.
- Initial Binance/Bybit collectors.
- Normalizer and canonical domain types.
- Recorder schema and migrations.
- Raw/canonical persistence.
- Replay dry-run.

## Не В Scope

- Real trading.
- Production dashboard.
- Full strategy optimization.
- Multi-asset scaling.
- Agent autopilot.

## Engineering Rules

- Ошибки через typed errors и explicit Result.
- Async code должен иметь backpressure и reconnect policy.
- No hidden defaults for trading/risk settings.
- Tests cover source fixtures, schema/domain alignment and config validation.

## Перед Стартом

LightRAG Dev Memory должен быть usable: `ingest`, `eval`, `health`,
`status --check-commit`, `audit-rag` проходят.
