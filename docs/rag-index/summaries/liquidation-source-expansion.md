# Liquidation Source Expansion Summary

Retrieval summary: priority order is `hyperliquid_liquidations`,
`bitget`, `gate`, `htx`. Hyperliquid is `node_research_candidate`; Bitget,
Gate and HTX remain `diagnostic-only` candidates until official docs, fixtures,
live probe, overlap and source usefulness gates pass.

Текущий приоритет расширения liquidation sources:

1. `hyperliquid_liquidations` - node research candidate, not simple WebSocket
   collector.
2. `bitget` - diagnostic-only source.
3. `gate` - diagnostic-only source.
4. `htx` - later research/diagnostic source.

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
