param(
    [string]$DatabaseUrl = $env:DATABASE_URL,
    [string]$ArtifactRoot = ".cache/replay/until-signal-built-aggregate",
    [string]$OutputPath = ".cache/replay/until-signal-built-aggregate-report.json",
    [string]$EntryFillAnalysisPath = ".cache/replay/until-signal-built-aggregate-entry-analysis.json",
    [string]$OkxInstrumentsPath = ".cache/okx/instruments-BTC-USDT-SWAP.json",
    [int]$TargetSignalWindows = 3,
    [int]$MaxTotalRuntimeSeconds = 7200,
    [int]$MaxCycleRuntimeSeconds = 900,
    [int]$MaxAttemptsPerCycle = 1,
    [int]$MaxWindowsPerAttempt = 1,
    [int]$MaxRuntimeSeconds = 330,
    [int]$MaxWaitForFreshWindowSeconds = 180,
    [int]$AttemptTimeoutBufferSeconds = 120,
    [int]$MinCycleBudgetSeconds = 420,
    [int]$DelayBetweenCyclesSeconds = 5,
    [string]$ReplayProfile = "baseline",
    [switch]$ContinueOnTechnicalFailure,
    [switch]$PrintCommandsOnly
)

$ErrorActionPreference = "Stop"

$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$SingleRunnerScript = Join-Path $PSScriptRoot "run-until-signal-built.ps1"
$EntryFillAnalyzerScript = Join-Path $PSScriptRoot "analyze-entry-fill-diagnostics.ps1"

