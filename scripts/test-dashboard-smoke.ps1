param(
    [int]$Port = 18080,
    [string]$FixturePath = "tests/fixtures/dashboard/collector-status-edge-cases.json",
    [switch]$InstallBrowser
)

$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent $PSScriptRoot
$FixtureFullPath = Join-Path $RepoRoot $FixturePath
$OutLog = Join-Path $RepoRoot ".cache/dashboard-smoke.out.log"
$ErrLog = Join-Path $RepoRoot ".cache/dashboard-smoke.err.log"
$ScreenshotDir = Join-Path $RepoRoot ".cache/dashboard-smoke"
$DashboardUrl = "http://127.0.0.1:$Port"

if (-not (Test-Path $FixtureFullPath)) {
    throw "Dashboard fixture not found: $FixtureFullPath"
}

New-Item -ItemType Directory -Force -Path (Join-Path $RepoRoot ".cache") | Out-Null
New-Item -ItemType Directory -Force -Path $ScreenshotDir | Out-Null
Remove-Item -Force -ErrorAction SilentlyContinue $OutLog, $ErrLog
Remove-Item -Force -ErrorAction SilentlyContinue (Join-Path $ScreenshotDir "*.png")

Push-Location $RepoRoot
try {
    cargo build -p liq-cli
    if ($LASTEXITCODE -ne 0) {
        throw "Dashboard binary build failed with exit code $LASTEXITCODE"
    }
} finally {
    Pop-Location
}

$Args = @(
    "run", "-p", "liq-cli", "--",
    "collector", "dashboard",
    "--bind", "127.0.0.1:$Port",
    "--fixture-path", $FixtureFullPath,
    "--poll-seconds", "1"
)

$DashboardJob = Start-Job -ScriptBlock {
    param($RepoRoot, $CargoArgs, $OutLog, $ErrLog)
    Set-Location $RepoRoot
    & cargo @CargoArgs > $OutLog 2> $ErrLog
} -ArgumentList $RepoRoot, $Args, $OutLog, $ErrLog

try {
    $Ready = $false
    for ($i = 0; $i -lt 60; $i++) {
        if ($DashboardJob.State -ne "Running") {
            $stderr = if (Test-Path $ErrLog) { Get-Content $ErrLog -Raw } else { "" }
            throw "Dashboard process exited before readiness. stderr: $stderr"
        }
        try {
            Invoke-RestMethod -Uri "$DashboardUrl/api/collector/status" -TimeoutSec 2 | Out-Null
            $Ready = $true
            break
        } catch {
            Start-Sleep -Milliseconds 500
        }
    }
    if (-not $Ready) {
        throw "Dashboard did not become ready at $DashboardUrl"
    }

    $env:DASHBOARD_URL = $DashboardUrl
    $env:DASHBOARD_SCREENSHOT_DIR = $ScreenshotDir
    if (-not (Test-Path (Join-Path $RepoRoot "node_modules/@playwright/test"))) {
        npm.cmd install
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    }
    if ($InstallBrowser) {
        npx.cmd playwright install chromium
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    }
    npm.cmd run test:dashboard
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
} finally {
    if ($DashboardJob) {
        Stop-Job -Job $DashboardJob -ErrorAction SilentlyContinue
        Remove-Job -Job $DashboardJob -Force -ErrorAction SilentlyContinue
    }
}
