# Hyperliquid Execution And Fees Research

Дата проверки: 2026-06-19.

## Что проверяли

- Hedge execution data.
- Fees.
- Funding.
- L2 book limitations.
- Recent community signals.

## `last30days` result

Raw output:
[hyperliquid-api-fees-funding-execution-slippage-raw-hyperliquid-fees-execution.md](raw/hyperliquid-api-fees-funding-execution-slippage-raw-hyperliquid-fees-execution.md)

Community evidence было thin: один Reddit thread о расширении Hyperliquid в
prediction markets, pre-IPO stocks и ETFs. Это полезно как strategic signal, но
не достаточно для fee/execution design. Для fees/funding/execution нужно
полагаться на official docs.

## Official findings

Official docs:
[Hyperliquid fees](https://hyperliquid.gitbook.io/hyperliquid-docs/trading/fees),
[Hyperliquid funding](https://hyperliquid.gitbook.io/hyperliquid-docs/trading/funding),
[Hyperliquid info endpoint](https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/api/info-endpoint).

Fees:

- fee tier depends on rolling 14-day volume;
- sub-account volume counts toward master account;
- vault volume is treated separately;
- fee schedules must be dated/versioned.

Funding:

- funding formula is based on an 8-hour rate;
- funding is paid every hour as one eighth of the computed 8-hour rate;
- premium is sampled every 5 seconds and averaged over the hour.

Info endpoint constraints:

- `userFills` returns at most 2000 most recent fills;
- `userFillsByTime` returns at most 2000 fills per response and only 10000 most
  recent fills are available;
- `l2Book` returns at most 20 levels per side;
- order status exposes rejection/cancel reasons that matter for paper/live
  reconciliation, including insufficient margin, no liquidity, open interest
  cap, post-only immediate match and scheduled cancel.

## Design impact

- Hedge fill model needs fee tier input, funding model and slippage penalties.
- `book_depth_cross` must stay out of MVP unless recorded depth is sufficient;
  Hyperliquid `l2Book` is limited to 20 levels per side.
- For paper trading, store order status, fill reason, reject reason and
  scheduled cancel state as first-class fields.
- Replay should include funding/holding cost even when hedge duration is short,
  at least as zero/nonzero explicitly derived from time held.
- Fee schedule ingestion is required before real-money readiness.

## Что улучшить или автоматизировать

- Add `hyperliquid_fee_schedule_snapshot` with source URL, date, account tier and
  assumptions.
- Add `hedge_execution_events` table for status/fill/reject reconciliation.
- Add `hedge_timeout` and `market_fallback_penalty_bps` to strategy config.
- Add nightly check for fee/funding docs changes.
