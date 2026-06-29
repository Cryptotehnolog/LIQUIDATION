param(
    [string]$DatabaseUrl = $env:DATABASE_URL,
    [string]$PrimarySource = "bybit",
    [int]$WindowMinutes = 120,
    [int]$BucketSeconds = 60,
    [int]$StaleAfterSeconds = 120,
    [string]$ArtifactPath = ".cache/source-usefulness/latest.json",
    [string]$AnalysisPath = ".cache/source-usefulness/signal-readiness.json",
    [string[]]$IncludedSources = @("bybit", "binance", "okx", "bitget", "gate"),
    [switch]$Json
)

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

if ([string]::IsNullOrWhiteSpace($DatabaseUrl)) {
    throw "DatabaseUrl is required. Pass -DatabaseUrl or set DATABASE_URL."
}

if (@($IncludedSources | Where-Object { $_ -eq "htx" }).Count -gt 0) {
    throw "HTX is intentionally excluded from the current-source signal-readiness report."
}

$sourceUsefulnessScript = Join-Path $PSScriptRoot "source-usefulness-report.ps1"
$analyzerScript = Join-Path $PSScriptRoot "analyze-source-signal-readiness.ps1"

$sourceUsefulnessOutput = & $sourceUsefulnessScript `
    -DatabaseUrl $DatabaseUrl `
    -PrimarySource $PrimarySource `
    -WindowMinutes $WindowMinutes `
    -BucketSeconds $BucketSeconds `
    -StaleAfterSeconds $StaleAfterSeconds `
    -ArtifactPath $ArtifactPath

if (-not $Json) {
    $sourceUsefulnessOutput | Write-Output
}

& $analyzerScript `
    -SourceUsefulnessArtifactPath $ArtifactPath `
    -OutputPath $AnalysisPath `
    -IncludedSources $IncludedSources `
    -Json:$Json
