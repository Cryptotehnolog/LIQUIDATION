$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $PSScriptRoot "check-websocket-endpoint-contracts.ps1"
$tempDir = Join-Path ([IO.Path]::GetTempPath()) ("liq-ws-endpoint-contracts-test-" + [guid]::NewGuid().ToString("N"))

function Assert-True {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

try {
    $fixtureDir = Join-Path $tempDir "fixtures"
    $outputDir = Join-Path $tempDir "out"
    New-Item -ItemType Directory -Force -Path $fixtureDir *> $null

    @"
Important WebSocket Change Notice
Market (regular market data): wss://fstream.binance.com/market
Liquidations: <symbol>@forceOrder
URL PATH /market
"@ | Set-Content -LiteralPath (Join-Path $fixtureDir "binance-websocket-change-notice.html") -Encoding UTF8

    @"
All Liquidation
Topic: allLiquidation.{symbol}
wss://stream.bybit.com/v5/public/linear
"@ | Set-Content -LiteralPath (Join-Path $fixtureDir "bybit-all-liquidation.html") -Encoding UTF8

    @"
Liquidation orders channel
wss://ws.okx.com:8443/ws/v5/public
liquidation-orders
"@ | Set-Content -LiteralPath (Join-Path $fixtureDir "okx-liquidation-orders.html") -Encoding UTF8

    @"
Bitget UTA Liquidation Channel
wss://ws.bitget.com/v3/ws/public
topic liquidation
"@ | Set-Content -LiteralPath (Join-Path $fixtureDir "bitget-liquidation-channel.html") -Encoding UTF8

    $result = & $scriptPath -FixtureDir $fixtureDir -OutputDir $outputDir
    $json = $result | ConvertFrom-Json

    Assert-True ($json.status -eq "ok") "expected endpoint contract status ok, got $($json.status)"
    Assert-True (($json.contracts | Where-Object { $_.name -eq "binance_force_order" }).code_ok) "expected Binance code contract to pass"
    Assert-True (($json.contracts | Where-Object { $_.name -eq "binance_force_order" }).docs_ok) "expected Binance docs contract to pass"
    Assert-True (($json.contracts | Where-Object { $_.name -eq "bitget_uta_liquidation" }).code_ok) "expected Bitget code contract to pass"
    Assert-True (($json.contracts | Where-Object { $_.name -eq "bitget_uta_liquidation" }).docs_ok) "expected Bitget docs contract to pass"

    foreach ($path in @("websocket-endpoint-contracts.json", "websocket-endpoint-contracts.md")) {
        Assert-True (Test-Path -LiteralPath (Join-Path $outputDir $path)) "expected $path to be written"
    }

    Write-Host "websocket endpoint contracts test ok"
} finally {
    if (Test-Path -LiteralPath $tempDir) {
        Remove-Item -LiteralPath $tempDir -Recurse -Force
    }
}
