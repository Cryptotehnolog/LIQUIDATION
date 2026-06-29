# Hyperliquid Node-Data Summary

Retrieval summary: Hyperliquid node-data remains `node_research_candidate`.
Official S3 anonymous listing returned `403`; official raw verification needs
AWS-authenticated requester-pays access or bounded node output. A processed
sample showed `notional_usd = price * size`, but `liquidation_id` can repeat
across both fill sides, so naive aggregation can double-count. Production
normalization requires dedup policy before canonical events.

Rust SDK note: Hyperliquid Rust SDK PR #175 is open and not merged. It adds
optional `liquidation: FillLiquidation` and `builder_fee` / `builderFee` to
`TradeInfo`, which corresponds to API `WsFill`. This is useful schema evidence
for Rust parser fixtures, but it is not a global public liquidation feed and
must not be used as a production dependency while unmerged.

Python SDK note: Hyperliquid Python SDK supports `userEvents` and
`userNonFundingLedgerUpdates` as user-specific paths. These can help a future
account-risk monitor, but they do not replace node-data research for market-wide
liquidation cascades.

Bounded node-output probe: use `scripts/probe-hyperliquid-node-output.ps1`.
Default mode is dry-run only. The script uses only fills/misc-events flags:
`--write-fills`, `--write-misc-events`, `--batch-by-block`,
`--stream-with-block-info`, `--disable-output-file-buffering`. It enforces
`MaxRuntimeSeconds`, `MaxBytes`, isolated probe home, auto-cleanup unless
`-KeepRaw`, and reports rows/files/bytes, liquidation markers,
`notional_usd`, `liquidation_id`/candidate ids, dedup candidates and max
notional. Test command:
`scripts/test-hyperliquid-node-output-probe.ps1`.
