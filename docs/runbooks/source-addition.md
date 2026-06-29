# Source Addition Runbook

Этот runbook описывает обязательный путь добавления нового market-data source в
LIQUIDATION. Цель: новый источник не должен появляться частично, без fixture,
normalizer test, source policy, dashboard visibility и CI guard.

## Обязательное правило

Новый источник сначала добавляется как diagnostic-only, пока не доказано:

- официальный WebSocket/REST contract понятен и сохранен в research notes;
- payload schema покрыта fixture tests;
- `notional_usd` считается корректно для instrument type;
- source-quality semantics определены без догадок;
- есть live probe и overlap validation against existing sources.

Если `notional_usd` нельзя посчитать честно, источник остается raw-only и не
пишет canonical `liquidation_events`.

## Текущая source policy

- `bybit`: `source_quality=all_events`, `coverage_role=strategy_primary`,
  `participates_in_signals=true`.
- `binance`: `source_quality=snapshot_only`,
  `coverage_role=diagnostic_only`, `participates_in_signals=false`.
- `okx`: `source_quality=websocket_only`, `coverage_role=diagnostic_only`,
  `participates_in_signals=false`.
- `bitget`: `source_quality=snapshot_only`, `coverage_role=diagnostic_only`,
  `participates_in_signals=false`.
- `gate`: `source_quality=websocket_only`, `coverage_role=diagnostic_only`,
  `participates_in_signals=false`.
- `polymarket`: `source_quality=websocket_only`,
  `coverage_role=market_data_leg`, `participates_in_signals=false`.
- `hyperliquid`: `source_quality=websocket_only`,
  `coverage_role=hedge_market_data`, `participates_in_signals=false`.

## Приоритет расширения liquidation sources

Решение от 2026-06-29, обновлено после Hyperliquid node-output review:

1. `bitget`: следующий diagnostic liquidation source; official public UTA
   liquidation channel.
2. `gate`: следующий diagnostic liquidation source после Bitget; official
   public futures liquidates channel.
3. `htx`: deferred research candidate; official USDT-M liquidation_orders
   channel, но не строить сейчас без доказанного coverage blocker.
4. `hyperliquid_liquidations`: deferred `node_research_candidate`; не WebSocket
   collector, не включать в сигналы и не смешивать с текущим hedge market-data
   leg.

Причина: по наблюдениям через Coinglass, когда Binance/Bybit/OKX молчат,
больше всего событий может давать Hyperliquid, затем Bitget, Gate и HTX. Это
операционный сигнал, но не доказательство. Hyperliquid временно отложен,
потому что official market-wide path требует node output и тяжелее локальной
итерации. HTX временно отложен, потому что после Bitget/Gate следующий bottleneck
нужно искать в controlled replay, entry fill, hedge fill и net PnL, а не в
механическом добавлении еще одного venue. Каждый источник проходит official docs
review, fixture tests, bounded live probe и source usefulness report.

Вернуться к HTX можно только если controlled replay/source usefulness показывает,
что текущих sources недостаточно для signal-ready windows, или если повторные
наблюдения Coinglass показывают material HTX BTC liquidations при тишине
Binance/Bybit/OKX/Bitget/Gate.

Все новые источники по умолчанию:

- `coverage_role=diagnostic_only`;
- `participates_in_signals=false`;
- не получают signal weight;
- не пишут canonical `liquidation_events`, если `notional_usd` нельзя посчитать
  честно из payload и verified metadata.

Перевод diagnostic source в signal-eligible запрещен без отдельного documented
decision. Нельзя просто суммировать liquidation notional across venues: feeds
могут быть all-events, snapshot-only, aggregated или rate-limited.

Связанная research note:
[liquidation-source-expansion-2026-06-29.md](../research/liquidation-source-expansion-2026-06-29.md).

`okx` намеренно не участвует в сигналах по умолчанию: OKX
`liquidation-orders` WebSocket дает liquidation details, но безопасный
`notional_usd` требует instrument metadata/contract value.

Canonical OKX normalization разрешается только при явном metadata cache:

- источник metadata: `GET /api/v5/public/instruments?instType=SWAP&instId=...`;
- обязательные поля: `instId`, `ctVal`, `ctValCcy`;
- поддержанный MVP-case: `ctValCcy` совпадает с base asset инструмента,
  например `BTC-USDT-SWAP` и `ctValCcy=BTC`;
- формула: `quantity_base = sz * ctVal`, `notional_usd = quantity_base * bkPx`;
- если metadata отсутствует или не доказывает формулу, OKX остается raw-only.

## Executable guard

