param(
    [string]$DatabaseUrl = $env:DATABASE_URL,
    [string]$ArtifactDirectory = ".cache/replay/entry-fill-diagnostics-batch",
    [string]$OutputPath = ".cache/replay/entry-fill-diagnostics-batch-report.json",
    [string]$AggregateReportPath = ".cache/replay/entry-fill-diagnostics-batch-aggregate.json",
    [string]$TradePathAnalysisPath = ".cache/replay/entry-fill-diagnostics-batch-trade-path-analysis.json",
    [string]$EntryFillAnalysisPath = ".cache/replay/entry-fill-diagnostics-batch-entry-analysis.json",
    [string]$OkxInstrumentsPath = ".cache/okx/instruments-BTC-USDT-SWAP.json",
    [int]$MaxAttempts = 3,
    [int]$MaxWindowsPerAttempt = 6,
    [int]$MaxRuntimeSeconds = 330,
    [int]$MaxTotalRuntimeSeconds = 1800,
    [int]$AttemptTimeoutBufferSeconds = 120,
    [int]$MinFreshSeconds = 120,
    [int]$MaxWaitForFreshWindowSeconds = 360,
    [int]$PostWindowGraceSeconds = 10,
    [int]$DelayBetweenAttemptsSeconds = 10,
    [int]$DelayBetweenWindowsSeconds = 5,
    [string]$ReplayProfile = "baseline",
    [decimal]$LiquidationThresholdMinUsd = -1,
    [decimal]$LiquidationThresholdMaxUsd = -1,
    [decimal]$PullbackPct = -1,
    [decimal]$PolymarketUsdPerPosition = -1,
    [int]$OrderCancelWindowSeconds = -1,
    [switch]$UntilSignalBuilt,
    [switch]$StopOnEntryFill,
    [switch]$FailFast,
    [switch]$PrintCommandsOnly
)

$ErrorActionPreference = "Stop"

$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$ControlledReplayScript = Join-Path $PSScriptRoot "controlled-replay.ps1"
$TradePathAnalyzerScript = Join-Path $PSScriptRoot "analyze-controlled-replay.ps1"
$EntryFillAnalyzerScript = Join-Path $PSScriptRoot "analyze-entry-fill-diagnostics.ps1"

if (-not $DatabaseUrl) {
    throw "DatabaseUrl or DATABASE_URL is required"
}
if ($MaxAttempts -lt 1) {
    throw "MaxAttempts must be at least 1"
}
if ($MaxWindowsPerAttempt -lt 1) {
    throw "MaxWindowsPerAttempt must be at least 1"
}
if ($MaxRuntimeSeconds -lt 30) {
    throw "MaxRuntimeSeconds must be at least 30"
}
if ($MaxTotalRuntimeSeconds -lt 60) {
    throw "MaxTotalRuntimeSeconds must be at least 60"
}
if ($AttemptTimeoutBufferSeconds -lt 30) {
    throw "AttemptTimeoutBufferSeconds must be at least 30"
}
if ($DelayBetweenAttemptsSeconds -lt 0) {
    throw "DelayBetweenAttemptsSeconds must be non-negative"
}

function Resolve-RepoPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return $Path
    }
    Join-Path $RepoRoot $Path
}

function Format-Command {
    param([Parameter(Mandatory = $true)][string[]]$Parts)

    ($Parts | ForEach-Object {
        if ($_ -match "\s") { '"' + ($_ -replace '"', '\"') + '"' } else { $_ }
    }) -join " "
}

function Add-OptionalReplayOverride {
    param(
        [Parameter(Mandatory = $true)]$Args,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)]$Value
    )

    if ($Value -ge 0) {
        $Args.Add($Name) | Out-Null
        $Args.Add([string]$Value) | Out-Null
    }
}