if (-not $DatabaseUrl) {
    throw "DatabaseUrl or DATABASE_URL is required"
}
if ($TargetSignalWindows -lt 1) {
    throw "TargetSignalWindows must be at least 1"
}
if ($MaxTotalRuntimeSeconds -lt 60) {
    throw "MaxTotalRuntimeSeconds must be at least 60"
}
if ($MaxCycleRuntimeSeconds -lt 60) {
    throw "MaxCycleRuntimeSeconds must be at least 60"
}
if ($MinCycleBudgetSeconds -lt 60) {
    throw "MinCycleBudgetSeconds must be at least 60"
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

function Stop-RepoLiqProcesses {
    Get-Process -ErrorAction SilentlyContinue |
        Where-Object {
            $_.ProcessName -eq "liq" -and
            $_.Path -eq (Join-Path $RepoRoot "target\debug\liq.exe")
        } |
        Stop-Process -Force -ErrorAction SilentlyContinue
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
        Write-Output "__LIQ_AGG_EXIT_CODE:$LASTEXITCODE"
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
            if ($line -match "^__LIQ_AGG_EXIT_CODE:(-?\d+)$") {
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

function Write-JsonFile {
    param(
        [Parameter(Mandatory = $true)]$Value,
        [Parameter(Mandatory = $true)][string]$Path,
        [int]$Depth = 40
    )

    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $Value | ConvertTo-Json -Depth $Depth | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Read-SignalReplayArtifacts {
    param([Parameter(Mandatory = $true)][string]$ReportPath)

    $report = Get-Content -Raw -LiteralPath $ReportPath | ConvertFrom-Json
    if ([string]$report.stopped_reason -ne "signal_built_observed") {
        return @()
    }

    $aggregatePath = [string]$report.aggregate_report_path
    if (-not (Test-Path -LiteralPath $aggregatePath)) {
        throw "Aggregate report not found: $aggregatePath"
    }
    $aggregate = Get-Content -Raw -LiteralPath $aggregatePath | ConvertFrom-Json
    @($aggregate.attempts |
        Where-Object { $_.status -eq "completed" -and [int]$_.signal_count -gt 0 } |
        ForEach-Object { [string]$_.replay_artifact_path })
}

$outputFullPath = Resolve-RepoPath -Path $OutputPath
$entryAnalysisFullPath = Resolve-RepoPath -Path $EntryFillAnalysisPath
$artifactRootFullPath = Resolve-RepoPath -Path $ArtifactRoot

$startedAt = [DateTime]::UtcNow
$cycles = @()
$replayArtifactPaths = [System.Collections.ArrayList]::new()
$signalWindows = 0
$noReplayReadyWindows = 0
$failedCycles = 0
$shortTailCyclesSkipped = 0
$cycle = 0

$templateArgs = @(
    "-NoProfile",
    "-ExecutionPolicy", "Bypass",
    "-File", $SingleRunnerScript,
    "-DatabaseUrl", $DatabaseUrl,
    "-ArtifactRoot", (Join-Path $ArtifactRoot "cycle-NNN"),
    "-OkxInstrumentsPath", $OkxInstrumentsPath,
    "-MaxTotalRuntimeSeconds", [string]$MaxCycleRuntimeSeconds,
    "-MaxAttempts", [string]$MaxAttemptsPerCycle,
    "-MaxWindowsPerAttempt", [string]$MaxWindowsPerAttempt,
    "-MaxRuntimeSeconds", [string]$MaxRuntimeSeconds,
    "-MaxWaitForFreshWindowSeconds", [string]$MaxWaitForFreshWindowSeconds,
    "-AttemptTimeoutBufferSeconds", [string]$AttemptTimeoutBufferSeconds,
    "-ReplayProfile", $ReplayProfile
)

if ($PrintCommandsOnly) {
    [pscustomobject]@{
        generated_at = ([DateTime]::UtcNow.ToString("o"))
        target_signal_windows = $TargetSignalWindows
        max_total_runtime_seconds = $MaxTotalRuntimeSeconds
        min_cycle_budget_seconds = $MinCycleBudgetSeconds
        command_template = "powershell " + (Format-Command -Parts ([string[]]$templateArgs))
        output_path = [string]$outputFullPath
        combined_entry_fill_analysis_path = [string]$entryAnalysisFullPath
    } | ConvertTo-Json -Depth 20
    return
}

while ($signalWindows -lt $TargetSignalWindows) {
    $elapsedSeconds = [int](([DateTime]::UtcNow - $startedAt).TotalSeconds)
    $remainingSeconds = $MaxTotalRuntimeSeconds - $elapsedSeconds
    if ($remainingSeconds -lt $MinCycleBudgetSeconds) {
        $shortTailCyclesSkipped += 1
        Write-Output "skipping short tail cycle: remaining_seconds=$remainingSeconds min_cycle_budget_seconds=$MinCycleBudgetSeconds"
        break
    }

    $cycle += 1
    $cycleArtifactRoot = Join-Path $ArtifactRoot ("cycle-{0:D3}" -f $cycle)
    $cycleTimeout = [Math]::Min($MaxCycleRuntimeSeconds, $remainingSeconds)
    $cycleArgs = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", $SingleRunnerScript,
        "-DatabaseUrl", $DatabaseUrl,
        "-ArtifactRoot", $cycleArtifactRoot,
        "-OkxInstrumentsPath", $OkxInstrumentsPath,
        "-MaxTotalRuntimeSeconds", [string]$cycleTimeout,
        "-MaxAttempts", [string]$MaxAttemptsPerCycle,
        "-MaxWindowsPerAttempt", [string]$MaxWindowsPerAttempt,
        "-MaxRuntimeSeconds", [string]$MaxRuntimeSeconds,
        "-MaxWaitForFreshWindowSeconds", [string]$MaxWaitForFreshWindowSeconds,
        "-AttemptTimeoutBufferSeconds", [string]$AttemptTimeoutBufferSeconds,
        "-ReplayProfile", $ReplayProfile
    )

    Write-Output "until-signal aggregate cycle $cycle target=$TargetSignalWindows collected=$signalWindows"
    Write-Output ("powershell " + (Format-Command -Parts ([string[]]$cycleArgs)))

    try {
        $result = Invoke-NestedPowerShell -Args ([string[]]$cycleArgs) -TimeoutSeconds ($cycleTimeout + 180)
        $result.output | ForEach-Object { Write-Output ([string]$_) }
        if ([int]$result.exit_code -ne 0) {
            throw "run-until-signal-built.ps1 failed with exit code $($result.exit_code)"
        }

        $cycleRootFullPath = Resolve-RepoPath -Path $cycleArtifactRoot
        $reportPath = Get-ChildItem -LiteralPath $cycleRootFullPath -Filter "until-signal-built-*-report.json" -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1
        if ($null -eq $reportPath) {
            throw "cycle report was not written under $cycleRootFullPath"
        }

        $cycleReport = Get-Content -Raw -LiteralPath $reportPath.FullName | ConvertFrom-Json
        $cycleReplayArtifacts = @(Read-SignalReplayArtifacts -ReportPath $reportPath.FullName)
        foreach ($path in $cycleReplayArtifacts) {
            $replayArtifactPaths.Add($path) | Out-Null
        }
        $signalWindows += $cycleReplayArtifacts.Count
        $noReplayReadyWindows += [int]$cycleReport.no_replay_ready_windows
        $cycles += [pscustomobject]@{
            cycle = $cycle
            status = [string]$cycleReport.status
            stopped_reason = [string]$cycleReport.stopped_reason
            report_path = [string]$reportPath.FullName
            replay_artifact_paths = @($cycleReplayArtifacts)
            signals_collected = $cycleReplayArtifacts.Count
            no_replay_ready_windows = [int]$cycleReport.no_replay_ready_windows
            failed_attempts = [int]$cycleReport.failed_attempts
        }
    } catch {
        $failedCycles += 1
        $cycles += [pscustomobject]@{
            cycle = $cycle
            status = "failed"
            stopped_reason = "technical_failure"
            report_path = $null
            replay_artifact_paths = @()
            signals_collected = 0
            no_replay_ready_windows = 0
            failed_attempts = 1
            error = $_.Exception.Message
        }
        Write-Warning $_.Exception.Message
        if (-not $ContinueOnTechnicalFailure) {
            Write-Output "stopping after technical failure; rerun with -ContinueOnTechnicalFailure to override"
            break
        }
    }

    if ($signalWindows -lt $TargetSignalWindows -and $DelayBetweenCyclesSeconds -gt 0) {
        Start-Sleep -Seconds $DelayBetweenCyclesSeconds
    }
}

$combinedEntryFillAnalysis = $null
if ($replayArtifactPaths.Count -gt 0) {
    $artifactListPath = [System.IO.Path]::ChangeExtension($entryAnalysisFullPath, ".artifacts.txt")
    @($replayArtifactPaths | ForEach-Object { [string]$_ }) |
        Set-Content -LiteralPath $artifactListPath -Encoding utf8

    $analysisArgs = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", $EntryFillAnalyzerScript,
        "-ReplayArtifactListPath", $artifactListPath,
        "-DisableReplayArtifactDirectory",
        "-OutputPath", $EntryFillAnalysisPath
    )

    $analysisResult = Invoke-NestedPowerShell -Args ([string[]]$analysisArgs) -TimeoutSeconds 180
    $analysisResult.output | ForEach-Object { Write-Output ([string]$_) }
    if ([int]$analysisResult.exit_code -ne 0) {
        throw "analyze-entry-fill-diagnostics.ps1 failed with exit code $($analysisResult.exit_code)"
    }
    if (Test-Path -LiteralPath $entryAnalysisFullPath) {
        $combinedEntryFillAnalysis = Get-Content -Raw -LiteralPath $entryAnalysisFullPath | ConvertFrom-Json
    }
}

$status = if ($signalWindows -ge $TargetSignalWindows) {
    "target_reached"
} elseif ($signalWindows -gt 0) {
    "partial"
} elseif ($failedCycles -gt 0) {
    "failed"
} else {
    "no_signals"
}

$report = [pscustomobject]@{
    generated_at = ([DateTime]::UtcNow.ToString("o"))
    status = $status
    target_signal_windows = $TargetSignalWindows
    signal_windows_collected = $signalWindows
    cycles_completed = $cycle
    failed_cycles = $failedCycles
    short_tail_cycles_skipped = $shortTailCyclesSkipped
    no_replay_ready_windows = $noReplayReadyWindows
    replay_artifact_paths = @($replayArtifactPaths)
    output_path = [string]$outputFullPath
    combined_entry_fill_analysis_path = [string]$entryAnalysisFullPath
    combined_entry_fill_analysis = $combinedEntryFillAnalysis
    cycles = $cycles
}
Write-JsonFile -Value $report -Path $outputFullPath

Write-Output "until-signal aggregate report written: $outputFullPath"
Write-Output "status=$status signal_windows_collected=$signalWindows target_signal_windows=$TargetSignalWindows failed_cycles=$failedCycles no_replay_ready_windows=$noReplayReadyWindows"
if ($combinedEntryFillAnalysis) {
    Write-Output "combined_entry_fill_classification=$($combinedEntryFillAnalysis.decision.classification)"
    Write-Output "combined_entry_fill_summary=signals=$($combinedEntryFillAnalysis.summary.signals) fills=$($combinedEntryFillAnalysis.summary.polymarket_fills) avg_trade_distance=$($combinedEntryFillAnalysis.summary.average_trade_distance_to_fill) avg_seconds_to_expiry=$($combinedEntryFillAnalysis.summary.average_seconds_to_order_expiry)"
}
