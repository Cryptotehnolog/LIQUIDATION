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

`okx` намеренно не участвует в сигналах: OKX `liquidation-orders` WebSocket
дает raw liquidation details, но для безопасного `notional_usd` нужен
instrument metadata/contract value. До этого OKX используется только для
coverage, freshness и reliability diagnostics.

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

## Что улучшить или автоматизировать

- Добавить nightly official docs changelog check для Binance/Bybit/OKX.
- Добавить overlap validation report: Bybit primary vs OKX diagnostic window.
- Добавить instrument metadata cache для OKX, после чего разрешить canonical
  normalization только для проверенных instrument types.
