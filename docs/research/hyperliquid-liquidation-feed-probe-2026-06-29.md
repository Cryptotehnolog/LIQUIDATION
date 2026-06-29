# Hyperliquid Liquidation Feed Probe

Дата проверки: 2026-06-29.

## Цель

Проверить, есть ли у Hyperliquid реальный public liquidation feed, который
можно честно нормализовать как `liquidation_events`, аналогично Bybit/Binance/OKX.

## Короткий вывод

На момент проверки простой public WebSocket/API all-market liquidation feed у
Hyperliquid не найден.

После дополнительной проверки всех API/Nodelinks найден официальный
node-based путь, который может дать market-wide liquidation data: Hyperliquid
non-validating node L1 output.

Hyperliquid остается:

- `coverage_role=hedge_market_data` для текущего `hyperliquid` source;
- `hyperliquid_liquidations=node_research_candidate`, не WebSocket collector;
- `participates_in_signals=false`;
- без canonical `liquidation_events`.

Retrieval summary: `hyperliquid_liquidations` is `node_research_candidate`;
`liquidations`/`liquidation` public market-wide subscriptions are not confirmed;
official `userEvents` is user-specific; current Hyperliquid integration remains
`hedge market-data`; future `userEvents` usage belongs to account risk monitor.
Official node data exposes `misc_events` with `LedgerDelta = Liquidation` and
node fills can include `FillLiquidation`; this is a research/probe path, not yet
a production collector.

Eval summary: `node_research_candidate`, `liquidations`, `liquidation`,
`user-specific`, `hedge market-data`, `account risk monitor`, `misc_events`,
`FillLiquidation`.

Это не означает, что ликвидаций на Hyperliquid нет. Это означает, что в
публичном API пока не доказан честный источник all-market liquidation events,
который можно безопасно включить в collector.

## Official docs review

Проверенные official docs страницы:

- https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/api/websocket/subscriptions
- https://hyperliquid.gitbook.io/hyperliquid-docs/trading/liquidations

Страница `Trading / Liquidations` подтверждает, что Hyperliquid отдельно
документирует механику ликвидаций:

- liquidation event occurs when account equity falls below maintenance margin;
- positions are first attempted to be closed by sending market orders to the
  book;
- if the account drops below 2/3 of maintenance margin, backstop liquidation can
  happen through the liquidator vault;
- for positions larger than 100k USDC, only 20% can be sent as a market
  liquidation order first, followed by a cooldown rule;
- liquidations use mark price.

Эта страница важна для понимания market microstructure Hyperliquid, но она не
публикует точный public WebSocket channel, REST endpoint или live JSON schema
для market-wide liquidation feed.

### API / Historical data / Nodes links review

Дополнительно проверены страницы:

- https://hyperliquid.gitbook.io/hyperliquid-docs/historical-data
- https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/nodes
- https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/nodes/l1-data-schemas
- https://github.com/hyperliquid-dex/node

Найдена более серьёзная возможность, чем WebSocket `liquidations`:

- `Historical data` указывает на `s3://hl-mainnet-node-data/node_fills_by_block`
  и `explorer_blocks` / `replica_cmds`.
- `L1 data schemas` описывает node output:
  - `node_trades`;
  - `node_fills`;
  - `misc_events`;
  - `raw_book_diffs`;
  - `order_statuses`.
- `misc_events` содержит `LedgerDelta = Liquidation`.
- `Liquidation` schema содержит:
  - `liquidatedNtlPos`;
  - `accountValue`;
  - `leverageType`;
  - `liquidatedPositions: Array<LiquidatedPosition>`;
  - `LiquidatedPosition { coin, szi }`.
- `WsFill`/node fills schema может содержать `liquidation?: FillLiquidation`,
  где `FillLiquidation` включает `liquidatedUser`, `markPx`, `method:
  "market" | "backstop"`.
- `hyperliquid-dex/node` flags позволяют писать эти данные локально:
  - `--write-fills`;
  - `--write-misc-events`;
  - `--batch-by-block`;
  - `--stream-with-block-info`;
  - `--disable-output-file-buffering`.

Это означает: Hyperliquid liquidation source нельзя списывать. Но его правильная
архитектура не WebSocket adapter, а отдельный node-data ingestion pipeline.

Operational caveats:

- node docs предупреждают примерно о 100 GB logs/day with default settings;
- foundation non-validating node access is best-efforts и не должен быть
  единственным authoritative source for trading;
- для низкой latency нужны отдельная машина/сервер, disk retention и monitoring;
- на ноутбуке такой collector запускать рискованно.

Документация перечисляет market-data subscriptions вроде:

- `allMids`;
- `notification`;
- `webData2`;
- `candle`;
- `l2Book`;
- `trades`;
- `bbo`;
- user-specific streams: `userEvents`, `userFills`, `userFundings`,
  `orderUpdates` и другие.

`liquidation` встречается в user-specific event schema:

```json
{"method":"subscribe","subscription":{"type":"userEvents","user":"<address>"}}
```

Это официальный путь получить liquidation event конкретного Hyperliquid address.
Но это не public all-market liquidation feed. Такой stream нельзя использовать
для общего рыночного liquidation collector без списка пользователей и без
нарушения семантики данных.

Практический вывод:

- `userEvents` можно использовать позже для мониторинга нашей собственной
  Hyperliquid hedge account risk и emergency alerts;
- `userEvents` нельзя использовать для поиска рыночных liquidation cascades;
- `userNonFundingLedgerUpdates` также относится к конкретному user/address и не
  является market-wide liquidation source.

## Live WebSocket probe

