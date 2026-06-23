param(
    [string]$DatabaseUrl = $env:DATABASE_URL,
    [string]$ArtifactPath = ".cache/replay/latest-polymarket-baseline.json",
    [string]$FetchFixturePath,
    [switch]$FetchMetadataFirst
)

$ErrorActionPreference = "Stop"

if (-not $DatabaseUrl) {
    throw "DatabaseUrl or DATABASE_URL is required"
}

if ($FetchMetadataFirst) {
    $fetchScript = Join-Path $PSScriptRoot "fetch-polymarket-markets.ps1"
    $fetchArgs = @{
        DatabaseUrl = $DatabaseUrl
        Apply = $true
    }
    if ($FetchFixturePath) {
        $fetchArgs.FixturePath = $FetchFixturePath
    }
    & $fetchScript @fetchArgs
    if ($LASTEXITCODE -ne 0) {
        throw "fetch-polymarket-markets.ps1 failed with exit code $LASTEXITCODE"
    }
}

$args = @(
    "run", "-p", "liq-cli", "--",
    "replay", "run",
    "--database-url", $DatabaseUrl,
    "--strategy", "baseline",
    "--latest-polymarket-market",
    "--fill-model", "trade_cross",
    "--hedge-notional-usd", "15",
    "--hyperliquid-taker-bps", "5",
    "--hyperliquid-funding-bps-per-hour", "1",
    "--hedge-slippage-usd", "0.10",
    "--funding-hours", "1",
    "--artifact-path", $ArtifactPath,
    "--json"
)

& cargo @args
if ($LASTEXITCODE -ne 0) {
    throw "liq replay run failed with exit code $LASTEXITCODE"
}

if (-not (Test-Path -LiteralPath $ArtifactPath)) {
    throw "Expected replay artifact was not written: $ArtifactPath"
}
