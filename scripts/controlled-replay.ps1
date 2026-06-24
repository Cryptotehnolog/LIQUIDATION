param(
    [string]$DatabaseUrl = $env:DATABASE_URL,
    [string]$MarketArtifactPath = ".cache/replay/latest-polymarket-market.json",
    [string]$ReplayArtifactPath = ".cache/replay/latest-polymarket-baseline.json",
    [string]$OkxInstrumentsPath = ".cache/okx/instruments-BTC-USDT-SWAP.json",
    [int]$MaxWindows = 6,
    [int]$MaxRuntimeSeconds = 330,
    [int]$MinFreshSeconds = 120,
    [int]$MaxWaitForFreshWindowSeconds = 360,
    [int]$PostWindowGraceSeconds = 10,
    [int]$DelayBetweenWindowsSeconds = 5,
    [int]$DashboardPort = 18080,
    [string]$DashboardBindHost = "127.0.0.1",
    [int]$DashboardWindowMinutes = 60,
    [int]$DashboardPollSeconds = 5,
    [int]$PolymarketMarketStaleAfterMinutes = 15,
    [string]$ReplayProfile = "baseline",
    [decimal]$LiquidationThresholdMinUsd = -1,
    [decimal]$LiquidationThresholdMaxUsd = -1,
    [decimal]$PullbackPct = -1,
    [decimal]$PolymarketUsdPerPosition = -1,
    [int]$OrderCancelWindowSeconds = -1,
    [switch]$UntilEntryFilled,
    [int]$MaxReplayAttempts = 6,
    [int]$DelayBetweenReplayAttemptsSeconds = 5,
    [string]$AggregateReportPath = ".cache/replay/controlled-replay-aggregate.json",
    [switch]$SkipDashboard,
    [switch]$NoOpenBrowser,
    [switch]$PrintCommandsOnly
)

$ErrorActionPreference = "Stop"

$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$WaitScript = Join-Path $PSScriptRoot "wait-for-liquidation-replay.ps1"
$DashboardScript = Join-Path $PSScriptRoot "start-dashboard.ps1"
$ReplayArtifactFullPath = Join-Path $RepoRoot $ReplayArtifactPath
$MarketArtifactFullPath = Join-Path $RepoRoot $MarketArtifactPath
$AggregateReportFullPath = Join-Path $RepoRoot $AggregateReportPath

if (-not $DatabaseUrl) {
    throw "DatabaseUrl or DATABASE_URL is required"
}
if ($MaxWindows -lt 1) {
    throw "MaxWindows must be at least 1"
}
if ($MaxRuntimeSeconds -lt 30) {
    throw "MaxRuntimeSeconds must be at least 30"
}
if ($MaxReplayAttempts -lt 1) {
    throw "MaxReplayAttempts must be at least 1"
}
if ($DelayBetweenReplayAttemptsSeconds -lt 0) {
    throw "DelayBetweenReplayAttemptsSeconds must be non-negative"
}

function Resolve-ReplayParameters {
    switch ($ReplayProfile) {
        "baseline" {
            $resolved = [ordered]@{
                LiquidationThresholdMinUsd = [decimal]25000
                LiquidationThresholdMaxUsd = [decimal]100000
                PullbackPct = [decimal]0.30
                PolymarketUsdPerPosition = [decimal]15
                OrderCancelWindowSeconds = 60
            }
        }
        "research-wide-threshold" {
            $resolved = [ordered]@{
                LiquidationThresholdMinUsd = [decimal]25000
                LiquidationThresholdMaxUsd = [decimal]1000000
                PullbackPct = [decimal]0.30
                PolymarketUsdPerPosition = [decimal]15
                OrderCancelWindowSeconds = 60
            }
        }
        default {
            throw "Unsupported ReplayProfile '$ReplayProfile'; supported: baseline, research-wide-threshold"
        }
    }

    if ($LiquidationThresholdMinUsd -ge 0) { $resolved.LiquidationThresholdMinUsd = $LiquidationThresholdMinUsd }
    if ($LiquidationThresholdMaxUsd -ge 0) { $resolved.LiquidationThresholdMaxUsd = $LiquidationThresholdMaxUsd }
    if ($PullbackPct -ge 0) { $resolved.PullbackPct = $PullbackPct }
    if ($PolymarketUsdPerPosition -ge 0) { $resolved.PolymarketUsdPerPosition = $PolymarketUsdPerPosition }
    if ($OrderCancelWindowSeconds -ge 0) { $resolved.OrderCancelWindowSeconds = $OrderCancelWindowSeconds }

    if ($resolved.LiquidationThresholdMinUsd -le 0) {
        throw "LiquidationThresholdMinUsd must be greater than zero"
    }
    if ($resolved.LiquidationThresholdMaxUsd -lt $resolved.LiquidationThresholdMinUsd) {
        throw "LiquidationThresholdMaxUsd must be greater than or equal to LiquidationThresholdMinUsd"
    }
    if ($resolved.PullbackPct -lt 0 -or $resolved.PullbackPct -ge 1) {
        throw "PullbackPct must be greater than or equal to zero and less than one"
    }
    if ($resolved.PolymarketUsdPerPosition -le 0) {
        throw "PolymarketUsdPerPosition must be greater than zero"
    }
    if ($resolved.OrderCancelWindowSeconds -lt 0) {
        throw "OrderCancelWindowSeconds must be non-negative"
    }

    [pscustomobject]$resolved
}

