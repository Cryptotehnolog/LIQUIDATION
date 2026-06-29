# Liquidation Source Expansion Summary

Retrieval summary: Hyperliquid market-wide liquidations are deferred because
official access requires node output / `hl-visor` research, not a lightweight
public liquidation-only feed. Current low-cost diagnostic source order is
`bitget`, `gate`, `htx`. These remain `diagnostic-only` candidates until
official docs, fixtures, live probe, overlap and source usefulness gates pass.

Текущий приоритет расширения liquidation sources после решения 2026-06-29:

1. `bitget` - diagnostic-only source; official public UTA liquidation channel,
   aggregated by one-second buckets.
2. `gate` - diagnostic-only source; official public futures liquidates channel.
3. `htx` - diagnostic-only source; official public USDT-M liquidation_orders
   channel.
4. `hyperliquid_liquidations` - deferred node research candidate, not simple
   WebSocket collector.

Нельзя сразу включать эти sources в strategy signals. Все новые venues сначала
пишутся как diagnostic-only, без signal weight. Для canonical events обязателен
честный `notional_usd`; если его нельзя доказать из payload и metadata,
источник остается raw-only.

Причина приоритета: пользователь заметил по Coinglass, что когда
Binance/Bybit/OKX молчат, больше всего событий может давать Hyperliquid, затем
Bitget, Gate и HTX. Это полезный операционный сигнал, но не proof of feed
quality.

Перед участием в сигналах source должен пройти:

- official docs/changelog review;
- fixtures and normalizer tests;
- bounded live probe;
- latency/stale/source health checks;
- overlap validation against Bybit/Binance/OKX;
- source usefulness report;
- отдельное documented policy decision.

Нужная автоматизация: source usefulness report с events/hour, max notional,
latency, stale rate, overlap buckets и количеством replay windows, которые стали
signal-ready благодаря source.

Реализованный report должен использоваться до включения новых venues в сигналы.
Ключевое поле: `liquidation_ready_buckets_without_primary` - buckets, где
diagnostic source дал canonical liquidation events, а primary source молчал.
Это не полный PnL proof, но честный proxy для source coverage.

## Hyperliquid Deferred Decision

Decision 2026-06-29: pause Hyperliquid liquidation ingestion until strategy
economics are clearer from cheaper public feeds. Reason: official node output is
too heavy for laptop/local iteration and short 60-second probe proves schema,
not usefulness. Return to Hyperliquid when paper replay shows edge or when we
move node research to a server. Keep current Hyperliquid source only as hedge
market-data leg.

Hyperliquid liquidation probe от 2026-06-29: official WebSocket docs и live
probe не подтвердили public all-market liquidation subscription. `bbo` работает,
но `liquidations`/`liquidation` endpoint отклоняет. User-specific liquidation
events не являются all-market feed. Поэтому текущий `hyperliquid` source
остается только hedge market-data leg.

Official `userEvents` with `user=<address>` can emit liquidation events for that
address only. Это можно использовать позже как hedge account risk monitor, но
нельзя использовать как source рыночных liquidation cascades.

Official `Trading / Liquidations` page подтверждает механику: ликвидации могут
отправляться как market orders to the book, partial liquidation threshold is
100k USDC, есть liquidator vault и mark-price liquidation logic. Но эта страница
не содержит public market-wide WebSocket/REST feed schema. Поэтому она усиливает
microstructure thesis, но не снимает API blocker.

Новая важная находка: official `Nodes / L1 data schemas` и
`hyperliquid-dex/node` дают node-based path. `misc_events` содержит
`LedgerDelta = Liquidation` с `liquidatedNtlPos`, `accountValue`,
`leverageType`, `liquidatedPositions`. Node/API fills могут содержать
`FillLiquidation` (`liquidatedUser`, `markPx`, `method`). Node flags
`--write-fills`, `--write-misc-events`, `--batch-by-block`,
`--stream-with-block-info`, `--disable-output-file-buffering` позволяют строить
отдельный node-data ingestion pipeline. Это не готовый collector, но сильный
research/probe path. На ноутбуке постоянный node runtime запускать не надо:
docs предупреждают о больших логах, порядка 100 GB/day by default.

Hyperliquid node-data probe 2026-06-29: official S3 anonymous listing returned
403, so requester-pays AWS auth is needed for official sample. Public processed
mirror sample had 2.1 MB parquet, 26,236 liquidation fill rows, 1,779 unique
liquidation_id values, BTC rows, `market`/`backstop` methods, and all rows had
`raw_json.event.liquidation`. `notional_usd = price * size` is computable, but
rows can double-count both sides, so dedup policy is required before canonical
normalization.

Official Python SDK review: SDK supports `userEvents` and
`userNonFundingLedgerUpdates` as user-specific subscriptions/API calls and does
not expose a global `liquidations` subscription. It is useful for future
Hyperliquid account-risk monitor, not for market-wide cascade collection.

Official Rust SDK PR #175 review: open PR adds optional `liquidation:
FillLiquidation` and optional `builderFee` to `TradeInfo`/API `WsFill`.
This is useful schema evidence for our future Rust parser fixtures, but it is
not a public market-wide liquidation feed and should not be used as a production
dependency while unmerged.

## Bitget Candidate

Bitget official UTA liquidation channel:

- public WebSocket topic `liquidation`;
- request uses `instType=usdt-futures`;
- push interval 1s;
- each push contains aggregated liquidation data for previous second;
- for each pair, at most two records: largest long and largest short
  liquidation quantity;
- payload has `symbol`, `side`, `price`, `amount`, `ts`;
- `amount` is quote coin, so `notional_usd` can be mapped directly for
  USDT-futures, subject to fixture verification.

Bitget limitation: because the feed is aggregated and only keeps the largest
long/short liquidation per pair per second, it is not full all-events coverage.
It is useful as `diagnostic_only` and may improve signal-ready windows, but it
must not be treated as exact venue notional without source policy.

## Gate Candidate

Gate official futures public liquidates channel:

- WebSocket endpoint `wss://fx-ws.gateio.ws/v4/ws/usdt`;
- channel `futures.public_liquidates`;
- payload includes `price`, `size`, `time`, `contract`;
- source is public and symbol-scoped;
- `size` semantics need fixture/contract verification before canonical
  `notional_usd`.

Gate limitation: if `size` is contract size rather than quote notional, canonical
normalization must use contract metadata. Until verified, Gate may be raw-only or
canonical-with-metadata.

## HTX Candidate

HTX official USDT-M liquidation_orders:

- public topic `public.$contract_code.liquidation_orders`;
- no authentication required;
- payload includes `contract_code`, `direction`, `volume`, `price`, `amount`,
  `trade_turnover`, `created_at`;
- `trade_turnover` is quotation-token liquidation amount and is the preferred
  candidate for `notional_usd`.

HTX limitation: docs/payload naming must be fixture-tested because HTX contract
APIs can differ between coin-margined and USDT-margined variants.