Перед commit запускайте:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\check-source-addition.ps1
```

Для проверки одного источника:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\check-source-addition.ps1 -Source okx
```

Guard проверяет:

- `liq-domain` source enum и stable source id;
- `liq-config` config section и `config/default.toml`;
- `liq-connectors` module export;
- fixture file;
- normalization/raw parser test;
- `liq-collector` routing;
- dashboard/source policy в `liq-recorder`;
- наличие источника в этом runbook.

## Bitget notes

Official decision:

- Bitget UTA public liquidation channel добавлен как `diagnostic_only`.
- Endpoint: `wss://ws.bitget.com/v3/ws/public`.
- Subscribe args: `instType=usdt-futures`, `topic=liquidation`, `symbol=BTCUSDT`.
- Push interval: 1s.
- Feed aggregated: за каждую пару приходит максимум largest long и largest
  short liquidation за предыдущую секунду.
- `side=buy` означает long position liquidation, `side=sell` означает short
  position liquidation.
- `amount` описан как quote coin, поэтому для USDT futures canonical
  `notional_usd=amount` разрешён.
- Collector обязан фильтровать canonical events по requested `symbol`: live
  probe 2026-06-29 показал, что Bitget может прислать broader liquidation
  payloads, даже если подписка отправлена с `symbol=BTCUSDT`.

Ограничение: это не all-events feed. Bitget не участвует в сигналах до source
usefulness/overlap/replay decision.

Минимальная bounded probe:

```powershell
$env:DATABASE_URL="postgres://liquidation:liquidation@127.0.0.1:15433/liquidation"
cargo run -p liq-cli -- collector probe --source bitget --symbol BTCUSDT --max-messages 5 --min-messages 0 --read-timeout-seconds 60
cargo run -p liq-cli -- collector usefulness-report --window-minutes 120 --json
```

Ожидаемо:

- `bitget` отображается как `diagnostic_only`;
- `source_quality=snapshot_only`;
- `participates_in_signals=false`;
- если в окне были liquidation payloads, `canonical_events` и `max_notional_usd`
  считаются по USDT quote amount.

## Gate notes

Official decision:

- Gate futures public liquidates channel добавлен как `diagnostic_only`.
- Endpoint для USDT futures: `wss://fx-ws.gateio.ws/v4/ws/usdt`.
- Subscribe channel: `futures.public_liquidates`, payload `["BTC_USDT"]`.
- WebSocket payload содержит `contract`, `size`, `price`, `time`/`time_ms`.
- `size` является количеством contracts, а не USD-notional.
- Canonical normalization разрешается только при явном Gate contract metadata
  cache с `name` и `quanto_multiplier`.
- Формула MVP: `quantity_base = abs(size) * quanto_multiplier`,
  `notional_usd = quantity_base * price`.
- Без metadata Gate остается raw-only: payload сохраняется, но
  `liquidation_events` не пишутся.
- Gate не участвует в сигналах до source usefulness/overlap/replay decision.

Минимальная bounded probe после настройки БД и contract metadata:

```powershell
$env:DATABASE_URL="postgres://liquidation:liquidation@127.0.0.1:15433/liquidation"
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\fetch-gate-contract.ps1 -Contract BTC_USDT
cargo run -p liq-cli -- collector probe --source gate --symbol BTC_USDT --gate-contracts-path .cache\gate\contract-BTC_USDT.json --max-messages 500 --min-messages 0 --max-runtime-seconds 180 --read-timeout-seconds 60 --until-canonical-events 1
cargo run -p liq-cli -- collector usefulness-report --window-minutes 120 --json
```

Ожидаемо:

- `gate` отображается как `diagnostic_only`;
- `source_quality=websocket_only`;
- `participates_in_signals=false`;
- canonical rows появляются только если metadata есть и в bounded window
  реально пришёл `BTC_USDT` liquidation payload.

## Checklist добавления нового источника

1. Проверить official docs и changelog.
2. Добавить source id в `liq-domain`.
3. Добавить config section в `liq-config` и `config/default.toml`.
4. Добавить connector module и fixture.
5. Добавить normalizer или raw-only parser test.
6. Добавить `CollectorSource` routing, URL и subscribe message.
7. Добавить dashboard/source policy.
8. Добавить dashboard smoke fixture только если новый source должен быть виден
   в default fixture.
9. Добавить source в `scripts/check-source-addition.ps1`.
10. Запустить guard и targeted tests.
11. Добавить source usefulness report fields: events/hour, max notional,
    latency, stale rate, overlap buckets и replay windows made signal-ready.

## OKX notes

Official decision:

