param(
    [string]$DatabaseUrl = $env:DATABASE_URL,
    [string]$MarketArtifactPath = ".cache/replay/latest-polymarket-market.json",
    [string]$OkxInstrumentsPath = ".cache/okx/instruments-BTC-USDT-SWAP.json",
    [int]$MaxRuntimeSeconds = 330,
    [int]$MinFreshSeconds = 120,
    [int]$MaxWaitForFreshWindowSeconds = 360,
    [int]$PostWindowGraceSeconds = 10,
    [switch]$SkipFetch,
    [switch]$RunReplay
)

$ErrorActionPreference = "Stop"

$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$MarketArtifactFullPath = Join-Path $RepoRoot $MarketArtifactPath
$OkxInstrumentsFullPath = Join-Path $RepoRoot $OkxInstrumentsPath

if (-not $DatabaseUrl) {
    throw "DatabaseUrl or DATABASE_URL is required"
}

function Invoke-MarketFetch {
    $fetchScript = Join-Path $PSScriptRoot "fetch-polymarket-markets.ps1"
    & powershell -NoProfile -ExecutionPolicy Bypass -File $fetchScript `
        -DatabaseUrl $DatabaseUrl `
        -OutputPath $MarketArtifactFullPath `
        -Apply | Out-Host
    if ($LASTEXITCODE -ne 0) {
        throw "fetch-polymarket-markets.ps1 failed with exit code $LASTEXITCODE"
    }
}

function Read-LatestMarket {
    if (-not (Test-Path $MarketArtifactFullPath)) {
        throw "Polymarket market artifact not found: $MarketArtifactFullPath"
    }

    $markets = Get-Content -Raw -Path $MarketArtifactFullPath | ConvertFrom-Json
    if (-not $markets -or $markets.Count -lt 1) {
        throw "Polymarket market artifact is empty: $MarketArtifactFullPath"
    }

    $market = @($markets)[0]
    if (-not $market.up_token_id -or -not $market.down_token_id -or -not $market.end_ts) {
        throw "Polymarket market artifact is missing up_token_id/down_token_id/end_ts"
    }
    $market
}

$waitStartedUtc = [DateTime]::UtcNow
while ($true) {
    if (-not $SkipFetch) {
        Invoke-MarketFetch
    }

    $market = Read-LatestMarket
    $endUtc = ([DateTimeOffset]::Parse($market.end_ts)).UtcDateTime
    $nowUtc = [DateTime]::UtcNow
    $secondsRemaining = [int][Math]::Ceiling(($endUtc - $nowUtc).TotalSeconds) + $PostWindowGraceSeconds
    $requiredFreshSeconds = [Math]::Min($MaxRuntimeSeconds, $MinFreshSeconds)
    if ($secondsRemaining -ge $requiredFreshSeconds) {
        break
    }
    if ($SkipFetch) {
        throw "Latest Polymarket market is too close to done or already stale; rerun without -SkipFetch"
    }
    $waitedSeconds = ([DateTime]::UtcNow - $waitStartedUtc).TotalSeconds
    if ($waitedSeconds -ge $MaxWaitForFreshWindowSeconds) {
        throw "Timed out waiting for a fresh Polymarket 5-minute window"
    }

    $sleepSeconds = [Math]::Min(30, [Math]::Max(5, $secondsRemaining))
    Write-Output "Latest Polymarket market has only $secondsRemaining seconds left; waiting $sleepSeconds seconds for a fresher window..."
    Start-Sleep -Seconds $sleepSeconds
}

$runtimeSeconds = [Math]::Min($MaxRuntimeSeconds, $secondsRemaining)
Write-Output "Collecting paper replay window market_id=$($market.market_id) $($market.start_ts)..$($market.end_ts) runtime_seconds=$runtimeSeconds"

if (-not (Test-Path $OkxInstrumentsFullPath)) {
    $okxFetchScript = Join-Path $PSScriptRoot "fetch-okx-instruments.ps1"
    & powershell -NoProfile -ExecutionPolicy Bypass -File $okxFetchScript `
        -Symbol "BTC-USDT-SWAP" `
        -OutputPath $OkxInstrumentsFullPath | Out-Host
    if ($LASTEXITCODE -ne 0) {
        throw "fetch-okx-instruments.ps1 failed with exit code $LASTEXITCODE"
    }
}

function Start-LiqCollectorJob {
    param(
        [string]$Name,
        [string[]]$CollectorArgs
    )

    Start-Job -Name $Name -ScriptBlock {
        param($RepoRoot, $CollectorArgs)
        Set-Location $RepoRoot
        & cargo @CollectorArgs
        if ($LASTEXITCODE -ne 0) {
            throw "collector job failed with exit code $LASTEXITCODE"
        }
    } -ArgumentList $RepoRoot, $CollectorArgs
}

$jobs = @()
$jobs += Start-LiqCollectorJob -Name "liquidations" -CollectorArgs @(
    "run", "-p", "liq-cli", "--",
    "collector", "run",
    "--database-url", $DatabaseUrl,
    "--source", "bybit",
    "--source", "binance",
    "--symbol", "BTCUSDT",
    "--max-runtime-seconds", [string]$runtimeSeconds,
    "--read-timeout-seconds", "20",
    "--health-interval-seconds", "15"
)
$jobs += Start-LiqCollectorJob -Name "okx-liquidations" -CollectorArgs @(
    "run", "-p", "liq-cli", "--",
    "collector", "run",
    "--database-url", $DatabaseUrl,
    "--source", "okx",
    "--symbol", "BTC-USDT-SWAP",
    "--okx-instruments-path", $OkxInstrumentsFullPath,
    "--max-runtime-seconds", [string]$runtimeSeconds,
    "--read-timeout-seconds", "20",
    "--health-interval-seconds", "15"
)
$jobs += Start-LiqCollectorJob -Name "polymarket-up" -CollectorArgs @(
    "run", "-p", "liq-cli", "--",
    "collector", "run",
    "--database-url", $DatabaseUrl,
    "--source", "polymarket",
    "--symbol", [string]$market.up_token_id,
    "--max-runtime-seconds", [string]$runtimeSeconds,
    "--read-timeout-seconds", "20",
    "--health-interval-seconds", "15"
)
$jobs += Start-LiqCollectorJob -Name "polymarket-down" -CollectorArgs @(
    "run", "-p", "liq-cli", "--",
    "collector", "run",
    "--database-url", $DatabaseUrl,
    "--source", "polymarket",
    "--symbol", [string]$market.down_token_id,
    "--max-runtime-seconds", [string]$runtimeSeconds,
    "--read-timeout-seconds", "20",
    "--health-interval-seconds", "15"
)
$jobs += Start-LiqCollectorJob -Name "hyperliquid" -CollectorArgs @(
    "run", "-p", "liq-cli", "--",
    "collector", "run",
    "--database-url", $DatabaseUrl,
    "--source", "hyperliquid",
    "--symbol", "BTC",
    "--max-runtime-seconds", [string]$runtimeSeconds,
    "--read-timeout-seconds", "20",
    "--health-interval-seconds", "15"
)

try {
    Wait-Job -Job $jobs | Out-Null
    foreach ($job in $jobs) {
        Write-Output "=== collector job: $($job.Name) ==="
        Receive-Job -Job $job -ErrorAction SilentlyContinue | Out-Host
        if ($job.State -ne "Completed") {
            throw "collector job $($job.Name) ended with state $($job.State)"
        }
    }
}
finally {
    Remove-Job -Job $jobs -Force -ErrorAction SilentlyContinue
}

Write-Output "Running paper replay preflight..."
& cargo run -p liq-cli -- replay preflight `
    --database-url $DatabaseUrl `
    --strategy baseline `
    --latest-polymarket-market `
    --fill-model trade_cross `
    --hedge-notional-usd 15 `
    --hyperliquid-taker-bps 5 `
    --hyperliquid-funding-bps-per-hour 1 `
    --hedge-slippage-usd 0.10 `
    --funding-hours 1 `
    --market-stale-after-minutes 15 `
    --json
$preflightExit = $LASTEXITCODE

if ($RunReplay -and $preflightExit -eq 0) {
    $replayScript = Join-Path $PSScriptRoot "run-latest-polymarket-replay.ps1"
    & powershell -NoProfile -ExecutionPolicy Bypass -File $replayScript `
        -DatabaseUrl $DatabaseUrl `
        -ArtifactPath ".cache/replay/latest-polymarket-baseline.json" `
        -MarketArtifactPath $MarketArtifactPath `
        -SkipFetch
    exit $LASTEXITCODE
}

exit $preflightExit