function Test-ShouldStopAfterAttempt {
    param([Parameter(Mandatory = $true)]$Summary)

    if ($UntilSignalBuilt -and [int]$Summary.signal_count -gt 0) {
        return [pscustomobject]@{
            should_stop = $true
            stopped_reason = "signal_built_observed"
        }
    }
    if ($StopOnEntryFill -and [int]$Summary.polymarket_fills -gt 0) {
        return [pscustomobject]@{
            should_stop = $true
            stopped_reason = "entry_fill_observed"
        }
    }

    [pscustomobject]@{
        should_stop = $false
        stopped_reason = $null
    }
}

function Read-ReplayArtifactSummary {
    param(
        [Parameter(Mandatory = $true)][int]$Attempt,
        [Parameter(Mandatory = $true)][string]$ReplayArtifactPath,
        [Parameter(Mandatory = $true)][string]$MarketArtifactPath,
        [Parameter(Mandatory = $true)][string]$AttemptAggregatePath
    )

    if (-not (Test-Path -LiteralPath $ReplayArtifactPath)) {
        throw "Replay artifact was not written: $ReplayArtifactPath"
    }

    $artifact = Get-Content -Raw -LiteralPath $ReplayArtifactPath | ConvertFrom-Json
    $markets = if (Test-Path -LiteralPath $MarketArtifactPath) {
        @(Get-Content -Raw -LiteralPath $MarketArtifactPath | ConvertFrom-Json)
    } else {
        @()
    }
    $market = if ($markets.Count -gt 0) { $markets[0] } else { $null }

    [pscustomobject]@{
        attempt = $Attempt
        status = "completed"
        replay_artifact_path = [string]$ReplayArtifactPath
        market_artifact_path = [string]$MarketArtifactPath
        attempt_aggregate_path = [string]$AttemptAggregatePath
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

function Write-JsonFile {
    param(
        [Parameter(Mandatory = $true)]$Value,
        [Parameter(Mandatory = $true)][string]$Path,
        [int]$Depth = 30
    )

    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $Value | ConvertTo-Json -Depth $Depth | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Invoke-NestedPowerShell {
    param(
        [Parameter(Mandatory = $true)][string[]]$Args,
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds
    )

    $job = Start-Job -ScriptBlock {
        param($WorkingDirectory, $NestedArgs)
        Set-Location $WorkingDirectory
        $ErrorActionPreference = "Continue"
        & powershell @NestedArgs 2>&1 | ForEach-Object {
            Write-Output ([string]$_)
        }
        Write-Output "__LIQ_BATCH_EXIT_CODE:$LASTEXITCODE"
    } -ArgumentList $RepoRoot, $Args

    try {
        $completed = Wait-Job -Job $job -Timeout $TimeoutSeconds
        if ($null -eq $completed) {
            Stop-Job -Job $job -ErrorAction SilentlyContinue
            Stop-RepoLiqProcesses
            throw "nested powershell command timed out after $TimeoutSeconds seconds"
        }
        $exitCode = 0
        $lines = [System.Collections.ArrayList]::new()
        Receive-Job -Job $job -ErrorAction SilentlyContinue | ForEach-Object {
            $line = [string]$_
            if ($line -match "^__LIQ_BATCH_EXIT_CODE:(-?\d+)$") {
                $exitCode = [int]$Matches[1]
                return
            }
            $lines.Add($line) | Out-Null
        }
        [pscustomobject]@{
            exit_code = $exitCode
            output = @($lines)
        }
    } finally {
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
    }
}

function Stop-RepoLiqProcesses {
    Get-Process -ErrorAction SilentlyContinue |
        Where-Object {
            $_.ProcessName -eq "liq" -and
            $_.Path -eq (Join-Path $RepoRoot "target\debug\liq.exe")
        } |
        Stop-Process -Force -ErrorAction SilentlyContinue
}

$artifactDirectoryFullPath = Resolve-RepoPath -Path $ArtifactDirectory
$aggregateReportFullPath = Resolve-RepoPath -Path $AggregateReportPath
$tradePathAnalysisFullPath = Resolve-RepoPath -Path $TradePathAnalysisPath
$entryFillAnalysisFullPath = Resolve-RepoPath -Path $EntryFillAnalysisPath
$outputFullPath = Resolve-RepoPath -Path $OutputPath

$plannedCommands = @()
for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
    $attemptName = "attempt-{0:D3}" -f $attempt
    $attemptDirectory = Join-Path $ArtifactDirectory $attemptName
    $marketArtifactPath = Join-Path $attemptDirectory "market.json"
    $replayArtifactPath = Join-Path $attemptDirectory "replay.json"
    $attemptAggregatePath = Join-Path $attemptDirectory "controlled-aggregate.json"

    $argsList = [System.Collections.ArrayList]@(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", $ControlledReplayScript,
        "-DatabaseUrl", $DatabaseUrl,
        "-MarketArtifactPath", $marketArtifactPath,
        "-ReplayArtifactPath", $replayArtifactPath,
        "-OkxInstrumentsPath", $OkxInstrumentsPath,
        "-MaxWindows", [string]$MaxWindowsPerAttempt,
        "-MaxRuntimeSeconds", [string]$MaxRuntimeSeconds,
        "-MinFreshSeconds", [string]$MinFreshSeconds,
        "-MaxWaitForFreshWindowSeconds", [string]$MaxWaitForFreshWindowSeconds,
        "-PostWindowGraceSeconds", [string]$PostWindowGraceSeconds,
        "-DelayBetweenWindowsSeconds", [string]$DelayBetweenWindowsSeconds,
        "-ReplayProfile", $ReplayProfile,
        "-AggregateReportPath", $attemptAggregatePath,
        "-SkipDashboard",
        "-NoOpenBrowser"
    )
    Add-OptionalReplayOverride -Args $argsList -Name "-LiquidationThresholdMinUsd" -Value $LiquidationThresholdMinUsd
    Add-OptionalReplayOverride -Args $argsList -Name "-LiquidationThresholdMaxUsd" -Value $LiquidationThresholdMaxUsd
    Add-OptionalReplayOverride -Args $argsList -Name "-PullbackPct" -Value $PullbackPct
    Add-OptionalReplayOverride -Args $argsList -Name "-PolymarketUsdPerPosition" -Value $PolymarketUsdPerPosition
    Add-OptionalReplayOverride -Args $argsList -Name "-OrderCancelWindowSeconds" -Value $OrderCancelWindowSeconds

    $plannedCommands += [pscustomobject]@{
        attempt = $attempt
        command_args = [string[]]$argsList
        command = "powershell " + (Format-Command -Parts ([string[]]$argsList))
        market_artifact_path = [string](Resolve-RepoPath -Path $marketArtifactPath)
        replay_artifact_path = [string](Resolve-RepoPath -Path $replayArtifactPath)
        attempt_aggregate_path = [string](Resolve-RepoPath -Path $attemptAggregatePath)
    }
}

$tradePathAnalysisCommand = "powershell " + (Format-Command -Parts @(
    "-NoProfile",
    "-ExecutionPolicy", "Bypass",
    "-File", $TradePathAnalyzerScript,
    "-AggregateReportPath", $AggregateReportPath,
    "-OutputPath", $TradePathAnalysisPath
))
$entryFillAnalysisCommand = "powershell " + (Format-Command -Parts @(
    "-NoProfile",
    "-ExecutionPolicy", "Bypass",
    "-File", $EntryFillAnalyzerScript,
    "-ReplayArtifactDirectory", $ArtifactDirectory,
    "-OutputPath", $EntryFillAnalysisPath
))
$analysisCommands = @($tradePathAnalysisCommand, $entryFillAnalysisCommand)

if ($PrintCommandsOnly) {
    [pscustomobject]@{
        generated_at = ([DateTime]::UtcNow.ToString("o"))
        until_signal_built = [bool]$UntilSignalBuilt
        stop_on_entry_fill = [bool]$StopOnEntryFill
        planned_attempts = $plannedCommands
        planned_analysis_commands = $analysisCommands
        output_path = [string]$outputFullPath
    } | ConvertTo-Json -Depth 10
    return
}

if (-not (Test-Path -LiteralPath $artifactDirectoryFullPath)) {
    New-Item -ItemType Directory -Force -Path $artifactDirectoryFullPath | Out-Null
}

$startedAt = [DateTime]::UtcNow
$attempts = @()
$completed = 0
$failed = 0
$noReplayReady = 0
$stoppedReason = "max_attempts_reached"
$attemptTimeoutSeconds = ($MaxWindowsPerAttempt * ($MaxRuntimeSeconds + $DelayBetweenWindowsSeconds + 30)) +
    $MaxWaitForFreshWindowSeconds +
    $AttemptTimeoutBufferSeconds

for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
    $elapsedSeconds = [int](([DateTime]::UtcNow - $startedAt).TotalSeconds)
    if ($elapsedSeconds -ge $MaxTotalRuntimeSeconds) {
        $stoppedReason = "max_total_runtime_reached"
        break
    }

    $planned = $plannedCommands[$attempt - 1]
    Write-Output "entry fill diagnostics batch attempt $attempt/$MaxAttempts"
    Write-Output $planned.command

    try {
        $nestedResult = Invoke-NestedPowerShell -Args ([string[]]$planned.command_args) -TimeoutSeconds $attemptTimeoutSeconds
        $nestedResult.output | ForEach-Object { Write-Output ([string]$_) }
        if ([int]$nestedResult.exit_code -ne 0) {
            $noReplayReadyWindow = @($nestedResult.output | Where-Object {
                [string]$_ -match "No replay-ready liquidation window found"
            }).Count -gt 0
            if ($noReplayReadyWindow) {
                $noReplayReady += 1
                $attempts += [pscustomobject]@{
                    attempt = $attempt
                    status = "no_replay_ready_window"
                    replay_artifact_path = [string]$planned.replay_artifact_path
                    market_artifact_path = [string]$planned.market_artifact_path
                    attempt_aggregate_path = [string]$planned.attempt_aggregate_path
                    error = "No replay-ready liquidation window found"
                    run_summary = @()
                    signal_rejection_reasons = @()
                    signal_count = 0
                    polymarket_orders = 0
                    polymarket_fills = 0
                    hedge_attempts = 0
                    hedge_fills = 0
                }
                continue
            }
            throw "controlled replay attempt $attempt failed with exit code $($nestedResult.exit_code)"
        }

        $summary = Read-ReplayArtifactSummary `
            -Attempt $attempt `
            -ReplayArtifactPath ([string]$planned.replay_artifact_path) `
            -MarketArtifactPath ([string]$planned.market_artifact_path) `
            -AttemptAggregatePath ([string]$planned.attempt_aggregate_path)
        $attempts += $summary
        $completed += 1

        $stopDecision = Test-ShouldStopAfterAttempt -Summary $summary
        if ($stopDecision.should_stop) {
            $stoppedReason = [string]$stopDecision.stopped_reason
            break
        }
    } catch {
        $failed += 1
        $attempts += [pscustomobject]@{
            attempt = $attempt
            status = "failed"
            replay_artifact_path = [string]$planned.replay_artifact_path
            market_artifact_path = [string]$planned.market_artifact_path
            attempt_aggregate_path = [string]$planned.attempt_aggregate_path
            error = $_.Exception.Message
            run_summary = @()
            signal_rejection_reasons = @()
            signal_count = 0
            polymarket_orders = 0
            polymarket_fills = 0
            hedge_attempts = 0
            hedge_fills = 0
        }
        Write-Warning $_.Exception.Message
        if ($FailFast) {
            $stoppedReason = "failed_fast"
            break
        }
    }

    if ($attempt -lt $MaxAttempts -and $DelayBetweenAttemptsSeconds -gt 0) {
        Start-Sleep -Seconds $DelayBetweenAttemptsSeconds
    }
}

$status = if ($completed -gt 0 -or $noReplayReady -gt 0) { "completed" } else { "failed" }
$aggregate = [pscustomobject]@{
    generated_at = ([DateTime]::UtcNow.ToString("o"))
    status = $status
    started_at = $startedAt.ToString("o")
    stopped_reason = $stoppedReason
    replay_profile = $ReplayProfile
    until_signal_built = [bool]$UntilSignalBuilt
    stop_on_entry_fill = [bool]$StopOnEntryFill
    max_attempts = $MaxAttempts
    attempts_completed = $completed
    no_replay_ready_windows = $noReplayReady
    failed_attempts = $failed
    artifact_directory = [string]$artifactDirectoryFullPath
    attempts = $attempts
}
Write-JsonFile -Value $aggregate -Path $aggregateReportFullPath

if ($completed -gt 0) {
    $tradeResult = Invoke-NestedPowerShell -Args @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", $TradePathAnalyzerScript,
        "-AggregateReportPath", $AggregateReportPath,
        "-OutputPath", $TradePathAnalysisPath
    ) -TimeoutSeconds 120
    $tradeResult.output | ForEach-Object { Write-Output ([string]$_) }
    if ([int]$tradeResult.exit_code -ne 0) {
        throw "analyze-controlled-replay.ps1 failed with exit code $($tradeResult.exit_code)"
    }

    $entryResult = Invoke-NestedPowerShell -Args @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", $EntryFillAnalyzerScript,
        "-ReplayArtifactDirectory", $ArtifactDirectory,
        "-OutputPath", $EntryFillAnalysisPath
    ) -TimeoutSeconds 120
    $entryResult.output | ForEach-Object { Write-Output ([string]$_) }
    if ([int]$entryResult.exit_code -ne 0) {
        throw "analyze-entry-fill-diagnostics.ps1 failed with exit code $($entryResult.exit_code)"
    }
}