- REST liquidation backfill для OKX остается disabled.
- OKX WebSocket endpoint для `liquidation-orders` можно использовать как
  realtime diagnostic source.
- Canonical normalization для OKX блокируется до instrument metadata.

Минимальная bounded probe после настройки БД:

```powershell
$env:DATABASE_URL="postgres://liquidation:liquidation@127.0.0.1:15433/liquidation"
cargo run -p liq-cli -- collector probe --source okx --symbol BTC-USDT-SWAP --max-messages 1 --min-messages 0 --read-timeout-seconds 30
```

Ожидаемо:

- `raw_inserted` может стать больше 0 при наличии liquidation payload;
- `normalized_events=0` и `canonical_inserted=0` до instrument metadata;
- dashboard показывает `okx` как `diagnostic_only`.

Для canonical OKX probe сначала скачайте и провалидируйте official instruments
response. Не сохраняйте JSON вручную: так легко получить BOM, неполный payload
или metadata для другого instrument.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\fetch-okx-instruments.ps1 -Symbol BTC-USDT-SWAP -OutputPath .cache\okx\instruments-BTC-USDT-SWAP.json
```

Скрипт проверяет:

- `code=0`;
- ровно один `instId`, совпадающий с `-Symbol`;
- `instType=SWAP`;
- положительный `ctVal`;
- непустой `ctValCcy`;
- `ctValCcy` совпадает с base asset инструмента, например `BTC` для
  `BTC-USDT-SWAP`;
- output пишется как UTF-8 без BOM, чтобы Rust `serde_json` мог читать файл.

После этого запустите bounded canonical probe:

```powershell
$env:DATABASE_URL="postgres://liquidation:liquidation@127.0.0.1:15433/liquidation"
cargo run -p liq-cli -- collector probe --source okx --symbol BTC-USDT-SWAP --okx-instruments-path .cache/okx/instruments-BTC-USDT-SWAP.json --max-messages 1 --min-messages 0 --read-timeout-seconds 30
```

Для dashboard visibility лучше использовать bounded `collector run`, потому что
он пишет `collector_health` даже если в коротком окне нет liquidation event:

```powershell
$env:DATABASE_URL="postgres://liquidation:liquidation@127.0.0.1:15433/liquidation"
cargo run -p liq-cli -- collector run --source okx --symbol BTC-USDT-SWAP --okx-instruments-path .cache\okx\instruments-BTC-USDT-SWAP.json --max-runtime-seconds 15 --health-interval-seconds 3 --read-timeout-seconds 10 --batch-flush-interval-seconds 1
cargo run -p liq-cli -- collector status --source okx --json --window-minutes 60
```

Даже в canonical mode OKX остается `diagnostic_only` до overlap validation и
ручного решения о signal policy.

## Polymarket / Hyperliquid market-data legs

`polymarket` и `hyperliquid` добавлены не как источники liquidation signal, а
как обязательные legs для pre-strategy readiness:

- Polymarket CLOB market channel дает public prediction-market quotes/trades.
- Hyperliquid public market data дает hedge-side quotes/trades для paper hedge
  simulation.
- Оба источника по умолчанию disabled в `config/default.toml`.
- `polymarket.symbols` может быть пустым, пока source disabled: реальный
  `asset_id` зависит от выбранного Polymarket market/outcome и не должен быть
  фальшивым default.
- При включении любого source `config validate` требует непустой `symbols`.
- `strategy readiness --database-url ... --json` закрывает:
  - `polymarket_live_probe`, если в readiness window есть хотя бы один
    `market_quotes` или `market_trades` row с `venue = 'polymarket'`;
  - `hyperliquid_market_data_probe`, если есть и quote rows, и trade rows с
    `venue = 'hyperliquid'`.

Минимальные bounded probes:

```powershell
$env:DATABASE_URL="postgres://liquidation:liquidation@127.0.0.1:15433/liquidation"
cargo run -p liq-cli -- collector probe --source polymarket --symbol <polymarket_asset_id> --max-messages 40 --min-messages 1 --read-timeout-seconds 60
cargo run -p liq-cli -- collector probe --source hyperliquid --symbol BTC --max-messages 40 --min-messages 1 --read-timeout-seconds 60
cargo run -p liq-cli -- strategy readiness --database-url $env:DATABASE_URL --window-minutes 60 --json
```

## Hyperliquid liquidation source status

`hyperliquid` в текущем collector - это hedge market-data source, не liquidation
source.

Проверка 2026-06-29:

- Retrieval guard: Hyperliquid node-data probe says `notional_usd = price * size`,
  `liquidation_id` can repeat and double-count, and official raw
  verification needs requester-pays S3 access or bounded node output.
- official `Trading / Liquidations` page описывает механику ликвидаций,
  market orders to the book, partial liquidations и liquidator vault;
- official WebSocket subscriptions docs не показывают public all-market
  `liquidations` stream;
- live probe подтвердил `bbo` market data;
- live probe отклонил subscriptions `liquidations` и `liquidation`;
- `liquidation` events в docs относятся к user-specific event streams, а не к
  public market-wide feed.
- official `Nodes / L1 data schemas` показывает node-data path:
  `misc_events` содержит `LedgerDelta = Liquidation`, а node/API fills могут
  содержать `FillLiquidation`.
- `hyperliquid-dex/node` поддерживает `--write-fills`, `--write-misc-events`,
  `--batch-by-block`, `--stream-with-block-info`,
  `--disable-output-file-buffering`.

Важно: official `userEvents` subscription:

```json
{"method":"subscribe","subscription":{"type":"userEvents","user":"<address>"}}
```

может вернуть `liquidation` для указанного address. Это пригодно для будущего
Hyperliquid hedge account risk monitor, но не для market-wide liquidation
collector. Наша стратегия ищет каскады ликвидаций по рынку, а не только события
собственного адреса.

Следствие: production WebSocket `hyperliquid_liquidations` collector не
добавлять. Но node-based Hyperliquid liquidation ingestion является реальным
research candidate.

Не путать две вещи:

- `Liquidations` trading page доказывает, что liquidation mechanics существуют
  и важны для market microstructure;
- она не доказывает, что public API отдаёт market-wide liquidation events с
  нормализуемым payload.
- node-data docs доказывают, что можно исследовать market-wide liquidation
  events через L1 data output, но это другой operational class: node runtime,
  большие логи, отдельное хранение и отдельные gates.

Запрещено:

- нормализовать ordinary Hyperliquid `trades` как ликвидации;
- выводить liquidation notional из orderbook/trade prints без marker;
- использовать user-specific streams как global liquidation source.
- использовать own-account `userEvents` как proxy для market-wide liquidation
  cascades.

Разрешенный следующий Hyperliquid path:

1. Не трогать текущий `hyperliquid` hedge market-data connector.
2. Добавить research fixture из historical S3/node output:
   `misc_events` `Liquidation` или `node_fills_by_block` with
   `FillLiquidation`.
3. Написать parser/normalizer tests.
4. Оценить node runtime отдельно. Official docs предупреждают, что default node
   output может давать около 100 GB logs/day.
5. Только после этого решать, нужен ли отдельный server-side
   `hyperliquid-node` collector.

Текущий research probe:
[hyperliquid-node-data-probe-2026-06-29.md](../research/hyperliquid-node-data-probe-2026-06-29.md).

Official Python SDK:
[hyperliquid-dex/hyperliquid-python-sdk](https://github.com/hyperliquid-dex/hyperliquid-python-sdk)
подтверждает `userEvents` и `userNonFundingLedgerUpdates` как user-specific
paths. SDK полезен для future account-risk monitor, но не даёт global
`liquidations` subscription.

Official Rust SDK PR #175:
[hyperliquid-dex/hyperliquid-rust-sdk#175](https://github.com/hyperliquid-dex/hyperliquid-rust-sdk/pull/175)
добавляет в `TradeInfo` optional `liquidation: FillLiquidation` и
`builderFee`. Это полезная подсказка для наших Rust parser fixtures: future
Hyperliquid fill parser должен принимать optional liquidation metadata. Но PR
открыт и не смержен, поэтому запрещено тянуть fork/branch как dependency в
production path. Схему можно использовать только как research evidence рядом с
official docs и raw fixtures.

Для воспроизведения schema reconnaissance без постоянного node runtime:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\probe-hyperliquid-node-data.ps1
```

