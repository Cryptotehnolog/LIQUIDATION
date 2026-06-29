param(
    [string]$DatabaseUrl = $env:DATABASE_URL,
    [string]$ArtifactRoot = "",
    [string[]]$PreviousSignalReportPath = @(),
    [string]$OkxInstrumentsPath = ".cache/okx/instruments-BTC-USDT-SWAP.json",
    [int]$TargetSignalWindows = 4,
    [int]$MaxTotalRuntimeSeconds = 7200,
    [int]$MaxCycleRuntimeSeconds = 900,
    [int]$MaxAttemptsPerCycle = 1,
    [int]$MaxWindowsPerAttempt = 1,
    [int]$MaxRuntimeSeconds = 330,
    [int]$MaxWaitForFreshWindowSeconds = 240,
    [int]$AttemptTimeoutBufferSeconds = 180,
    [int]$MinCycleBudgetSeconds = 420,
    [int]$DelayBetweenCyclesSeconds = 5,
    [decimal[]]$PullbackPct = @(0.30, 0.20, 0.15, 0.10),
    [string]$ReplayProfile = "baseline",
    [switch]$SkipPreflight,
    [switch]$SkipCollection,
    [switch]$ContinueOnTechnicalFailure,
    [switch]$PrintCommandsOnly
)

$ErrorActionPreference = "Stop"

$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$SignalRunnerScript = Join-Path $PSScriptRoot "run-until-signal-built-aggregate.ps1"
$PullbackAggregateScript = Join-Path $PSScriptRoot "compare-pullback-profiles-aggregate.ps1"
$InvariantCulture = [System.Globalization.CultureInfo]::InvariantCulture

if (-not $DatabaseUrl) {
    throw "DatabaseUrl or DATABASE_URL is required"
}
if ($TargetSignalWindows -lt 1) {
    throw "TargetSignalWindows must be at least 1"
}
if ($PullbackPct.Count -lt 2) {
    throw "At least two PullbackPct values are required"
}
if ($SkipCollection -and $PreviousSignalReportPath.Count -eq 0) {
    throw "SkipCollection requires PreviousSignalReportPath"
}
foreach ($value in $PullbackPct) {
    if ($value -lt 0 -or $value -ge 1) {
        throw "PullbackPct values must be greater than or equal to 0 and less than 1"
    }
}
if (@($PullbackPct | Sort-Object -Unique).Count -ne $PullbackPct.Count) {
    throw "PullbackPct values must be unique"
}

if ([string]::IsNullOrWhiteSpace($ArtifactRoot)) {
    $ArtifactRoot = Join-Path ".cache/replay/signal-pullback-pipeline" (Get-Date -Format "yyyyMMdd-HHmmss")
}

function Resolve-RepoPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return $Path
    }
    Join-Path $RepoRoot $Path
}

