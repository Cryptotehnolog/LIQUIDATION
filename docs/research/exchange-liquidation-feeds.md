# Exchange Liquidation Feeds Research

Дата проверки: 2026-06-19.

Обновление 2026-06-29: добавлен отдельный source expansion decision для
Hyperliquid, Bitget, Gate и HTX:
[liquidation-source-expansion-2026-06-29.md](liquidation-source-expansion-2026-06-29.md).

## Что проверяли

- Binance liquidation streams.
- Bybit all-liquidation WebSocket.
- OKX liquidation orders.
- Возможность REST backfill.
- Свежие community signals через `last30days`.

## `last30days` result

Raw output:
[crypto-liquidation-websocket-feed-reliability-raw-exchange-liquidation-feeds.md](raw/crypto-liquidation-websocket-feed-reliability-raw-exchange-liquidation-feeds.md)

`last30days` не нашел usable recent community evidence по теме exchange
liquidation websocket reliability. Это не значит, что проблем нет; это значит,
что по этой теме нельзя принимать решения на основе social layer в текущем
запуске.

## Official findings

### Binance

Official docs:
[USD-M Liquidation Order Streams](https://developers.binance.com/docs/derivatives/usds-margined-futures/websocket-market-streams/Liquidation-Order-Streams),
[COIN-M All Market Liquidation Order Streams](https://developers.binance.com/docs/derivatives/coin-margined-futures/websocket-market-streams/All-Market-Liquidation-Order-Streams).

Binance stream является snapshot-only:

- per-symbol stream публикует только largest liquidation order в 1000 ms window;
- all-market stream публикует latest liquidation order per symbol в 1000 ms
  window;
- если в window несколько liquidation events, часть событий не попадет в stream.

Решение: Binance не должен получать production signal weight в MVP. Его можно
писать как diagnostic source и использовать для source-health comparison.

### Bybit

Official docs:
[Bybit All Liquidation WebSocket](https://bybit-exchange.github.io/docs/v5/websocket/public/all-liquidation).

Bybit all-liquidation stream:

- покрывает USDT contract, USDC contract и inverse contract;
- topic format: `allLiquidation.{symbol}`;
- push frequency: 500 ms;
- documentation explicitly говорит, что stream pushes all liquidations that
  occur on Bybit.

Решение: Bybit остается primary liquidation source для MVP strategy signals,
если health checks проходят.

Bybit REST liquidation history endpoint не подтвержден в official docs во время
этого research. Предыдущая проверка `/v5/market/liquidation-history` возвращала
404. До появления current official page и fixture tests Bybit REST backfill
остается disabled.

### OKX

Official docs:
[OKX changelog](https://www.okx.com/docs-v5/log_en/),
[OKX API overview](https://www.okx.com/docs-v5/en/).

Критичная находка: OKX changelog сообщает, что endpoint
`GET /api/v5/public/liquidation-orders` был delisted, а пользователям
рекомендовано использовать WebSocket liquidation orders channel для real-time
data.

Решение: OKX REST liquidation backfill нельзя считать verified candidate. OKX
адаптер можно добавлять позже как WebSocket source после отдельной проверки
channel schema, heartbeat, reconnect и source-quality semantics.

OKX WebSocket docs также важны для collector design:

- connection breaks if subscription is not established or no data pushed for
  more than 30 seconds;
- recommended ping/pong loop;
- subscribe/unsubscribe/login request limit: 480 per hour per connection;
- public WebSocket connection setup has request limits.

Решение: для OKX adapter нужен explicit heartbeat watchdog и reconnect policy.

## Design impact

- `source_quality` должен различать `all_events`, `snapshot_only`,
  `websocket_only`, `disabled_backfill`, `derived`.
- Backfill не должен быть generic feature. Он должен быть source-specific,
  documented и fixture-tested.
- Strategy MVP использует Bybit primary-only для liquidation signals.
- Binance остается diagnostic.
- OKX добавляется после отдельного adapter research и WebSocket fixture.

## Что улучшить или автоматизировать

- Добавить endpoint probes для Bybit/Binance/OKX docs URLs.
- Добавить collector health metric: source coverage, reconnects, heartbeat age,
  event rate, stale source.
- Добавить nightly check API changelog для Binance/Bybit/OKX.
- Добавить source usefulness report для Hyperliquid/Bitget/Gate/HTX перед
  любым решением об участии этих источников в strategy signals.
