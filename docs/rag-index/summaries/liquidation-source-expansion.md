# Liquidation Source Expansion Summary

Retrieval summary: Hyperliquid market-wide liquidations are deferred because
official access requires node output / `hl-visor` research, not a lightweight
public liquidation-only feed. `bitget` and `gate` are implemented as
diagnostic-only sources. `htx` is deferred until source coverage becomes a real
blocker. These sources remain outside strategy signals until official docs,
fixtures, live probe, overlap and source usefulness gates pass.

Текущий приоритет расширения liquidation sources после решения 2026-06-29:

1. `bitget` - implemented diagnostic-only source; official public UTA
   liquidation channel, aggregated by one-second buckets.
2. `gate` - implemented diagnostic-only source with metadata-gated canonical
   normalization; official public futures liquidates channel.
3. `htx` - deferred research candidate; do not build now unless coverage
   blockers are proven by controlled replay/source usefulness reports.
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

Implementation update 2026-06-30: `scripts/source-signal-readiness-report.ps1`
wraps `source-usefulness-report.ps1` and then runs
`scripts/analyze-source-signal-readiness.ps1`. The current-source set is
`bybit`, `binance`, `okx`, `bitget`, `gate`; HTX is intentionally excluded.
The analyzer writes `.cache/source-usefulness/signal-readiness.json` with
`signal_ready_windows_proxy` per source and an `htx_decision` classification.
This is a coverage proxy, not a PnL proof.

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

- public WebSocket endpoint `wss://ws.bitget.com/v3/ws/public`;
- public WebSocket topic `liquidation`;
- request uses `instType=usdt-futures` and `topic=liquidation`;
- push interval 1s;
- each push contains aggregated liquidation data for previous second;
- for each pair, at most two records: largest long and largest short
  liquidation quantity;
- payload has `symbol`, `side`, `price`, `amount`, `ts`;
- docs define `side=buy` as long position liquidation and `side=sell` as short
  position liquidation;
- `amount` is quote coin, so `notional_usd` can be mapped directly for
  USDT-futures, subject to fixture verification.

Bitget limitation: because the feed is aggregated and only keeps the largest
long/short liquidation per pair per second, it is not full all-events coverage.
It is useful as `diagnostic_only` and may improve signal-ready windows, but it
must not be treated as exact venue notional without source policy.

Implementation note 2026-06-29: bounded live probe connected to
`wss://ws.bitget.com/v3/ws/public`. A first probe received liquidation payloads
for non-BTC symbols despite a BTCUSDT subscription, so collector routing must
filter canonical events by the requested symbol. After adding the filter, a
second short probe received 5 messages, normalized 0 BTCUSDT events, inserted 0
raw/canonical rows, and had 1 reconnect. This is acceptable for a quiet BTC
window and prevents non-BTC contamination of BTC replay.

## Gate Candidate

Gate official futures public liquidates channel:

- WebSocket endpoint `wss://fx-ws.gateio.ws/v4/ws/usdt`;
- channel `futures.public_liquidates`;
- payload includes `price`, `size`, `time`, `contract`;
- source is public and symbol-scoped;
- `size` is contract quantity, not quote notional;
- canonical `notional_usd` requires contract metadata with `quanto_multiplier`;
- MVP formula: `quantity_base = abs(size) * quanto_multiplier`,
  `notional_usd = quantity_base * price`.

Implementation note 2026-06-29: Gate was added as `diagnostic_only` source with
`source_quality=websocket_only`. Without `--gate-contracts-path`, the collector
keeps Gate liquidation payloads as raw-only. With a validated contract metadata
cache, canonical normalization is allowed for supported contracts such as
`BTC_USDT`. Gate does not participate in strategy signals until live probe,
overlap/usefulness and replay usefulness gates pass.

## HTX Candidate

Decision update 2026-06-30: do not implement HTX in the current cycle. The
current priority is to run controlled replay windows and evaluate signal,
entry-fill, hedge-fill and net-PnL quality using existing sources. HTX returns
only if coverage, not fill quality or economics, is proven to be the bottleneck.

HTX official USDT-M liquidation_orders:

- public topic `public.$contract_code.liquidation_orders`;
- no authentication required;
- payload includes `contract_code`, `direction`, `volume`, `price`, `amount`,
  `trade_turnover`, `created_at`;
- `trade_turnover` is quotation-token liquidation amount and is the preferred
  candidate for `notional_usd`.

HTX limitation: docs/payload naming must be fixture-tested because HTX contract
APIs can differ between coin-margined and USDT-margined variants.
