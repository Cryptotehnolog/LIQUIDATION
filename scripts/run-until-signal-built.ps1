param(
    [string]$DatabaseUrl = $env:DATABASE_URL,
    [string]$ArtifactRoot = ".cache/replay",
    [string]$OkxInstrumentsPath = ".cache/okx/instruments-BTC-USDT-SWAP.json",
    [int]$MaxTotalRuntimeSeconds = 7200,
    [int]$MaxAttempts = 48,
    [int]$MaxWindowsPerAttempt = 1,
    [int]$MaxRuntimeSeconds = 260,
    [int]$MaxWaitForFreshWindowSeconds = 180,
    [int]$AttemptTimeoutBufferSeconds = 120,
    [int]$DelayBetweenAttemptsSeconds = 5,
    [string]$ReplayProfile = "baseline",
    [switch]$PrintCommandsOnly
)

$ErrorActionPreference = "Stop"

$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$BatchScript = Join-Path $PSScriptRoot "run-entry-fill-diagnostics-batch.ps1"

if (-not $DatabaseUrl) {
    throw "DatabaseUrl or DATABASE_URL is required"
}
if ($MaxTotalRuntimeSeconds -lt 60) {
    throw "MaxTotalRuntimeSeconds must be at least 60"
}
if ($MaxAttempts -lt 1) {
    throw "MaxAttempts must be at least 1"
}

$RunId = Get-Date -Format 'yyyyMMdd-HHmmss'
$RunPrefix = Join-Path $ArtifactRoot "until-signal-built-$RunId"
$ArtifactDirectory = $RunPrefix
$OutputPath = "$RunPrefix-report.json"
$AggregateReportPath = "$RunPrefix-aggregate.json"
$TradePathAnalysisPath = "$RunPrefix-trade-path-analysis.json"
$EntryFillAnalysisPath = "$RunPrefix-entry-analysis.json"

$batchArgs = @(
    "-NoProfile",
    "-ExecutionPolicy", "Bypass",
    "-File", $BatchScript,
    "-DatabaseUrl", $DatabaseUrl,
    "-ArtifactDirectory", $ArtifactDirectory,
    "-OutputPath", $OutputPath,
    "-AggregateReportPath", $AggregateReportPath,
    "-TradePathAnalysisPath", $TradePathAnalysisPath,
    "-EntryFillAnalysisPath", $EntryFillAnalysisPath,
    "-OkxInstrumentsPath", $OkxInstrumentsPath,
    "-MaxAttempts", [string]$MaxAttempts,
    "-MaxWindowsPerAttempt", [string]$MaxWindowsPerAttempt,
    "-MaxRuntimeSeconds", [string]$MaxRuntimeSeconds,
    "-MaxWaitForFreshWindowSeconds", [string]$MaxWaitForFreshWindowSeconds,
    "-MaxTotalRuntimeSeconds", [string]$MaxTotalRuntimeSeconds,
    "-AttemptTimeoutBufferSeconds", [string]$AttemptTimeoutBufferSeconds,
    "-DelayBetweenAttemptsSeconds", [string]$DelayBetweenAttemptsSeconds,
    "-ReplayProfile", $ReplayProfile,
    "-UntilSignalBuilt"
)

if ($PrintCommandsOnly) {
    $batchArgs += "-PrintCommandsOnly"
}

& powershell @batchArgs
$exitCode = $LASTEXITCODE
if ($exitCode -ne 0) {
    throw "run-entry-fill-diagnostics-batch.ps1 failed with exit code $exitCode"
}
