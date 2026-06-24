param(
    [string]$DatabaseUrl = $env:DATABASE_URL,
    [string]$ArtifactPath = ".cache/replay/latest-polymarket-baseline.json",
    [string]$MarketArtifactPath = ".cache/replay/latest-polymarket-market.json",
    [int]$MarketStaleAfterMinutes = 15,
    [string]$ReplayProfile = "baseline",
    [decimal]$LiquidationThresholdMinUsd = -1,
    [decimal]$LiquidationThresholdMaxUsd = -1,
    [decimal]$PullbackPct = -1,
    [decimal]$PolymarketUsdPerPosition = -1,
    [int]$OrderCancelWindowSeconds = -1,
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

$strategyArgs = @("--replay-profile", $ReplayProfile)
if ($LiquidationThresholdMinUsd -ge 0) {
    $strategyArgs += @("--liquidation-threshold-min-usd", [string]$LiquidationThresholdMinUsd)
}
if ($LiquidationThresholdMaxUsd -ge 0) {
    $strategyArgs += @("--liquidation-threshold-max-usd", [string]$LiquidationThresholdMaxUsd)
}
if ($PullbackPct -ge 0) {
    $strategyArgs += @("--pullback-pct", [string]$PullbackPct)
}
if ($PolymarketUsdPerPosition -ge 0) {
    $strategyArgs += @("--polymarket-usd-per-position", [string]$PolymarketUsdPerPosition)
}
if ($OrderCancelWindowSeconds -ge 0) {
    $strategyArgs += @("--order-cancel-window-seconds", [string]$OrderCancelWindowSeconds)
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
$args += $strategyArgs

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
$args += $strategyArgs

& cargo @args
if ($LASTEXITCODE -ne 0) {
    throw "liq replay run failed with exit code $LASTEXITCODE"
}

if (-not (Test-Path -LiteralPath $ArtifactPath)) {
    throw "Expected replay artifact was not written: $ArtifactPath"
}
