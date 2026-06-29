# Hyperliquid Node-Output Probe Runbook

Этот runbook описывает безопасный research-only путь проверки Hyperliquid
market-wide liquidation data через official node output. Это не production
collector и не замена текущему Hyperliquid hedge market-data leg.

Retrieval keywords: `preflight-hyperliquid-node-runner.ps1`, `Ubuntu 24.04`,
`hl-visor`, `not-ready-for-run`, `dry-run`, `MaxBytes`.

## Почему это не обычный WebSocket collector

Official Hyperliquid node docs говорят:

- non-validator node поддержан только на Ubuntu 24.04;
- machine specs для non-validator: 16 vCPU, 128 GB RAM, 500 GB SSD;
- gossip ports должны быть открыты публично для нормальной p2p работы;
- node пишет данные в `~/hl/data`;
- default output может генерировать около 100 GB logs/day.

Для нашей задачи нужны только liquidation-relevant outputs:

- `node_fills`, если fill содержит `liquidation`;
- `misc_events`, если ledger/event содержит liquidation data.

Поэтому разрешён только bounded research probe с лимитами времени и размера.

## Безопасная последовательность

1. Запустить preflight. Он ничего тяжёлого не запускает:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\preflight-hyperliquid-node-runner.ps1 -MaxRuntimeSeconds 60 -MaxBytes 52428800
```

Ожидаемый статус без установленного runner:

- `status=not-ready-for-run`;
- `dry_run.ok=true`;
- warning про missing `hl-visor`.

2. Проверить dry-run node-output wrapper:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\probe-hyperliquid-node-output.ps1 -MaxRuntimeSeconds 60 -MaxBytes 52428800
```

Dry-run должен показать planned command с флагами:

- `--write-fills`;
- `--write-misc-events`;
- `--batch-by-block`;
- `--stream-with-block-info`;
- `--disable-output-file-buffering`.

3. Реальный run разрешён только после verified runner path:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\probe-hyperliquid-node-output.ps1 -Run -NodeExecutable <hl-visor-or-runner> -MaxRuntimeSeconds 60 -MaxBytes 52428800 -KeepRaw
```

`-KeepRaw` нужен для первого raw output, чтобы затем сделать Rust parser
fixture. После fixture raw можно удалить.

## Что запрещено

- Запускать node без `MaxRuntimeSeconds` и `MaxBytes`.
- Включать raw book diffs, order statuses или default full output.
- Использовать user-specific `userEvents` как market-wide liquidation source.
- Нормализовать ordinary trades как liquidation events без explicit
  liquidation marker.
- Тянуть unmerged Hyperliquid Rust SDK PR как dependency.
- Запускать Docker compose/containers второго проекта для этого probe.

## Проверки

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\test-hyperliquid-node-output-probe.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\test-hyperliquid-node-runner-preflight.ps1
```

## После первого raw output

Следующий обязательный инкремент:

1. Добавить Rust fixture parser для `FillLiquidation` в `node_fills`.
2. Добавить Rust fixture parser для `Liquidation` в `misc_events`.
3. Добавить dedup policy test:
   - не суммировать две стороны одного liquidation fill дважды;
   - stable `source_event_id` строить из verified fields;
   - `notional_usd` считать только из explicit price/size или
     liquidation notional fields.
4. Только после parser tests обсуждать bounded collector/recorder path.

## Что улучшить или автоматизировать

- Добавить server-side runner profile, если ноутбук не подходит для p2p node.
- Добавить auto-redaction raw sample перед сохранением fixture.
- Добавить source usefulness report для Hyperliquid node output после появления
  первых verified canonical events.
