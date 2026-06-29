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
- `polymarket`: `source_quality=websocket_only`,
  `coverage_role=market_data_leg`, `participates_in_signals=false`.
- `hyperliquid`: `source_quality=websocket_only`,
  `coverage_role=hedge_market_data`, `participates_in_signals=false`.

## Приоритет расширения liquidation sources

Решение от 2026-06-29:

1. `hyperliquid_liquidations`: сначала `research/probe`, не включать в сигналы
   и не смешивать с текущим hedge market-data leg.
2. `bitget`: следующий diagnostic liquidation source.
3. `gate`: следующий diagnostic liquidation source после Bitget.
4. `htx`: research candidate после Hyperliquid, Bitget и Gate.

Причина: по наблюдениям через Coinglass, когда Binance/Bybit/OKX молчат,
больше всего событий может давать Hyperliquid, затем Bitget, Gate и HTX. Это
операционный сигнал, но не доказательство. Каждый источник проходит official
docs review, fixture tests, bounded live probe и source usefulness report.

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

## Что улучшить или автоматизировать

- Поддерживать official docs/changelog watch через
  `scripts/check-api-docs-changelog.ps1` и nightly workflow. Warning из этого
  отчёта означает "нужен review адаптеров/fixtures", а не автоматическое
  включение источника в strategy signal.
- Добавить сравнение trend reports между GitHub artifacts разных дат.
