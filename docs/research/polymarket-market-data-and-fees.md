# Polymarket Market Data And Fees Research

Дата проверки: 2026-06-19.

## Что проверяли

- CLOB market data.
- WebSocket channel coverage.
- Order/fill semantics.
- Fees.
- SDK status.
- Community signals через `last30days`.

## `last30days` result

Raw output:
[polymarket-clob-api-market-data-fees-arbitrage-raw-polymarket-market-data.md](raw/polymarket-clob-api-market-data-fees-arbitrage-raw-polymarket-market-data.md)

Главный community signal: разработчики ищут reliable historical Polymarket data
для bot/backtest work и упираются в API limits. Это усиливает наше решение:
нужен собственный recorder и replay archive, а не только live API.

Дополнительный signal: arbitrage/dashboard tooling появляется в GitHub, но это
не заменяет нашу модель fees/fills и не является источником истины.

## Official findings

Official docs:
[Polymarket docs](https://docs.polymarket.com/),
[WebSocket overview](https://docs.polymarket.com/market-data/websocket/overview),
[Market channel](https://docs.polymarket.com/market-data/websocket/market-channel),
[Orderbook](https://docs.polymarket.com/trading/orderbook),
[Create order](https://docs.polymarket.com/trading/orders/create),
[Clients & SDKs](https://docs.polymarket.com/api-reference/clients-sdks),
[Polymarket US fees](https://docs.polymarket.us/fees).

Polymarket WebSocket provides market data channels for near real-time orderbook
data, trades and personal order activity. The market channel is public and
streams level 2 price data, orderbook snapshots, price changes, trade
executions and market events.

Orderbook docs explicitly recommend WebSocket for live orderbook data instead
of polling.

All orders are expressed as limit orders. Market orders are implemented by
submitting a marketable limit order.

SDK status matters:

- old `py-clob-client` is archived and should not be used;
- `py-clob-client-v2` recommends the new unified SDK;
- official docs list TypeScript, Python and Rust clients;
- [Polymarket Rust CLOB client](https://github.com/Polymarket/rs-clob-client)
  exists and should be evaluated before writing raw REST wrappers.

Fees:

- Polymarket US fee docs define fee formula `Fee = theta * C * p * (1 - p)`;
- fees can be market/category dependent;
- global/non-US behavior must be verified through current docs and fee-rate
  endpoints before replay uses numbers as decision-grade.

## Design impact

- Paper fill model must store market WebSocket events, not just periodic REST
  snapshots.
- MVP fill models should remain `trade_cross` and `book_touch`. Depth-sensitive
  fills are follow-up unless full enough depth is recorded.
- Replay output must show gross PnL, Polymarket fees/rebates, slippage,
  penalties and net PnL separately.
- Do not hardcode zero-fee assumption. If a market reports zero fee, store
  source URL/date/fee-rate response.
- Evaluate official Rust SDK first. If it lacks required WebSocket coverage,
  use typed internal adapter around documented endpoints.

## Что улучшить или автоматизировать

- Add `polymarket_fee_snapshot` table or config artifact with fee source/date.
- Add replay guard: result is `not decision-grade` when fee schedule is missing.
- Add fixture tests for `book`, `price_change`, `last_trade_price`,
  `best_bid_ask`, `market_resolved`.
- Add historical-data gap report for Polymarket CLOB streams.
