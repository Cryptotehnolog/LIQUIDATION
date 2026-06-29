param(
    [string]$OutputDir = ".cache/hyperliquid-node-data",
    [string]$ParquetUrl = "https://huggingface.co/datasets/Chainticks/perp-data/resolve/main/hyperliquid_chain/liquidations/date%3D2026-05-12/part-0000.parquet",
    [string]$ParquetPath = "",
    [string]$JsonOutputPath = ""
)

$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent $PSScriptRoot
$OutputFullPath = [System.IO.Path]::GetFullPath((Join-Path $RepoRoot $OutputDir))
New-Item -ItemType Directory -Force -Path $OutputFullPath | Out-Null

if ([string]::IsNullOrWhiteSpace($ParquetPath)) {
    $ParquetPath = Join-Path $OutputFullPath "hyperliquid-liquidations-sample.parquet"
} elseif (-not [System.IO.Path]::IsPathRooted($ParquetPath)) {
    $ParquetPath = Join-Path $RepoRoot $ParquetPath
}

$ParquetFullPath = [System.IO.Path]::GetFullPath($ParquetPath)

if ([string]::IsNullOrWhiteSpace($JsonOutputPath)) {
    $JsonOutputPath = Join-Path $OutputFullPath "hyperliquid-node-data-probe.json"
} elseif (-not [System.IO.Path]::IsPathRooted($JsonOutputPath)) {
    $JsonOutputPath = Join-Path $RepoRoot $JsonOutputPath
}

$JsonFullPath = [System.IO.Path]::GetFullPath($JsonOutputPath)

if (-not (Get-Command uv -ErrorAction SilentlyContinue)) {
    throw "uv is required for temporary pyarrow execution. Install uv or pass an already inspected JSON report."
}

if (-not (Test-Path $ParquetFullPath)) {
    Write-Output "Downloading Hyperliquid node-data sample to $ParquetFullPath"
    Invoke-WebRequest -Uri $ParquetUrl -OutFile $ParquetFullPath -TimeoutSec 180
}

$python = @'
import json
import os
from collections import Counter, defaultdict
from decimal import Decimal
from pathlib import Path

import pyarrow.parquet as pq

path = Path(os.environ["HL_PARQUET_PATH"])
table = pq.read_table(path)
rows = table.to_pylist()

symbols = Counter()
sides = Counter()
source_kinds = Counter()
methods = Counter()
unique_ids = set()
rows_by_id = defaultdict(int)
missing_liquidation_marker = 0
max_price_times_size_diff = Decimal("0")

for row in rows:
    symbols[row["symbol"]] += 1
    sides[row["side"]] += 1
    source_kinds[row["source_kind"]] += 1
    unique_ids.add(row["liquidation_id"])
    rows_by_id[row["liquidation_id"]] += 1

    raw = json.loads(row["raw_json"])
    liquidation = raw.get("event", {}).get("liquidation")
    if liquidation is None:
        missing_liquidation_marker += 1
    else:
        methods[liquidation.get("method", "unknown")] += 1

    computed = Decimal(str(row["price"])) * Decimal(str(row["size"]))
    diff = abs(computed - Decimal(str(row["notional_usd"])))
    if diff > max_price_times_size_diff:
        max_price_times_size_diff = diff

largest = sorted(rows, key=lambda item: item.get("notional_usd") or 0, reverse=True)[:10]
btc_rows = [row for row in rows if str(row["symbol"]).upper() == "BTC"]

summary = {
    "source": "public processed sample; not authoritative production source",
    "input_path": str(path),
    "file_size_bytes": path.stat().st_size,
    "schema": [(field.name, str(field.type)) for field in table.schema],
    "rows": len(rows),
    "unique_liquidation_ids": len(unique_ids),
    "max_rows_per_liquidation_id": max(rows_by_id.values()) if rows_by_id else 0,
    "source_kinds": dict(source_kinds),
    "top_symbols": symbols.most_common(15),
    "sides": dict(sides),
    "methods": dict(methods),
    "missing_liquidation_marker_rows": missing_liquidation_marker,
    "max_notional_usd": max((row["notional_usd"] for row in rows), default=0),
    "min_exchange_time": min((row["exchange_time"] for row in rows), default=None),
    "max_exchange_time": max((row["exchange_time"] for row in rows), default=None),
    "max_price_times_size_diff": str(max_price_times_size_diff),
    "btc_rows": len(btc_rows),
    "largest_rows": [
        {
            key: row[key]
            for key in [
                "symbol",
                "exchange_time",
                "liquidation_id",
                "side",
                "price",
                "size",
                "notional_usd",
                "block_number",
            ]
        }
        for row in largest
    ],
}

print(json.dumps(summary, ensure_ascii=False, indent=2, default=str))
'@

$env:HL_PARQUET_PATH = $ParquetFullPath
$json = $python | uv run --with pyarrow python -
$json | Set-Content -Path $JsonFullPath -Encoding UTF8

Write-Output $json
Write-Output "Probe report written to $JsonFullPath"
