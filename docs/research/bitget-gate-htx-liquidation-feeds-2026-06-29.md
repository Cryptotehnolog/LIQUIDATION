# Bitget / Gate / HTX Liquidation Feeds Research

Date: 2026-06-29.

## Decision

Pause Hyperliquid market-wide liquidation ingestion for now. Continue strategy
coverage work with cheaper public liquidation feeds in this order:

1. Bitget diagnostic.
2. Gate diagnostic.
3. HTX diagnostic.

Do not enable any of these sources in strategy signals until docs, fixtures,
bounded live probe, overlap validation and source usefulness gates pass.

## Why Hyperliquid Is Deferred

Hyperliquid remains valuable, but the official market-wide path is node output,
not a lightweight public liquidation-only WebSocket. A 60-second local run would
only prove payload schema. It would not tell whether the strategy makes money.
For strategy economics, cheaper public exchange feeds are a better next step.

Return to Hyperliquid when:

- Bitget/Gate/HTX replay windows show whether the baseline strategy has edge;
- a server is available for longer bounded node-output research;
- Rust parser fixtures and dedup policy are ready.

## Bitget

Official source: Bitget UTA WebSocket public Liquidation Channel.

Important details:

- channel name: `liquidation`;
- public WebSocket channel;
- data is pushed once per second;
- each push contains aggregated liquidation data for the previous second;
- for each pair, at most two records are delivered: largest long liquidation and
  largest short liquidation;
- UTA and Classic Account liquidation data are covered;
- request uses `instType=usdt-futures`;
- payload fields include `symbol`, `side`, `price`, `amount`, `ts`;
- docs describe `amount` as quote coin.

Implication:

Bitget is the best next source because `notional_usd` is likely straightforward
for USDT futures. But the feed is aggregated, not all-events. It should be
`diagnostic_only` until source usefulness proves value.

## Gate

Official source: Gate Futures WebSocket.

Important details:

- futures WebSocket endpoint for USDT futures:
  `wss://fx-ws.gateio.ws/v4/ws/usdt`;
- public liquidation channel: `futures.public_liquidates`;
- payload includes `price`, `size`, `time`, `contract`.

Implication:

Gate is a good second source, but canonical `notional_usd` depends on exact
`size` semantics and contract metadata. Until verified with fixture and live
sample, Gate should be raw-only or canonical-with-metadata.

## HTX

Official source: Huobi/HTX USDT-margined swaps API docs/history.

Important details:

- public subscription topic: `public.$contract_code.liquidation_orders`;
- interface type: public;
- fields include `amount` and `trade_turnover`;
- docs describe `amount` as liquidation amount in token and `trade_turnover` as
  liquidation amount in quotation token.

Implication:

HTX can be a useful diagnostic source. For USDT-margined contracts,
`trade_turnover` is the preferred `notional_usd` candidate. It comes after
Bitget/Gate because HTX docs are older/fragmented and require careful fixture
verification.

## Source Policy

All three sources start as:

- `coverage_role=diagnostic_only`;
- `participates_in_signals=false`;
- no signal weight;
- no automatic aggregation with Bybit/Binance/OKX;
- canonical only if `notional_usd` is proven from payload and metadata.

## Gates

Required before a source can affect strategy analysis:

1. Official docs/changelog review.
2. Fixture payload.
3. Raw parser test.
4. Normalizer test with `notional_usd`.
5. Bounded live probe to TimescaleDB.
6. Dashboard/source policy visibility.
7. Source usefulness report:
   - events/hour;
   - max notional;
   - latency;
   - stale rate;
   - overlap buckets;
   - `liquidation_ready_buckets_without_primary`.
8. Separate documented decision before `participates_in_signals=true`.

## What To Build Next

Build Bitget first:

1. Add Bitget fixture from official docs.
2. Add connector subscription for BTCUSDT USDT futures.
3. Add raw parser and canonical normalizer.
4. Run bounded live probe.
5. Add Bitget to source usefulness report.

Then repeat for Gate and HTX.

## References

- Bitget Liquidation Channel:
  `https://www.bitget.com/api-doc/uta/websocket/public/Liquidation-Channel`
- Bitget WebSocket intro:
  `https://www.bitget.com/api-doc/common/websocket-intro`
- Gate Futures WebSocket:
  `https://www.gate.com/docs/developers/futures/ws/en/`
- HTX USDT-margined swaps API history:
  `https://www.htx.com/en-us/support/900004253583/`
- Huobi/HTX USDT-margined contracts API reference:
  `https://huobiapi.github.io/docs/usdt_swap/v1/en/`
