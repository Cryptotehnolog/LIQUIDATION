param(
    [ValidateSet("Auto", "Live", "Fixture")]
    [string]$Mode = "Auto",

    [int]$Port = 18080,

    [string]$BindHost = "127.0.0.1",

    [int]$WindowMinutes = 60,

    [int]$PollSeconds = 5,

    [string]$FixturePath = "tests/fixtures/dashboard/collector-status-edge-cases.json",

    [string]$ReplayArtifactPath = ".cache/replay/latest-polymarket-baseline.json",

    [string]$PolymarketMarketArtifactPath = ".cache/replay/latest-polymarket-market.json",

    [int]$PolymarketMarketStaleAfterMinutes = 15,

    [string]$DatabaseUrl = $env:DATABASE_URL,

    [switch]$OpenBrowser,

    [switch]$PrintCommandOnly
)

$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent $PSScriptRoot
$FixtureFullPath = Join-Path $RepoRoot $FixturePath
$Bind = "${BindHost}:$Port"
$Url = "http://$Bind"

if ($Port -lt 1 -or $Port -gt 65535) {
    throw "Port must be between 1 and 65535, got $Port"
}

if ($WindowMinutes -lt 1) {
    throw "WindowMinutes must be at least 1"
}

if ($PollSeconds -lt 1) {
    throw "PollSeconds must be at least 1"
}

$SelectedMode = $Mode
if ($SelectedMode -eq "Auto") {
    if ([string]::IsNullOrWhiteSpace($DatabaseUrl)) {
        $SelectedMode = "Fixture"
    } else {
        $SelectedMode = "Live"
    }
}

$Args = @(
    "run", "-p", "liq-cli", "--",
    "collector", "dashboard",
    "--bind", $Bind,
    "--window-minutes", [string]$WindowMinutes,
    "--poll-seconds", [string]$PollSeconds,
    "--replay-artifact-path", (Join-Path $RepoRoot $ReplayArtifactPath),
    "--polymarket-market-artifact-path", (Join-Path $RepoRoot $PolymarketMarketArtifactPath),
    "--polymarket-market-stale-after-minutes", [string]$PolymarketMarketStaleAfterMinutes
)

if ($SelectedMode -eq "Live") {
    if ([string]::IsNullOrWhiteSpace($DatabaseUrl)) {
        throw "Live dashboard requires DatabaseUrl or DATABASE_URL. Use -Mode Fixture for fixture data."
    }
    $Args += @("--database-url", $DatabaseUrl)
} elseif ($SelectedMode -eq "Fixture") {
    if (-not (Test-Path $FixtureFullPath)) {
        throw "Dashboard fixture not found: $FixtureFullPath"
    }
    $Args += @("--fixture-path", $FixtureFullPath)
} else {
    throw "Unsupported dashboard mode: $SelectedMode"
}

$CommandText = "cargo " + (($Args | ForEach-Object {
            if ($_ -match "\s") { '"' + ($_ -replace '"', '\"') + '"' } else { $_ }
        }) -join " ")

Write-Host "Dashboard mode: $SelectedMode"
Write-Host "Dashboard URL:  $Url"
Write-Host "Command:        $CommandText"

if ($PrintCommandOnly) {
    return
}

if ($OpenBrowser) {
    Start-Process $Url | Out-Null
}

Push-Location $RepoRoot
try {
    & cargo @Args
    exit $LASTEXITCODE
} finally {
    Pop-Location
}
