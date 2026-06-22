param(
    [string]$DatabaseUrl = $env:DATABASE_URL,
    [string]$ReportDir = ".cache\nightly-market-data",
    [string]$BybitSymbol = "BTCUSDT",
    [string]$OkxSymbol = "BTC-USDT-SWAP",
    [int]$RuntimeSeconds = 30,
    [int]$HealthIntervalSeconds = 5,
    [int]$WindowMinutes = 60,
    [int]$BucketSeconds = 60
)

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

if ([string]::IsNullOrWhiteSpace($DatabaseUrl)) {
    throw "DatabaseUrl or DATABASE_URL is required"
}

function Resolve-RepoPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    if ([IO.Path]::IsPathRooted($Path)) {
        return $Path
    }

    return Join-Path $repoRoot $Path
}

function Invoke-LoggedCommand {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$LogPath,
        [Parameter(Mandatory = $true)][string[]]$Command
    )

    "## $Name" | Tee-Object -FilePath $LogPath
    "+ $($Command -join ' ')" | Tee-Object -FilePath $LogPath -Append
    $result = Invoke-CapturedCommand -Command $Command
    if (-not [string]::IsNullOrWhiteSpace($result.Stdout)) {
        $result.Stdout | Tee-Object -FilePath $LogPath -Append
    }
    if (-not [string]::IsNullOrWhiteSpace($result.Stderr)) {
        $result.Stderr | Tee-Object -FilePath $LogPath -Append
    }
    if ($result.ExitCode -ne 0) {
        throw "$Name failed with exit code $($result.ExitCode)"
    }
}

function Invoke-CapturedCommand {
    param([Parameter(Mandatory = $true)][string[]]$Command)

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $Command[0]
    if ($Command.Count -gt 1) {
        $startInfo.Arguments = (($Command[1..($Command.Count - 1)] | ForEach-Object { ConvertTo-ProcessArgument $_ }) -join " ")
    } else {
        $startInfo.Arguments = ""
    }
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    [void]$process.Start()
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()

    return [pscustomobject]@{
        ExitCode = $process.ExitCode
        Stdout = $stdout
        Stderr = $stderr
    }
}

function ConvertTo-ProcessArgument {
    param([Parameter(Mandatory = $true)][string]$Argument)

    if ($Argument -notmatch '[\s"]') {
        return $Argument
    }

    return '"' + ($Argument -replace '\\(?=\\*")', '$0$0' -replace '"', '\"') + '"'
}

$resolvedReportDir = Resolve-RepoPath $ReportDir
New-Item -ItemType Directory -Force -Path $resolvedReportDir *> $null

$okxInstrumentsPath = Join-Path $resolvedReportDir "okx-instruments-$OkxSymbol.json"
$runLogPath = Join-Path $resolvedReportDir "nightly-run.log"
$statusPath = Join-Path $resolvedReportDir "collector-status.json"
$overlapPath = Join-Path $resolvedReportDir "overlap-report.json"
$summaryPath = Join-Path $resolvedReportDir "summary.md"
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

$fetchOkxScript = Join-Path $PSScriptRoot "fetch-okx-instruments.ps1"
& $fetchOkxScript `
    -Symbol $OkxSymbol `
    -OutputPath $okxInstrumentsPath | Tee-Object -FilePath $runLogPath

$env:DATABASE_URL = $DatabaseUrl

Invoke-LoggedCommand `
    -Name "database migrate" `
    -LogPath $runLogPath `
    -Command @("cargo", "run", "-p", "liq-cli", "--", "db", "migrate", "--database-url", $DatabaseUrl)

Invoke-LoggedCommand `
    -Name "bounded bybit collector" `
    -LogPath $runLogPath `
    -Command @(
        "cargo", "run", "-p", "liq-cli", "--",
        "collector", "run",
        "--database-url", $DatabaseUrl,
        "--source", "bybit",
        "--symbol", $BybitSymbol,
        "--max-runtime-seconds", "$RuntimeSeconds",
        "--health-interval-seconds", "$HealthIntervalSeconds",
        "--read-timeout-seconds", "10",
        "--batch-flush-interval-seconds", "1"
    )

Invoke-LoggedCommand `
    -Name "bounded okx collector" `
    -LogPath $runLogPath `
    -Command @(
        "cargo", "run", "-p", "liq-cli", "--",
        "collector", "run",
        "--database-url", $DatabaseUrl,
        "--source", "okx",
        "--symbol", $OkxSymbol,
        "--okx-instruments-path", $okxInstrumentsPath,
        "--max-runtime-seconds", "$RuntimeSeconds",
        "--health-interval-seconds", "$HealthIntervalSeconds",
        "--read-timeout-seconds", "10",
        "--batch-flush-interval-seconds", "1"
    )

$statusResult = Invoke-CapturedCommand -Command @(
    "cargo", "run", "-p", "liq-cli", "--",
    "collector", "status",
    "--database-url", $DatabaseUrl,
    "--json",
    "--window-minutes", "$WindowMinutes"
)
if ($statusResult.ExitCode -ne 0) {
    $statusResult.Stderr | Tee-Object -FilePath $runLogPath -Append
    throw "collector status snapshot failed"
}
$statusResult.Stderr | Tee-Object -FilePath $runLogPath -Append
[IO.File]::WriteAllText($statusPath, $statusResult.Stdout, $utf8NoBom)

$overlapResult = Invoke-CapturedCommand -Command @(
    "cargo", "run", "-p", "liq-cli", "--",
    "collector", "overlap-report",
    "--database-url", $DatabaseUrl,
    "--primary-source", "bybit",
    "--diagnostic-source", "okx",
    "--window-minutes", "$WindowMinutes",
    "--bucket-seconds", "$BucketSeconds"
)
if ($overlapResult.ExitCode -ne 0) {
    $overlapResult.Stderr | Tee-Object -FilePath $runLogPath -Append
    throw "collector overlap report failed"
}
$overlapResult.Stderr | Tee-Object -FilePath $runLogPath -Append
[IO.File]::WriteAllText($overlapPath, $overlapResult.Stdout, $utf8NoBom)

$status = Get-Content -Raw -LiteralPath $statusPath | ConvertFrom-Json
$overlap = Get-Content -Raw -LiteralPath $overlapPath | ConvertFrom-Json
$okx = @($status.sources | Where-Object { $_.source -eq "okx" }) | Select-Object -First 1
$bybit = @($status.sources | Where-Object { $_.source -eq "bybit" }) | Select-Object -First 1

$summary = @(
    "# Nightly Market Data Check",
    "",
    "- generated_at: $((Get-Date).ToUniversalTime().ToString("o"))",
    "- bybit_status: $($bybit.status)",
    "- okx_status: $($okx.status)",
    "- okx_metadata_valid: true",
    "- bybit_raw_events: $($overlap.primary.raw_events)",
    "- bybit_canonical_events: $($overlap.primary.canonical_events)",
    "- okx_raw_events: $($overlap.diagnostic.raw_events)",
    "- okx_canonical_events: $($overlap.diagnostic.canonical_events)",
    "- overlap_buckets: $($overlap.buckets.Count)",
    "",
    "OKX remains diagnostic-only. Zero OKX events in a bounded window is not a",
    "strategy failure; it means the window did not contain a liquidation payload."
)

[IO.File]::WriteAllText($summaryPath, ($summary -join "`n"), $utf8NoBom)

Write-Output (@{
    status = "ok"
    report_dir = $resolvedReportDir
    status_path = $statusPath
    overlap_path = $overlapPath
    summary_path = $summaryPath
} | ConvertTo-Json -Compress)
