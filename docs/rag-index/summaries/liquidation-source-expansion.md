# Liquidation Source Expansion Summary

Текущий приоритет расширения liquidation sources:

1. `hyperliquid_liquidations` - research blocked until official public
   liquidation feed is confirmed.
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
остается только hedge market-data leg, а `hyperliquid_liquidations` нельзя
добавлять в canonical collector до нового documented decision.

Official `userEvents` with `user=<address>` can emit liquidation events for that
address only. Это можно использовать позже как hedge account risk monitor, но
нельзя использовать как source рыночных liquidation cascades.
