$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent $PSScriptRoot
$ScriptPath = Join-Path $RepoRoot "scripts/start-dashboard.ps1"

function Assert-Contains {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Expected,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $Text.Contains($Expected)) {
        throw "$Message. Expected to find '$Expected' in: $Text"
    }
}

Push-Location $RepoRoot
try {
    $env:DATABASE_URL = ""
    $fixtureOutput = & powershell -NoProfile -ExecutionPolicy Bypass -File $ScriptPath -PrintCommandOnly
    if ($LASTEXITCODE -ne 0) {
        throw "Auto fixture command failed with exit code $LASTEXITCODE"
    }
    $fixtureText = $fixtureOutput -join "`n"
    Assert-Contains $fixtureText "Dashboard mode: Fixture" "Auto mode without DATABASE_URL must choose fixture"
    Assert-Contains $fixtureText "--fixture-path" "Fixture command must include fixture path"

    $env:DATABASE_URL = "postgres://liquidation:liquidation@127.0.0.1:15433/liquidation"
    $liveOutput = & powershell -NoProfile -ExecutionPolicy Bypass -File $ScriptPath -PrintCommandOnly
    if ($LASTEXITCODE -ne 0) {
        throw "Auto live command failed with exit code $LASTEXITCODE"
    }
    $liveText = $liveOutput -join "`n"
    Assert-Contains $liveText "Dashboard mode: Live" "Auto mode with DATABASE_URL must choose live"
    Assert-Contains $liveText "--database-url" "Live command must include database URL"

    $env:DATABASE_URL = ""
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $failedOutput = & powershell -NoProfile -ExecutionPolicy Bypass -File $ScriptPath -Mode Live -PrintCommandOnly 2>&1
    $ErrorActionPreference = $previousErrorActionPreference
    if ($LASTEXITCODE -eq 0) {
        throw "Live mode without DATABASE_URL must fail"
    }
    $failedText = $failedOutput -join "`n"
    Assert-Contains $failedText "Live dashboard requires DatabaseUrl or DATABASE_URL" "Live mode failure must be actionable"

    Write-Host "start-dashboard script checks passed"
} finally {
    Pop-Location
}
