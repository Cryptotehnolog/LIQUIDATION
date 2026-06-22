param(
    [int]$Port = 18080,
    [string]$FixturePath = "tests/fixtures/dashboard/collector-status-edge-cases.json"
)

$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent $PSScriptRoot
$FixtureFullPath = Join-Path $RepoRoot $FixturePath
$OutLog = Join-Path $RepoRoot ".cache/dashboard-smoke.out.log"
$ErrLog = Join-Path $RepoRoot ".cache/dashboard-smoke.err.log"
$DashboardUrl = "http://127.0.0.1:$Port"

if (-not (Test-Path $FixtureFullPath)) {
    throw "Dashboard fixture not found: $FixtureFullPath"
}

New-Item -ItemType Directory -Force -Path (Join-Path $RepoRoot ".cache") | Out-Null
Remove-Item -Force -ErrorAction SilentlyContinue $OutLog, $ErrLog

$Args = @(
    "run", "-p", "liq-cli", "--",
    "collector", "dashboard",
    "--bind", "127.0.0.1:$Port",
    "--fixture-path", $FixtureFullPath,
    "--poll-seconds", "1"
)

$Process = Start-Process -FilePath "cargo" `
    -ArgumentList $Args `
    -WorkingDirectory $RepoRoot `
    -RedirectStandardOutput $OutLog `
    -RedirectStandardError $ErrLog `
    -WindowStyle Hidden `
    -PassThru

try {
    $Ready = $false
    for ($i = 0; $i -lt 60; $i++) {
        if ($Process.HasExited) {
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
    if (-not (Test-Path (Join-Path $RepoRoot "node_modules/@playwright/test"))) {
        npm install
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    }
    npx playwright install chromium
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    npm run test:dashboard
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
} finally {
    if ($Process -and -not $Process.HasExited) {
        Stop-Process -Id $Process.Id -Force
    }
}
