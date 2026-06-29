# Liquidation Source Expansion Research Note

Дата решения: 2026-06-29.

## Контекст

Во время controlled replay windows стало видно, что текущие источники
ликвидаций не всегда дают достаточно событий для проверки стратегии:

- Bybit остается самым чистым primary source, потому что official docs
  описывают `allLiquidation.{symbol}` как all-liquidation stream.
- Binance полезен, но snapshot-only, поэтому часть событий внутри 1000 ms
  window может теряться.
- OKX уже добавлен как diagnostic source, но не должен автоматически влиять на
  сигнал.
- По наблюдениям через Coinglass, когда Binance, Bybit и OKX молчат, больше
  всего событий может давать Hyperliquid, затем Bitget, Gate и HTX.

Coinglass observation считается сильным операционным сигналом, но не
доказательством качества источника. Каждый новый источник должен пройти
официальную проверку документации, fixture tests, bounded live probe и overlap
report.

## Решение по приоритету

Новый порядок исследования и добавления источников:

1. `hyperliquid_liquidations`: research blocked until official public feed is
   confirmed.
2. `bitget`: diagnostic liquidation source.
3. `gate`: diagnostic liquidation source.
4. `htx`: diagnostic liquidation source.

Этот порядок заменяет старое общее backlog-решение "extra diagnostic exchanges
after OKX" и делает Hyperliquid первым кандидатом из-за наблюдаемой активности
на Coinglass.

## Source policy

Все новые источники сначала добавляются как:

- `coverage_role=diagnostic_only`;
- `participates_in_signals=false`;
- `signal_weight=0`;
- `notional_usd` required for canonical events;
- raw-only, если `notional_usd` нельзя честно посчитать из payload и verified
  instrument metadata.

Запрещено просто суммировать liquidation notional с Bybit/Binance/OKX и новых
venues. Разные биржи публикуют события с разной полнотой: all-events,
snapshot-only, aggregated или rate-limited. Преждевременное суммирование
создает ложный liquidation pressure и может дать фальшивые сигналы.

## Hyperliquid

Hyperliquid уже используется как hedge market-data leg для paper hedge
simulation. Новая идея - отдельно исследовать Hyperliquid как источник
ликвидаций.

Текущий статус: `research_blocked`, не готовый diagnostic source.

Причина: проверка official WebSocket docs и live probe 2026-06-29 не подтвердили
public all-market liquidation stream. Public `bbo` работает, но subscriptions
`liquidations` и `liquidation` отклоняются endpoint'ом. `liquidation` есть в
user-specific event schema, но это не общий market feed.

Связанная проверка:
[hyperliquid-liquidation-feed-probe-2026-06-29.md](hyperliquid-liquidation-feed-probe-2026-06-29.md).

До появления official public liquidation feed запрещено нормализовать обычные
Hyperliquid trades/orderbook как ликвидации.

Gate для включения:

- найден official public liquidation feed или documented public payload source
  с explicit liquidation marker;
- есть fixture с реальным liquidation payload;
- normalizer доказывает side, price, quantity и `notional_usd`;
- bounded live probe показывает raw events;
- source usefulness report показывает, что Hyperliquid добавляет signal-ready
  windows сверх Bybit/Binance/OKX.

До прохождения gates Hyperliquid остается только hedge market-data leg.

## Bitget

Bitget является candidate number 2.

Статус: `diagnostic_only` после реализации.

Официальная причина быть осторожным: Bitget liquidation channel является
агрегированным public feed. Он полезен для coverage, но не должен считаться
all-events primary source без отдельного validation.

Gate для включения:

- official liquidation channel documented;
- fixture покрывает long/short liquidation payload;
- `notional_usd` считается из quote amount или другой явно документированной
  величины;
- source policy явно помечает feed как aggregated/snapshot diagnostic;
- dashboard показывает Bitget отдельно от strategy-primary источников.

## Gate

Gate является candidate number 3.

Статус: `diagnostic_only` после реализации.

Причина осторожности: `futures.public_liquidates` полезен, включая подписку на
`!all`, но feed имеет ограничения частоты на contract. Такой источник нельзя
считать полноценным all-events stream без проверки coverage.

Gate для включения:

- official docs сохранены в research note;
- fixture покрывает liquidation payload;
- parser правильно различает contract, side, price и size;
- `notional_usd` считается только после instrument metadata validation;
- source usefulness report показывает реальную добавленную ценность.

## HTX

HTX является candidate number 4.

Статус: `research_candidate`, затем `diagnostic_only`.

Причина более низкого приоритета: документация и product naming фрагментированы
между futures/swap variants. Перед реализацией нужно отдельно проверить
актуальный endpoint, topic naming, heartbeat, contract value и payload schema.

## Gates для перевода diagnostic source в signal-eligible

Источник может стать `signal_eligible` только после отдельного решения и только
если выполнены все условия:

1. Official docs подтверждают semantics feed: all-events или явно описанная
   aggregation/snapshot policy.
2. Live probe стабильно пишет raw и canonical rows.
3. `notional_usd` считается без floating point и без догадок.
4. Overlap/source usefulness report показывает добавленную ценность:
   events/hour, max notional, stale rate, latency, overlap with primary sources.
5. Replay report показывает, сколько windows стали signal-ready благодаря этому
   source.
6. Dashboard явно отделяет signal sources от diagnostic-only sources.
7. Решение внесено в docs и ApeRAG memory.

До выполнения этих gates источник не участвует в стратегии.

## Source usefulness report

Нужен отдельный report, который считает по каждому source:

- events/hour;
- canonical events/hour;
- max notional;
- median and p95 receive latency;
- stale rate;
- overlap buckets с Bybit/Binance/OKX;
- number of replay windows that became signal-ready only because this source
  was present;
- diagnostic verdict: `useful-diagnostic`, `sparse-but-useful`,
  `noisy-or-duplicative`, `unreliable`, `insufficient-data`.

Этот report должен быть read-only и не менять source policy автоматически.

## Что улучшить или автоматизировать

- Добавить `scripts/source-usefulness-report.ps1` или Rust CLI command.
- Добавить nightly diagnostic job для Hyperliquid/Bitget/Gate/HTX после
  появления соответствующих collectors.
- Добавить dashboard block: `source coverage expansion`, где новые venues
  видны как `diagnostic_only` до ручного policy decision.
