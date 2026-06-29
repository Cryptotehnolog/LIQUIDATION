# Decision: Liquidation Source Expansion Priority

Дата: 2026-06-29.

Решение:

1. Hyperliquid liquidation source остается `research_blocked`, пока official
   public liquidation feed не подтвержден.
2. Bitget добавляется следующим как `diagnostic_only`.
3. Gate добавляется после Bitget как `diagnostic_only`.
4. HTX добавляется после Hyperliquid/Bitget/Gate как `research_candidate`, затем
   `diagnostic_only`.

Причина: по наблюдениям через Coinglass, когда Binance/Bybit/OKX молчат, больше
всего событий может давать Hyperliquid, затем Bitget, Gate и HTX.

Ограничение: Coinglass observation не является доказательством качества feed.
Новые sources не участвуют в сигналах до official docs review, fixture tests,
bounded live probe, correct `notional_usd`, overlap validation и source
usefulness report.

Запрещено автоматически суммировать liquidation notional across venues. Разные
feeds имеют разную полноту: all-events, snapshot-only, aggregated или
rate-limited.

Следующая автоматизация: source usefulness report с metrics events/hour,
canonical events/hour, max notional, latency, stale rate, overlap buckets и
replay windows made signal-ready.

Дополнение после probe 2026-06-29: official WebSocket docs и live probe не
подтвердили public all-market Hyperliquid liquidation subscription. Текущий
`hyperliquid` source остается hedge market-data leg; production
`hyperliquid_liquidations` collector не добавлять без нового documented
decision.

Уточнение: official `userEvents` subscription может вернуть `liquidation` для
конкретного address. Это будущий safety monitor для собственной Hyperliquid
hedge account, а не source для market-wide liquidation cascade signals.

Дополнительное уточнение: official `Trading / Liquidations` page подтверждает
механику ликвидаций и market orders to the book, но не даёт public market-wide
feed schema. Это не снимает `research_blocked` статус.