function Format-Command {
    param([Parameter(Mandatory = $true)][string[]]$Parts)

    ($Parts | ForEach-Object {
        if ($_ -match "\s") { '"' + ($_ -replace '"', '\"') + '"' } else { $_ }
    }) -join " "
}

function Read-ReplayArtifactSummary {
    if (-not (Test-Path -LiteralPath $ReplayArtifactFullPath)) {
        throw "Expected replay artifact was not written: $ReplayArtifactFullPath"
    }
    if (-not (Test-Path -LiteralPath $MarketArtifactFullPath)) {
        throw "Expected Polymarket market artifact was not written: $MarketArtifactFullPath"
    }

    $artifact = Get-Content -Raw -LiteralPath $ReplayArtifactFullPath | ConvertFrom-Json
    $markets = @(Get-Content -Raw -LiteralPath $MarketArtifactFullPath | ConvertFrom-Json)
    $market = if ($markets.Count -gt 0) { $markets[0] } else { $null }

    [pscustomobject]@{
        generated_at = ([DateTime]::UtcNow.ToString("o"))
        market_id = if ($market) { [string]$market.market_id } else { $null }
        market_start_ts = if ($market) { [string]$market.start_ts } else { $null }
        market_end_ts = if ($market) { [string]$market.end_ts } else { $null }
        strategy_version = [string]$artifact.strategy_version
        signal_count = [int]$artifact.signal_count
        polymarket_orders = [int]$artifact.polymarket_orders
        polymarket_fills = [int]$artifact.polymarket_fills
        hedge_attempts = [int]$artifact.hedge_attempts
        hedge_fills = [int]$artifact.hedge_fills
        net_pnl_usd = [string]$artifact.net_pnl_usd
        settlement_status = [string]$artifact.settlement_status
        run_summary = @($artifact.run_summary)
        signal_rejection_reasons = @($artifact.signal_rejection_reasons)
    }
}

function Write-AggregateReport {
    param(
        [Parameter(Mandatory = $true)][object[]]$Attempts,
        [Parameter(Mandatory = $true)][string]$Status
    )

    $parent = Split-Path -Parent $AggregateReportFullPath
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    $report = [pscustomobject]@{
        generated_at = ([DateTime]::UtcNow.ToString("o"))
        status = $Status
        until_entry_filled = [bool]$UntilEntryFilled
        max_replay_attempts = $MaxReplayAttempts
        attempts_completed = $Attempts.Count
        replay_artifact_path = [string]$ReplayArtifactFullPath
        market_artifact_path = [string]$MarketArtifactFullPath
        attempts = $Attempts
    }
    $report | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $AggregateReportFullPath -Encoding UTF8
}

$ResolvedReplayParameters = Resolve-ReplayParameters

$waitArgs = @(
    "-NoProfile",
    "-ExecutionPolicy", "Bypass",
    "-File", $WaitScript,
    "-DatabaseUrl", $DatabaseUrl,
    "-MarketArtifactPath", $MarketArtifactPath,
    "-ReplayArtifactPath", $ReplayArtifactPath,
    "-OkxInstrumentsPath", $OkxInstrumentsPath,
    "-MaxWindows", [string]$MaxWindows,
    "-MaxRuntimeSeconds", [string]$MaxRuntimeSeconds,
    "-MinFreshSeconds", [string]$MinFreshSeconds,
    "-MaxWaitForFreshWindowSeconds", [string]$MaxWaitForFreshWindowSeconds,
    "-PostWindowGraceSeconds", [string]$PostWindowGraceSeconds,
    "-DelayBetweenWindowsSeconds", [string]$DelayBetweenWindowsSeconds,
    "-ReplayProfile", $ReplayProfile,
    "-LiquidationThresholdMinUsd", [string]$ResolvedReplayParameters.LiquidationThresholdMinUsd,
    "-LiquidationThresholdMaxUsd", [string]$ResolvedReplayParameters.LiquidationThresholdMaxUsd,
    "-PullbackPct", [string]$ResolvedReplayParameters.PullbackPct,
    "-PolymarketUsdPerPosition", [string]$ResolvedReplayParameters.PolymarketUsdPerPosition,
    "-OrderCancelWindowSeconds", [string]$ResolvedReplayParameters.OrderCancelWindowSeconds
)