Endpoint:

```text
wss://api.hyperliquid.xyz/ws
```

Проверенные subscriptions:

```json
{"method":"subscribe","subscription":{"type":"bbo","coin":"BTC"}}
```

Результат: accepted, приходят `bbo` payloads. Это подтверждает, что WebSocket
endpoint доступен и текущий hedge market-data leg корректно основан на public
market data.

```json
{"method":"subscribe","subscription":{"type":"liquidations","coin":"BTC"}}
```

Результат:

```text
Error parsing JSON into valid websocket request
```

```json
{"method":"subscribe","subscription":{"type":"liquidation","coin":"BTC"}}
```

Результат:

```text
Error parsing JSON into valid websocket request
```

Также проверены неофициальные/guess subscriptions:

- `fills`: rejected;
- `explorerTxs`: accepted, но не документирован как liquidation feed и в probe
  вернул пустой snapshot;
- `explorerBlock`: accepted, но не документирован как liquidation feed и в probe
  вернул пустой snapshot.

`explorerTxs`/`explorerBlock` нельзя использовать как production source без
отдельной official contract/schema проверки. Даже если там позднее появятся
похожие события, это будет raw research stream, а не canonical liquidation feed.

## Что можно и нельзя вывести из Liquidations page

Можно вывести:

- Hyperliquid liquidations часто превращаются в market orders to the book.
- Теоретически часть liquidation flow может быть видна как обычные trades.
- Для стратегии это объясняет, почему Coinglass может видеть активность
  Hyperliquid liquidation flow.

Нельзя вывести:

- что ordinary public `trades` payload содержит explicit liquidation marker;
- что каждый market order during liquidation можно отличить от обычного market
  order;
- что есть public all-market `liquidations` subscription;
- что можно честно построить canonical `liquidation_events` без documented
  event marker или payload schema.

Поэтому текущий blocker не в том, что Hyperliquid не документирует ликвидации
как торговую механику. Blocker в том, что official API docs пока не показывают
документированный public market-wide feed с liquidation event payload.

## Почему Hyperliquid liquidation collector не добавлен

Hyperliquid WebSocket liquidation collector не добавлен, потому что public
`liquidations`/`liquidation` market-wide subscription не подтвержден. Official
`userEvents` является `user-specific` stream для конкретного address. Текущий
Hyperliquid connector остается `hedge market-data` leg.

Но Hyperliquid liquidation source больше не надо считать тупиком:
`hyperliquid_liquidations` переводится в `node_research_candidate`. Следующая
проверка должна идти через historical S3/node sample или non-validating node
output, где есть `misc_events` `Liquidation` и fills with `FillLiquidation`.

## Почему Coinglass недостаточно

Coinglass показывает Hyperliquid liquidation activity и это полезный
операционный сигнал. Но Coinglass не доказывает:

- какой public endpoint использован;
- полная ли это история или derived/aggregated feed;
- есть ли stable event id;
- можно ли честно посчитать `notional_usd`;
- совпадает ли semantics с Bybit/Binance/OKX.

Поэтому Coinglass observation не является основанием включать Hyperliquid в
strategy signals.

## Решение

Не добавлять production Hyperliquid liquidation collector сейчас.

Разрешено:

- оставить текущий Hyperliquid market-data connector для hedge simulation;
- добавить research task на Hyperliquid node-data ingestion;
- сначала проверить historical S3/node sample, затем только проектировать
  live non-validating-node collector;
- использовать `userEvents` позже только для hedge account risk monitor.

Запрещено:

- нормализовать `trades` как ликвидации;
- выводить liquidation side/notional из обычных trades/orderbook без explicit
  liquidation marker;
- использовать user-specific `userEvents` как all-market feed;
- использовать собственные `userEvents` hedge account как proxy для чужих
  рыночных ликвидаций;
- включать Hyperliquid liquidation data в signals без documented policy decision.

## Follow-up gates

Чтобы снять blocker, нужно выполнить все пункты:

1. Найти official public liquidation feed или documented public raw stream,
   который явно содержит liquidation marker.
2. Для Hyperliquid node path: получить sample из historical S3 или локального
   non-validating node output.
3. Сохранить fixture с реальным `misc_events` liquidation и/или fill payload
   with `FillLiquidation`.
4. Доказать поля: side, price/mark price, size/szi, `notional_usd`, block time,
   source event id.
5. Добавить normalizer tests.
6. Провести bounded probe с raw и canonical inserts.
7. Проверить source usefulness report: events/hour, max notional, latency,
   stale rate, overlap buckets, liquidation-ready buckets without primary.
8. Принять отдельное documented decision перед любым signal eligibility.

## Что улучшить или автоматизировать

- Добавить периодический docs/API check, который ищет новые Hyperliquid
  subscription types и слова `liquidation`/`liquidations` в official docs.
- Добавить raw research probe для `explorerTxs` только как отдельный
  non-canonical experiment, если official docs появятся или schema станет
  стабильной.
- Отдельно добавить future task: Hyperliquid account-risk monitor через
  `userEvents` для собственной hedge-ноги. Это не source для стратегии, а safety
  monitor.
- Добавить `hyperliquid-node-data` research/probe:
  1. исторический S3 sample `node_fills_by_block`/`misc_events`;
  2. fixture parser;
  3. оценка disk/CPU/network для live node;
  4. решение, где запускать node: точно не на текущем ноутбуке как постоянный
     runtime.

Follow-up probe completed:
[hyperliquid-node-data-probe-2026-06-29.md](hyperliquid-node-data-probe-2026-06-29.md).
