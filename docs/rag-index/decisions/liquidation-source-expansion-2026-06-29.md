# Decision: Liquidation Source Expansion Priority

Дата: 2026-06-29.

Решение:

1. Hyperliquid liquidation source переводится в `node_research_candidate`.
   Простой public WebSocket liquidation feed не подтвержден, но official node
   data path найден.
2. Bitget добавляется следующим как `diagnostic_only`.
3. Gate добавляется после Bitget как `diagnostic_only`.
4. HTX не добавляется в текущем цикле. Он остается `deferred_research_candidate`
   и возвращается в работу только при явном coverage blocker.

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

Дополнение по implementation 2026-06-29:

- Bitget добавлен как `diagnostic_only`, `source_quality=snapshot_only`.
- Gate добавлен как `diagnostic_only`, `source_quality=websocket_only`.
- Gate canonical normalization разрешается только при явном contract metadata
  cache с `quanto_multiplier`; иначе Gate payloads остаются raw-only.
- Новый probe guard `--until-canonical-events N --max-runtime-seconds N`
  нужен для broad feeds, чтобы bounded probe ждал именно canonical BTC event,
  но не зависал бесконечно.

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
WebSocket/REST feed schema.

Новая находка после проверки API/Nodes links: official `Nodes / L1 data schemas`
документирует `misc_events` with `LedgerDelta = Liquidation`, а node/API fills
могут содержать `FillLiquidation`. `hyperliquid-dex/node` поддерживает
`--write-fills`, `--write-misc-events`, `--batch-by-block` и
`--stream-with-block-info`. Следующий шаг - historical/node sample fixture, а
не WebSocket collector.

Дополнение 2026-06-30: после добавления Bitget и Gate как diagnostic-only
источников HTX намеренно отложен. Причина: сейчас главный вопрос - не собрать
еще один venue, а проверить экономику стратегии на уже доступных liquidation
sources, Polymarket fills и Hyperliquid hedge simulation. Добавление HTX сейчас
рискует превратить разработку в бесконечное расширение collector coverage.

Вернуться к HTX нужно, если выполняется хотя бы одно условие:

- controlled replay series по текущим sources не набирает достаточно
  `signal_count > 0` окон;
- source usefulness report показывает, что Bitget/Gate/OKX редко создают
  `liquidation_ready_buckets_without_primary`;
- наблюдения Coinglass в нескольких сессиях подряд показывают material BTC
  liquidation events на HTX, пока Binance/Bybit/OKX/Bitget/Gate молчат;
- перед server/paper-soak окажется, что coverage gap, а не entry fill/PnL,
  является главным bottleneck.
