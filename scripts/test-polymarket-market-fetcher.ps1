$ErrorActionPreference = "Stop"

$fixture = "crates/liq-cli/tests/fixtures/polymarket_gamma_btc_5m.json"
$output = ".cache/polymarket/selected-markets.json"

if (Test-Path -LiteralPath $output) {
    Remove-Item -LiteralPath $output -Force
}

powershell -NoProfile -ExecutionPolicy Bypass -File scripts/fetch-polymarket-markets.ps1 `
    -FixturePath $fixture `
    -OutputPath $output `
    -Json

if (-not (Test-Path -LiteralPath $output)) {
    throw "Expected Polymarket fetch output was not written: $output"
}

$markets = Get-Content -Raw -LiteralPath $output | ConvertFrom-Json
if ($markets.Count -ne 1) {
    throw "Expected exactly one BTC 5-minute market from fixture, got $($markets.Count)"
}
if ($markets[0].market_id -ne "btc-5m-fixture") {
    throw "Unexpected selected market id: $($markets[0].market_id)"
}
if ($markets[0].up_token_id -ne "up-token" -or $markets[0].down_token_id -ne "down-token") {
    throw "Unexpected selected token ids"
}

Write-Output "polymarket market fetcher guard ok"
