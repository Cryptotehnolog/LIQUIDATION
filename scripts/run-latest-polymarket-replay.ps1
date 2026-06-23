param(
    [string]$DatabaseUrl = $env:DATABASE_URL,
    [string]$ArtifactPath = ".cache/replay/latest-polymarket-baseline.json",
    [string]$MarketArtifactPath = ".cache/replay/latest-polymarket-market.json",
    [int]$MarketStaleAfterMinutes = 15,
    [string]$FetchFixturePath,
    [switch]$FetchMetadataFirst,
    [switch]$SkipFetch
)

$ErrorActionPreference = "Stop"

if (-not $DatabaseUrl) {
    throw "DatabaseUrl or DATABASE_URL is required"
}

if ($FetchMetadataFirst -and -not $SkipFetch) {
    $fetchScript = Join-Path $PSScriptRoot "fetch-polymarket-markets.ps1"
    $fetchArgs = @{
        DatabaseUrl = $DatabaseUrl
        Apply = $true
        OutputPath = $MarketArtifactPath
    }
    if ($FetchFixturePath) {
        $fetchArgs.FixturePath = $FetchFixturePath
    }
    & $fetchScript @fetchArgs
    if ($LASTEXITCODE -ne 0) {
        throw "fetch-polymarket-markets.ps1 failed with exit code $LASTEXITCODE"
    }
}

if (Test-Path -LiteralPath $ArtifactPath) {
    Remove-Item -LiteralPath $ArtifactPath -Force
}

if (Test-Path -LiteralPath $MarketArtifactPath) {
    $freshnessScript = Join-Path $PSScriptRoot "check-polymarket-metadata-freshness.ps1"
    & $freshnessScript -MarketArtifactPath $MarketArtifactPath -StaleAfterMinutes $MarketStaleAfterMinutes
    if ($LASTEXITCODE -ne 0) {
        throw "check-polymarket-metadata-freshness.ps1 failed with exit code $LASTEXITCODE"
    }
} else {
    Write-Warning "Polymarket market artifact does not exist before replay: $MarketArtifactPath"
}

$args = @(
    "run", "-p", "liq-cli", "--",
    "replay", "preflight",
    "--database-url", $DatabaseUrl,
    "--strategy", "baseline",
    "--latest-polymarket-market",
    "--fill-model", "trade_cross",
    "--hedge-notional-usd", "15",
    "--hyperliquid-taker-bps", "5",
    "--hyperliquid-funding-bps-per-hour", "1",
    "--hedge-slippage-usd", "0.10",
    "--funding-hours", "1",
    "--market-stale-after-minutes", [string]$MarketStaleAfterMinutes,
    "--json"
)

& cargo @args
if ($LASTEXITCODE -ne 0) {
    throw "liq replay preflight failed with exit code $LASTEXITCODE"
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
    "--market-stale-after-minutes", [string]$MarketStaleAfterMinutes,
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
