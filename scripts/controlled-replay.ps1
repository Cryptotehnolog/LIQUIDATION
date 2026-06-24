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

if (-not $DatabaseUrl) {
    throw "DatabaseUrl or DATABASE_URL is required"
}
if ($MaxWindows -lt 1) {
    throw "MaxWindows must be at least 1"
}
if ($MaxRuntimeSeconds -lt 30) {
    throw "MaxRuntimeSeconds must be at least 30"
}

function Format-Command {
    param([Parameter(Mandatory = $true)][string[]]$Parts)

    ($Parts | ForEach-Object {
        if ($_ -match "\s") { '"' + ($_ -replace '"', '\"') + '"' } else { $_ }
    }) -join " "
}

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
    "-DelayBetweenWindowsSeconds", [string]$DelayBetweenWindowsSeconds
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
Write-Output ("replay command: powershell " + (Format-Command -Parts $waitArgs))
if (-not $SkipDashboard) {
    Write-Output ("dashboard command: powershell " + (Format-Command -Parts $dashboardArgs))
}

if ($PrintCommandsOnly) {
    return
}

Push-Location $RepoRoot
try {
    & powershell @waitArgs
    if ($LASTEXITCODE -ne 0) {
        throw "wait-for-liquidation-replay.ps1 failed with exit code $LASTEXITCODE"
    }

    if (-not (Test-Path -LiteralPath $ReplayArtifactFullPath)) {
        throw "Expected replay artifact was not written: $ReplayArtifactFullPath"
    }
    if (-not (Test-Path -LiteralPath $MarketArtifactFullPath)) {
        throw "Expected Polymarket market artifact was not written: $MarketArtifactFullPath"
    }

    Write-Output "controlled replay artifact: $ReplayArtifactFullPath"
    Write-Output "polymarket market artifact: $MarketArtifactFullPath"

    if ($SkipDashboard) {
        return
    }

    Write-Output "starting read-only dashboard..."
    & powershell @dashboardArgs
    exit $LASTEXITCODE
} finally {
    Pop-Location
}
