param(
    [int]$Top = 15,
    [switch]$SkipDocker
)

$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent $PSScriptRoot

Write-Host "== Current CPU by process =="
Get-CimInstance Win32_PerfFormattedData_PerfProc_Process |
    Where-Object { $_.Name -notin @("_Total", "Idle") } |
    Sort-Object PercentProcessorTime -Descending |
    Select-Object -First $Top Name, IDProcess, PercentProcessorTime, WorkingSet |
    Format-Table -AutoSize

Write-Host ""
Write-Host "== Project-related processes =="
Get-Process -ErrorAction SilentlyContinue |
    Where-Object { $_.ProcessName -match "cargo|rustc|link|liq|node|playwright|chromium|msedge|powershell|codex|Docker|com.docker|MsMpEng" } |
    Sort-Object CPU -Descending |
    Select-Object -First ($Top * 2) Id, ProcessName, CPU, WorkingSet64, Path |
    Format-Table -AutoSize

Write-Host ""
Write-Host "== LIQUIDATION ports =="
$ports = @(15433, 18080, 18081, 18082, 19655, 23000, 28000, 28001, 21128)
$listeners = Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
    Where-Object { $_.LocalPort -in $ports } |
    Select-Object LocalAddress, LocalPort, OwningProcess |
    Sort-Object LocalPort
if ($listeners) {
    $listeners | Format-Table -AutoSize
} else {
    Write-Host "No LIQUIDATION dashboard/RAG listeners found."
}

Write-Host ""
Write-Host "== Project artifact sizes =="
$artifactRows = @()
foreach ($name in @("target", "node_modules", ".cache")) {
    $path = Join-Path $RepoRoot $name
    if (Test-Path $path) {
        $size = (Get-ChildItem -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue |
            Measure-Object Length -Sum).Sum
        $artifactRows += [pscustomobject]@{
            path = $path
            size_mb = [math]::Round($size / 1MB, 1)
        }
    }
}
if ($artifactRows) {
    $artifactRows | Format-Table -AutoSize
} else {
    Write-Host "No project build artifacts found."
}

if (-not $SkipDocker) {
    Write-Host ""
    Write-Host "== Docker container CPU snapshot =="
    try {
        docker stats --no-stream --format "table {{.Name}}`t{{.CPUPerc}}`t{{.MemUsage}}`t{{.BlockIO}}"
    } catch {
        Write-Host "Docker stats unavailable: $($_.Exception.Message)"
    }
}

Write-Host ""
Write-Host "== Notes =="
Write-Host "High MsMpEng usually means Windows Defender is scanning build artifacts."
Write-Host "Do not stop Docker containers from this script; it is read-only."
