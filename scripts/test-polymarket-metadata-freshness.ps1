$ErrorActionPreference = "Stop"

$fixture = "tests/fixtures/dashboard/latest-polymarket-market.json"
$freshnessScript = Join-Path $PSScriptRoot "check-polymarket-metadata-freshness.ps1"
$json = & $freshnessScript `
    -MarketArtifactPath $fixture `
    -StaleAfterMinutes 15 `
    -Json

$result = $json | ConvertFrom-Json
if ($result.status -ne "stale") {
    throw "Expected stale fixture metadata, got status=$($result.status)"
}
if ($result.market_id -ne "btc-5m-fixture") {
    throw "Unexpected market id: $($result.market_id)"
}
if (-not $result.warning) {
    throw "Expected stale metadata warning"
}

Write-Output "polymarket metadata freshness guard ok"