Этот скрипт использует public processed mirror только как sample. Для
production/diagnostic collector нужен official S3 requester-pays sample или
bounded non-validating node output.

Для bounded Hyperliquid node-output probe используйте отдельный safety wrapper:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\probe-hyperliquid-node-output.ps1
```

Default mode is dry-run only. Он показывает planned command и обязательные
flags:

- `--write-fills`;
- `--write-misc-events`;
- `--batch-by-block`;
- `--stream-with-block-info`;
- `--disable-output-file-buffering`.

Для анализа уже полученного output:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\probe-hyperliquid-node-output.ps1 -ExistingDataPath <path-to-hl-data>
```

Для реального bounded run требуется явное `-Run` и explicit executable:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\probe-hyperliquid-node-output.ps1 -Run -NodeExecutable <hl-visor-or-runner> -MaxRuntimeSeconds 60 -MaxBytes 52428800
```

Wrapper пишет node output в isolated probe home, выставляя `HOME`/`USERPROFILE`
на `.cache/hyperliquid-node-output/home`, мониторит `max runtime` и `max bytes`,
останавливает процесс, считает `notional_usd`, `liquidation_id`/candidate ids,
dedup candidates, max notional и удаляет raw probe home unless `-KeepRaw`.
Без явного `-Run` он не запускает node.

Regression test:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\test-hyperliquid-node-output-probe.ps1
```