function Convert-ToRepoRelativePath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $fullPath = Resolve-RepoPath -Path $Path
    $repoRootText = ([string]$RepoRoot).TrimEnd("\")
    if ($fullPath.StartsWith($repoRootText, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $fullPath.Substring($repoRootText.Length).TrimStart("\")
    }
    $fullPath
}

function Format-Command {
    param([Parameter(Mandatory = $true)][string[]]$Parts)

    ($Parts | ForEach-Object {
        if ($_ -match "\s") { '"' + ($_ -replace '"', '\"') + '"' } else { $_ }
    }) -join " "
}

function Format-Decimal {
    param([Parameter(Mandatory = $true)][decimal]$Value)

    $Value.ToString($InvariantCulture)
}

function Write-JsonFile {
    param(
        [Parameter(Mandatory = $true)]$Value,
        [Parameter(Mandatory = $true)][string]$Path,
        [int]$Depth = 50
    )

    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $Value | ConvertTo-Json -Depth $Depth | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Invoke-PowerShellScript {
    param([Parameter(Mandatory = $true)][string[]]$Args)

    Write-Output ("powershell " + (Format-Command -Parts $Args))
    & powershell @Args
    if ($LASTEXITCODE -ne 0) {
        throw "Nested PowerShell command failed with exit code $LASTEXITCODE"
    }
}

function Get-ReplayArtifactPathsFromReport {
    param([Parameter(Mandatory = $true)][string]$ReportPath)

    $reportFullPath = Resolve-RepoPath -Path $ReportPath
    if (-not (Test-Path -LiteralPath $reportFullPath)) {
        throw "Signal report not found: $reportFullPath"
    }

    $report = Get-Content -Raw -LiteralPath $reportFullPath | ConvertFrom-Json
    @($report.replay_artifact_paths |
        ForEach-Object { [string]$_ } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function Get-MarketArtifactPathsFromReports {
    param([Parameter(Mandatory = $true)][string[]]$ReportPaths)

    $paths = [System.Collections.ArrayList]::new()
    foreach ($reportPath in $ReportPaths) {
        foreach ($replayPath in @(Get-ReplayArtifactPathsFromReport -ReportPath $reportPath)) {
            $replayFullPath = Resolve-RepoPath -Path $replayPath
            $marketPath = Join-Path (Split-Path -Parent $replayFullPath) "market.json"
            if (-not (Test-Path -LiteralPath $marketPath)) {
                Write-Warning "Market artifact not found for replay artifact: $replayFullPath"
                continue
            }
            $relative = Convert-ToRepoRelativePath -Path $marketPath
            if (-not $paths.Contains($relative)) {
                $paths.Add($relative) | Out-Null
            }
        }
    }

    @($paths | Sort-Object -Unique)
}

$artifactRootFullPath = Resolve-RepoPath -Path $ArtifactRoot
$cyclesPath = Join-Path $ArtifactRoot "cycles"
$signalReportPath = Join-Path $ArtifactRoot "report.json"
$entryAnalysisPath = Join-Path $ArtifactRoot "entry-analysis.json"
$marketManifestPath = Join-Path $ArtifactRoot "aggregate-market-paths.txt"
$pullbackOutputPath = Join-Path $ArtifactRoot "pullback-aggregate.json"
$pullbackArtifactDirectory = Join-Path $ArtifactRoot "pullback-aggregate"
$summaryPath = Join-Path $ArtifactRoot "pipeline-summary.json"
$dashboardArtifactPath = ".cache/replay/latest-signal-pullback-pipeline.json"

$signalArgs = @(
    "-NoProfile",
    "-ExecutionPolicy", "Bypass",
    "-File", $SignalRunnerScript,
    "-DatabaseUrl", $DatabaseUrl,
    "-ArtifactRoot", $cyclesPath,
    "-OutputPath", $signalReportPath,
    "-EntryFillAnalysisPath", $entryAnalysisPath,
    "-OkxInstrumentsPath", $OkxInstrumentsPath,
    "-TargetSignalWindows", [string]$TargetSignalWindows,
    "-MaxTotalRuntimeSeconds", [string]$MaxTotalRuntimeSeconds,
    "-MaxCycleRuntimeSeconds", [string]$MaxCycleRuntimeSeconds,
    "-MaxAttemptsPerCycle", [string]$MaxAttemptsPerCycle,
    "-MaxWindowsPerAttempt", [string]$MaxWindowsPerAttempt,
    "-MaxRuntimeSeconds", [string]$MaxRuntimeSeconds,
    "-MaxWaitForFreshWindowSeconds", [string]$MaxWaitForFreshWindowSeconds,
    "-AttemptTimeoutBufferSeconds", [string]$AttemptTimeoutBufferSeconds,
    "-MinCycleBudgetSeconds", [string]$MinCycleBudgetSeconds,
    "-DelayBetweenCyclesSeconds", [string]$DelayBetweenCyclesSeconds,
    "-ReplayProfile", $ReplayProfile
)
if ($ContinueOnTechnicalFailure) {
    $signalArgs += "-ContinueOnTechnicalFailure"
}

if ($PrintCommandsOnly) {
    $plannedReports = if ($SkipCollection) {
        @($PreviousSignalReportPath)
    } else {
        @($PreviousSignalReportPath + @($signalReportPath))
    }
    [pscustomobject]@{
        generated_at = ([DateTime]::UtcNow.ToString("o"))
        diagnostic_only = $true
        artifact_root = $ArtifactRoot
        collection_command = if ($SkipCollection) { $null } else { "powershell " + (Format-Command -Parts ([string[]]$signalArgs)) }
        next_step = "After collection, extract replay_artifact_paths from signal reports, write aggregate-market-paths.txt, then run compare-pullback-profiles-aggregate.ps1."
        signal_report_paths = $plannedReports
        market_manifest_path = $marketManifestPath
        pullback_aggregate_path = $pullbackOutputPath
        pipeline_summary_path = $summaryPath
        dashboard_artifact_path = $dashboardArtifactPath
    } | ConvertTo-Json -Depth 30
    return
}

if (-not (Test-Path -LiteralPath $artifactRootFullPath)) {
    New-Item -ItemType Directory -Force -Path $artifactRootFullPath | Out-Null
}

if (-not $SkipCollection) {
    Invoke-PowerShellScript -Args ([string[]]$signalArgs)

    $signalReportFullPath = Resolve-RepoPath -Path $signalReportPath
    if (-not (Test-Path -LiteralPath $signalReportFullPath)) {
        throw "Signal aggregate report was not written: $signalReportFullPath"
    }
}

$signalReportPaths = if ($SkipCollection) {
    @($PreviousSignalReportPath)
} else {
    @($PreviousSignalReportPath + @($signalReportPath))
}
$marketPaths = @(Get-MarketArtifactPathsFromReports -ReportPaths ([string[]]$signalReportPaths))
if ($marketPaths.Count -eq 0) {
    throw "No pinned market artifacts found from signal reports; cannot run aggregate pullback comparison"
}

$marketManifestFullPath = Resolve-RepoPath -Path $marketManifestPath
$marketManifestParent = Split-Path -Parent $marketManifestFullPath
if ($marketManifestParent -and -not (Test-Path -LiteralPath $marketManifestParent)) {
    New-Item -ItemType Directory -Force -Path $marketManifestParent | Out-Null
}
$marketPaths | Set-Content -LiteralPath $marketManifestFullPath -Encoding UTF8

$marketCsv = $marketPaths -join ","
$pullbackArgs = @(
    "-NoProfile",
    "-ExecutionPolicy", "Bypass",
    "-File", $PullbackAggregateScript,
    "-DatabaseUrl", $DatabaseUrl,
    "-MarketArtifactPath", $marketCsv,
    "-OutputPath", $pullbackOutputPath,
    "-ArtifactDirectory", $pullbackArtifactDirectory,
    "-ReplayProfile", $ReplayProfile,
    "-PullbackPctCsv", (($PullbackPct | ForEach-Object { Format-Decimal $_ }) -join ",")
)
if ($SkipPreflight) {
    $pullbackArgs += "-SkipPreflight"
}

Invoke-PowerShellScript -Args ([string[]]$pullbackArgs)

$pullbackFullPath = Resolve-RepoPath -Path $pullbackOutputPath
if (-not (Test-Path -LiteralPath $pullbackFullPath)) {
    throw "Pullback aggregate artifact was not written: $pullbackFullPath"
}

$signalReports = @($signalReportPaths | ForEach-Object {
    $path = Resolve-RepoPath -Path $_
    Get-Content -Raw -LiteralPath $path | ConvertFrom-Json
})
$currentSignalReport = if ($SkipCollection) { $null } else { Get-Content -Raw -LiteralPath $signalReportFullPath | ConvertFrom-Json }
$pullbackAggregate = Get-Content -Raw -LiteralPath $pullbackFullPath | ConvertFrom-Json
$summary = [pscustomobject]@{
    generated_at = ([DateTime]::UtcNow.ToString("o"))
    diagnostic_only = $true
    artifact_root = $ArtifactRoot
    signal_report_path = $signalReportPath
    previous_signal_report_paths = @($PreviousSignalReportPath)
    entry_fill_analysis_path = $entryAnalysisPath
    market_manifest_path = $marketManifestPath
    market_artifact_paths = $marketPaths
    pullback_aggregate_path = $pullbackOutputPath
    status = [pscustomobject]@{
        signal_status = if ($SkipCollection) { "collection_skipped" } else { [string]$currentSignalReport.status }
        signal_windows_collected = [int](@($signalReports | ForEach-Object { [int]$_.signal_windows_collected } | Measure-Object -Sum).Sum)
        pullback_completed_comparisons = [int]$pullbackAggregate.completed_comparisons
        pullback_failed_comparisons = [int]$pullbackAggregate.failed_comparisons
        best_by_entry_fills = [string]$pullbackAggregate.best_by_entry_fills
        best_by_net_pnl = [string]$pullbackAggregate.best_by_net_pnl
        diagnostic_summary = [string]$pullbackAggregate.diagnostic_summary
    }
    profile_totals = @($pullbackAggregate.profile_totals)
}

$summaryFullPath = Resolve-RepoPath -Path $summaryPath
$dashboardFullPath = Resolve-RepoPath -Path $dashboardArtifactPath
Write-JsonFile -Value $summary -Path $summaryFullPath
Write-JsonFile -Value $summary -Path $dashboardFullPath

Write-Output "signal pullback pipeline summary written: $summaryFullPath"
Write-Output "dashboard artifact written: $dashboardFullPath"
Write-Output "market_manifest_path=$marketManifestFullPath"
Write-Output "pullback_aggregate_path=$pullbackFullPath"
Write-Output "signal_windows_collected=$($summary.status.signal_windows_collected) pullback_completed_comparisons=$($summary.status.pullback_completed_comparisons) best_by_entry_fills=$($summary.status.best_by_entry_fills) best_by_net_pnl=$($summary.status.best_by_net_pnl)"
