$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent $PSScriptRoot
$FixtureRoot = Join-Path $RepoRoot ".cache\test-hyperliquid-node-output"
$DataRoot = Join-Path $FixtureRoot "data"
$ReportPath = Join-Path $FixtureRoot "report.json"

if (Test-Path -LiteralPath $FixtureRoot) {
    Remove-Item -LiteralPath $FixtureRoot -Recurse -Force
}

$fillsDir = Join-Path $DataRoot "node_fills\2026\06\29"
$miscDir = Join-Path $DataRoot "misc_events\2026\06\29"
New-Item -ItemType Directory -Force -Path $fillsDir | Out-Null
New-Item -ItemType Directory -Force -Path $miscDir | Out-Null

$fillBatch = [ordered]@{
    block_time = "2026-06-29T00:00:00Z"
    block_number = 123
    events = @(
        [ordered]@{
            coin = "BTC"
            px = "60000"
            sz = "0.5"
            hash = "0xfill"
            tid = 42
            liquidation = [ordered]@{
                liquidatedUser = "0xliquidated"
                markPx = "60010"
                method = "market"
            }
            builderFee = "0.01"
        }
    )
}

$miscEvent = [ordered]@{
    block_time = "2026-06-29T00:00:01Z"
    block_number = 124
    hash = "0xmisc"
    inner = [ordered]@{
        delta = [ordered]@{
            liquidation = [ordered]@{
                liquidatedNtlPos = "12345.67"
                accountValue = "1000"
                leverageType = "cross"
                liquidatedPositions = @(
                    [ordered]@{
                        coin = "BTC"
                        szi = "-0.2"
                    }
                )
            }
        }
    }
}

($fillBatch | ConvertTo-Json -Depth 20 -Compress) |
    Set-Content -LiteralPath (Join-Path $fillsDir "fills.jsonl") -Encoding UTF8
($miscEvent | ConvertTo-Json -Depth 20 -Compress) |
    Set-Content -LiteralPath (Join-Path $miscDir "misc.jsonl") -Encoding UTF8

$output = & (Join-Path $PSScriptRoot "probe-hyperliquid-node-output.ps1") `
    -ExistingDataPath $DataRoot `
    -JsonOutputPath $ReportPath

$report = Get-Content -Raw -LiteralPath $ReportPath | ConvertFrom-Json
$analysis = $report.analysis

if ($report.mode -ne "analyze-existing") {
    throw "Expected analyze-existing mode, got $($report.mode)"
}
if ($analysis.file_count -ne 2) {
    throw "Expected 2 files, got $($analysis.file_count)"
}
if ($analysis.fill_liquidation_records -ne 1) {
    throw "Expected 1 fill liquidation record, got $($analysis.fill_liquidation_records)"
}
if ($analysis.misc_liquidation_records -ne 1) {
    throw "Expected 1 misc liquidation record, got $($analysis.misc_liquidation_records)"
}
if ($analysis.notional_candidates -ne 2) {
    throw "Expected 2 notional candidates, got $($analysis.notional_candidates)"
}
if ([math]::Abs([double]$analysis.max_notional_usd - 30000.0) -gt 0.000001) {
    throw "Expected max_notional_usd 30000, got $($analysis.max_notional_usd)"
}
if ($analysis.unique_liquidation_candidate_ids -ne 2) {
    throw "Expected 2 unique candidate ids, got $($analysis.unique_liquidation_candidate_ids)"
}

Write-Output "hyperliquid node-output probe test passed"