Перед любым реальным `-Run` выполните runner preflight:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\preflight-hyperliquid-node-runner.ps1 -MaxRuntimeSeconds 60 -MaxBytes 52428800
```

Preflight проверяет WSL/native runner, Ubuntu 24.04, dry-run probe, required
flags и isolated output path. Если `hl-visor` не найден, допустимый результат:
`status=not-ready-for-run`. Это blocker для реального bounded run, а не ошибка
скрипта. Regression test:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\test-hyperliquid-node-runner-preflight.ps1
```

Подробный runbook:
[hyperliquid-node-output-probe.md](hyperliquid-node-output-probe.md).

Связанная research note:
[hyperliquid-liquidation-feed-probe-2026-06-29.md](../research/hyperliquid-liquidation-feed-probe-2026-06-29.md).

Для overlap validation используйте read-only report:

```powershell
$env:DATABASE_URL="postgres://liquidation:liquidation@127.0.0.1:15433/liquidation"
cargo run -p liq-cli -- collector overlap-report --primary-source bybit --diagnostic-source okx --window-minutes 60 --bucket-seconds 60
```

Этот отчёт не дедуплицирует события между биржами. Bybit и OKX являются разными
venues, поэтому близкие по времени ликвидации считаются разными событиями.
Отчёт отвечает на другой вопрос: есть ли coverage/freshness/health у primary и
diagnostic source в одном окне.

Если OKX присылает liquidation payload по инструменту, которого нет в текущем
metadata cache, collector не должен падать. Такой payload сохраняется raw-only,
а canonical normalization остаётся выключенной до появления validated metadata
для этого instrument.

Для scheduled/manual diagnostics есть отдельный workflow
`.github/workflows/nightly-market-data.yml`. Локально тот же сценарий:

```powershell
$env:DATABASE_URL="postgres://liquidation:liquidation@127.0.0.1:15433/liquidation"
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\run-market-data-nightly-check.ps1 -RuntimeSeconds 30 -HealthIntervalSeconds 5 -WindowMinutes 60
```

Для сравнения нескольких nightly artifacts используйте history report:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\market-data-report-history.ps1 -InputRoot .cache\nightly-market-data -OutputPath .cache\nightly-market-data\trend.md -JsonOutputPath .cache\nightly-market-data\trend.json -MinRunsForSignal 3
```

Отчёт выводит `insufficient-history`, пока запусков меньше заданного минимума.
После накопления истории он классифицирует OKX как `useful-diagnostic`,
`healthy-but-sparse`, `unreliable-metadata` или `unreliable-source`. Это
по-прежнему не разрешает использовать OKX в сигналах автоматически.

Для сравнения полезности всех текущих sources используйте source usefulness
report:

```powershell
$env:DATABASE_URL="postgres://liquidation:liquidation@127.0.0.1:15433/liquidation"
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\source-usefulness-report.ps1 -WindowMinutes 120 -Json
```

Ключевое поле для новых diagnostic sources:
`liquidation_ready_buckets_without_primary`. Оно показывает buckets, где
diagnostic source видел canonical liquidation events, а current primary source
молчал. Это не полный replay proof, но честный signal-coverage proxy.

Для текущего решения "продолжаем без HTX" используйте wrapper:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\source-signal-readiness-report.ps1 -WindowMinutes 120 -Json
```

Wrapper анализирует только `bybit`, `binance`, `okx`, `bitget`, `gate` и
пишет `.cache/source-usefulness/signal-readiness.json`. Если
`signal_ready_windows_proxy > 0`, HTX остаётся deferred и следующий шаг -
controlled replay/entry fill/PnL, а не добавление ещё одного venue.

Подробности:
[source-usefulness-report.md](source-usefulness-report.md).

## Что улучшить или автоматизировать

- Поддерживать official docs/changelog watch через
  `scripts/check-api-docs-changelog.ps1` и nightly workflow. Warning из этого
  отчёта означает "нужен review адаптеров/fixtures", а не автоматическое
  включение источника в strategy signal.
- Добавить сравнение trend reports между GitHub artifacts разных дат.
