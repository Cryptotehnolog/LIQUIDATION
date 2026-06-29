$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent $PSScriptRoot
$FixtureRoot = Join-Path $RepoRoot ".cache\test-hyperliquid-node-runner-preflight"
$ReportPath = Join-Path $FixtureRoot "preflight.json"

if (Test-Path -LiteralPath $FixtureRoot) {
    Remove-Item -LiteralPath $FixtureRoot -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $FixtureRoot | Out-Null

$output = & (Join-Path $PSScriptRoot "preflight-hyperliquid-node-runner.ps1") `
    -OutputDir ".cache\test-hyperliquid-node-runner-preflight" `
    -JsonOutputPath $ReportPath `
    -NodeExecutable "definitely-missing-hl-visor-for-test" `
    -MaxRuntimeSeconds 60 `
    -MaxBytes 52428800

$report = Get-Content -Raw -LiteralPath $ReportPath | ConvertFrom-Json

if ($report.mode -ne "preflight") {
    throw "Expected preflight mode, got $($report.mode)"
}
if ($report.status -ne "not-ready-for-run") {
    throw "Expected not-ready-for-run status for missing runner, got $($report.status)"
}
if ($report.ready_for_bounded_run) {
    throw "Expected ready_for_bounded_run=false for missing runner"
}
if ($report.limits.max_runtime_seconds -ne 60) {
    throw "Expected max_runtime_seconds 60, got $($report.limits.max_runtime_seconds)"
}
if ($report.limits.max_bytes -ne 52428800) {
    throw "Expected max_bytes 52428800, got $($report.limits.max_bytes)"
}
if (-not ($report.required_node_flags -contains "--write-fills")) {
    throw "Expected --write-fills in required_node_flags"
}
if (-not ($report.required_node_flags -contains "--write-misc-events")) {
    throw "Expected --write-misc-events in required_node_flags"
}
if (-not $report.dry_run.ok) {
    throw "Expected nested dry-run probe to pass"
}
if (-not (Test-Path -LiteralPath $report.dry_run.report_path)) {
    throw "Expected nested dry-run report file to exist"
}
if (-not (($report.warnings -join "`n") -match "No hl-visor")) {
    throw "Expected missing hl-visor warning"
}

Write-Output "hyperliquid node-runner preflight test passed"