$tradePathAnalysis = if (Test-Path -LiteralPath $tradePathAnalysisFullPath) {
    Get-Content -Raw -LiteralPath $tradePathAnalysisFullPath | ConvertFrom-Json
} else {
    $null
}
$entryFillAnalysis = if (Test-Path -LiteralPath $entryFillAnalysisFullPath) {
    Get-Content -Raw -LiteralPath $entryFillAnalysisFullPath | ConvertFrom-Json
} else {
    $null
}

$finalReport = [pscustomobject]@{
    generated_at = ([DateTime]::UtcNow.ToString("o"))
    status = $status
    stopped_reason = $stoppedReason
    until_signal_built = [bool]$UntilSignalBuilt
    stop_on_entry_fill = [bool]$StopOnEntryFill
    attempts_completed = $completed
    no_replay_ready_windows = $noReplayReady
    failed_attempts = $failed
    aggregate_report_path = [string]$aggregateReportFullPath
    trade_path_analysis_path = [string]$tradePathAnalysisFullPath
    entry_fill_analysis_path = [string]$entryFillAnalysisFullPath
    trade_path_analysis = $tradePathAnalysis
    entry_fill_analysis = $entryFillAnalysis
}
Write-JsonFile -Value $finalReport -Path $outputFullPath -Depth 40

Write-Output "entry fill diagnostics batch report written: $outputFullPath"
Write-Output "aggregate_report_path=$aggregateReportFullPath"
Write-Output "trade_path_analysis_path=$tradePathAnalysisFullPath"
Write-Output "entry_fill_analysis_path=$entryFillAnalysisFullPath"
if ($entryFillAnalysis) {
    Write-Output "entry_fill_classification=$($entryFillAnalysis.decision.classification)"
    Write-Output "entry_fill_summary=signals=$($entryFillAnalysis.summary.signals) orders=$($entryFillAnalysis.summary.polymarket_orders) fills=$($entryFillAnalysis.summary.polymarket_fills) late_ratio=$($entryFillAnalysis.summary.late_entry_ratio) avg_trade_distance=$($entryFillAnalysis.summary.average_trade_distance_to_fill) avg_seconds_to_expiry=$($entryFillAnalysis.summary.average_seconds_to_order_expiry)"
}

if ($completed -eq 0 -and $noReplayReady -eq 0) {
    exit 1
}
exit 0