$dashboardArgs = @(
    "-NoProfile",
    "-ExecutionPolicy", "Bypass",
    "-File", $DashboardScript,
    "-Mode", "Live",
    "-DatabaseUrl", $DatabaseUrl,
    "-ReplayArtifactPath", $ReplayArtifactPath,
    "-PolymarketMarketArtifactPath", $MarketArtifactPath,
    "-Port", [string]$DashboardPort,
    "-BindHost", $DashboardBindHost,
    "-WindowMinutes", [string]$DashboardWindowMinutes,
    "-PollSeconds", [string]$DashboardPollSeconds,
    "-PolymarketMarketStaleAfterMinutes", [string]$PolymarketMarketStaleAfterMinutes
)
if (-not $NoOpenBrowser) {
    $dashboardArgs += "-OpenBrowser"
}

Write-Output "controlled replay: waiting for replay-ready liquidation window"
Write-Output "replay profile: $ReplayProfile"
Write-Output "strategy params: min=$($ResolvedReplayParameters.LiquidationThresholdMinUsd) max=$($ResolvedReplayParameters.LiquidationThresholdMaxUsd) pullback=$($ResolvedReplayParameters.PullbackPct) polymarket_usd=$($ResolvedReplayParameters.PolymarketUsdPerPosition) cancel_seconds=$($ResolvedReplayParameters.OrderCancelWindowSeconds)"
if ($UntilEntryFilled) {
    Write-Output "controlled replay mode: until entry filled, max attempts $MaxReplayAttempts"
    Write-Output "aggregate report: $AggregateReportFullPath"
}
Write-Output ("replay command: powershell " + (Format-Command -Parts $waitArgs))
if (-not $SkipDashboard) {
    Write-Output ("dashboard command: powershell " + (Format-Command -Parts $dashboardArgs))
}

if ($PrintCommandsOnly) {
    return
}

Push-Location $RepoRoot
try {
    $attemptSummaries = @()
    $attemptLimit = if ($UntilEntryFilled) { $MaxReplayAttempts } else { 1 }
    $entryFilled = $false

    for ($attempt = 1; $attempt -le $attemptLimit; $attempt++) {
        Write-Output "controlled replay attempt $attempt/$attemptLimit"
        & powershell @waitArgs
        if ($LASTEXITCODE -ne 0) {
            throw "wait-for-liquidation-replay.ps1 failed with exit code $LASTEXITCODE"
        }

        $summary = Read-ReplayArtifactSummary
        $summary | Add-Member -NotePropertyName attempt -NotePropertyValue $attempt
        $attemptSummaries += $summary

        if ($summary.polymarket_fills -gt 0) {
            $entryFilled = $true
            Write-AggregateReport -Attempts $attemptSummaries -Status "entry_filled"
            break
        }

        $status = if ($UntilEntryFilled) { "waiting_for_entry_fill" } else { "completed" }
        Write-AggregateReport -Attempts $attemptSummaries -Status $status

        if (-not $UntilEntryFilled) {
            break
        }
        if ($attempt -lt $attemptLimit) {
            Write-Output "polymarket_fills=0; waiting $DelayBetweenReplayAttemptsSeconds seconds before next controlled replay attempt"
            if ($DelayBetweenReplayAttemptsSeconds -gt 0) {
                Start-Sleep -Seconds $DelayBetweenReplayAttemptsSeconds
            }
        }
    }

    Write-Output "controlled replay artifact: $ReplayArtifactFullPath"
    Write-Output "polymarket market artifact: $MarketArtifactFullPath"
    if ($UntilEntryFilled) {
        Write-Output "controlled replay aggregate report: $AggregateReportFullPath"
        if (-not $entryFilled) {
            Write-AggregateReport -Attempts $attemptSummaries -Status "no_entry_fill"
            throw "No Polymarket entry fill found after $MaxReplayAttempts controlled replay attempt(s)"
        }
    }

    if ($SkipDashboard) {
        return
    }

    Write-Output "starting read-only dashboard..."
    & powershell @dashboardArgs
    exit $LASTEXITCODE
} finally {
    Pop-Location
}
