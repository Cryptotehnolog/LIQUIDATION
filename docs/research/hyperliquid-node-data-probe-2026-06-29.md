# Hyperliquid Node-Data Research Probe

Дата проверки: 2026-06-29.

## Цель

Проверить без постоянного Hyperliquid node runtime:

- можно ли получить маленький liquidation sample;
- какие поля доступны;
- можно ли честно считать `notional_usd`;
- какой следующий safe path для `hyperliquid_liquidations`.

Retrieval summary: Hyperliquid node-data probe found a processed sample where
`notional_usd = price * size`; `liquidation_id` can repeat across both sides, so
naive row summing can double-count; official S3 needs requester-pays access.

## Источники

Official sources:

- Hyperliquid historical data: `s3://hl-mainnet-node-data/node_fills_by_block`
  указан в official historical data docs.
- Hyperliquid node docs: L1 output может включать `node_fills` и `misc_events`.
- `misc_events` содержит `LedgerDelta = Liquidation`.
- Fill schema может содержать `FillLiquidation`.
- Official Python SDK:
  https://github.com/hyperliquid-dex/hyperliquid-python-sdk

Практическое ограничение: direct anonymous HTTPS listing
`https://hl-mainnet-node-data.s3.amazonaws.com/?list-type=2...` вернул `403`.
Header `x-amz-request-payer=requester` без AWS authentication также вернул
`403`. Для official S3 sample нужен AWS-authenticated requester-pays доступ или
заранее известный object key.

Для schema reconnaissance использован public processed mirror:

- HuggingFace dataset `Chainticks/perp-data`;
- file:
  `hyperliquid_chain/liquidations/date=2026-05-12/part-0000.parquet`;
- локальный ignored путь:
  `.cache/hyperliquid-node-data/hyperliquid-liquidations-2026-05-12.parquet`.

Этот mirror не является production source. Он годится только для research
schema probe.

## Python SDK review

`hyperliquid-dex/hyperliquid-python-sdk` полезен как reference для supported
WebSocket subscriptions и user-specific API methods, но не как market-wide
liquidation feed.

Observed SDK facts:

- `utils/types.py` содержит `UserEventsSubscription`:
  `{"type": "userEvents", "user": str}`.
- `utils/types.py` содержит `UserNonFundingLedgerUpdatesSubscription`:
  `{"type": "userNonFundingLedgerUpdates", "user": str}`.
- `info.py` имеет method для `userNonFundingLedgerUpdates`, который возвращает
  deposits, withdrawals, transfers, liquidations and other account activities
  excluding funding payments, but for one user.
- `websocket_manager.py` routes `userEvents` and
  `userNonFundingLedgerUpdates` by user-specific identifiers.
- SDK scan did not reveal a global `liquidations` subscription.

Conclusion: SDK helps future Hyperliquid account-risk monitor, but it does not
replace node-data research for market-wide liquidation cascades.

## Sample stats

Файл:

- размер: `2,102,489` bytes;
- rows: `26,236`;
- unique `liquidation_id`: `1,779`;
- max rows per liquidation id: `900`;
- source_kind: `hypercore_s3`;
- time range: `2026-05-12T00:12:08.310000+00:00` -
  `2026-05-12T23:59:26.191000+00:00`.

Top symbols:

- `BTC`: `3,014` rows;
- `ETH`: `1,370` rows;
- `HYPE`: `1,248` rows;
- `FARTCOIN`: `1,136` rows;
- `SOL`: `974` rows.

Liquidation methods:

- `market`: `26,222` rows;
- `backstop`: `14` rows.

All rows in the sample had a `raw_json.event.liquidation` marker.

## Observed schema

Processed parquet columns:

- `provider`;
- `symbol`;
- `recorded_at`;
- `schema_version`;
- `source_kind`;
- `exchange_time`;
- `liquidation_id`;
- `side`;
- `price`;
- `size`;
- `notional_usd`;
- `block_number`;
- `raw_json`.

Probe finding for retrieval: `notional_usd` matches `price * size`, but
`liquidation_id` can repeat, so naive aggregation can double-count; official
raw verification still needs requester-pays S3 access.

Inside `raw_json.event.liquidation`:

- `liquidatedUser`;
- `markPx`;
- `method`: `market` or `backstop`.

Useful raw fields:

- `event.hash`;
- `event.coin`;
- `event.side`;
- `event.px`;
- `event.sz`;
- `event.time`;
- `event.tid`;
- `event.dir`;
- `event.startPosition`;
- `block.block_number`;
- `block.block_time`.

## Can notional_usd be computed honestly?

Yes for fill rows that contain `px` and `sz`:

```text
notional_usd = price * size
```

Observed max absolute difference between parquet `notional_usd` and
`price * size`: `3E-11`, which is floating-point formatting noise.

Important caveat: do not aggregate naively by rows. The same
`liquidation_id` can appear in multiple rows, including both sides of the fill.
For source usefulness and cascade pressure we need a policy:

- either use only the row where `event.user == event.liquidation.liquidatedUser`;
- or group by `(liquidation_id, liquidatedUser, coin, tid)` and deduplicate;
- never sum both maker and liquidated-user legs as separate liquidation notional.

## Conclusion

`hyperliquid_liquidations` should stay `node_research_candidate`, but it is now
a credible candidate.

Do not implement a production collector yet. Next work should be:

1. Get an official S3 requester-pays sample or bounded non-validating node
   output.
2. Build fixtures from official raw `node_fills` and/or `misc_events`.
3. Add parser tests for `FillLiquidation` and `LedgerDelta = Liquidation`.
4. Define deduplication and notional policy.
5. Only then add a diagnostic-only collector path.

## Reproduce probe

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\probe-hyperliquid-node-data.ps1
```

The script writes ignored output under `.cache/hyperliquid-node-data/`.

## What to improve or automate

- Add AWS requester-pays official sample support.
- Add a tiny bounded node-output mode with hard caps:
  - enabled outputs only: fills/misc events;
  - max runtime;
  - max bytes;
  - local retention cleanup.
- Add a future normalizer fixture once an official raw sample is available.
