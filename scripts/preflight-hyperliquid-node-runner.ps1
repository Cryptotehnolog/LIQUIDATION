param(
    [string]$OutputDir = ".cache/hyperliquid-node-output",
    [string]$JsonOutputPath = "",
    [string]$NodeExecutable = "",
    [string[]]$NodeArgs = @("run-non-validator"),
    [int]$MaxRuntimeSeconds = 60,
    [long]$MaxBytes = 52428800,
    [string]$WslDistro = "Ubuntu"
)

$ErrorActionPreference = "Stop"

if ($MaxRuntimeSeconds -lt 1) {
    throw "MaxRuntimeSeconds must be positive."
}
if ($MaxBytes -lt 1024) {
    throw "MaxBytes must be at least 1024 bytes."
}

$RepoRoot = Split-Path -Parent $PSScriptRoot
$OutputFullPath = [System.IO.Path]::GetFullPath((Join-Path $RepoRoot $OutputDir))
New-Item -ItemType Directory -Force -Path $OutputFullPath | Out-Null

if ([string]::IsNullOrWhiteSpace($JsonOutputPath)) {
    $JsonOutputPath = Join-Path $OutputFullPath "hyperliquid-node-runner-preflight.json"
} elseif (-not [System.IO.Path]::IsPathRooted($JsonOutputPath)) {
    $JsonOutputPath = Join-Path $RepoRoot $JsonOutputPath
}
$JsonFullPath = [System.IO.Path]::GetFullPath($JsonOutputPath)

$ProbeScript = Join-Path $PSScriptRoot "probe-hyperliquid-node-output.ps1"
if (-not (Test-Path -LiteralPath $ProbeScript)) {
    throw "Missing probe script: $ProbeScript"
}

function Invoke-OptionalCommand {
    param([Parameter(Mandatory = $true)][scriptblock]$Command)

    try {
        $output = & $Command 2>&1
        return [ordered]@{
            ok = $true
            output = @($output | ForEach-Object { [string]$_ })
        }
    } catch {
        return [ordered]@{
            ok = $false
            output = @([string]$_.Exception.Message)
        }
    }
}

function Get-CommandPathOrNull {
    param([Parameter(Mandatory = $true)][string]$Name)

    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if ($null -eq $command) {
        return $null
    }
    return $command.Source
}

function ConvertTo-WslMountPathOrNull {
    param([Parameter(Mandatory = $true)][string]$WindowsPath)

    $fullPath = [System.IO.Path]::GetFullPath($WindowsPath)
    if ($fullPath -notmatch '^([A-Za-z]):\\(.*)$') {
        return $null
    }

    $drive = $Matches[1].ToLowerInvariant()
    $rest = $Matches[2] -replace '\\', '/'
    return "/mnt/$drive/$rest"
}

$mandatoryFlags = @(
    "--write-fills",
    "--write-misc-events",
    "--batch-by-block",
    "--stream-with-block-info",
    "--disable-output-file-buffering"
)

$wslCommand = Get-CommandPathOrNull -Name "wsl.exe"
$dockerCommand = Get-CommandPathOrNull -Name "docker.exe"

$wslStatus = $null
$wslOsRelease = $null
$wslRunnerCheck = $null
if ($wslCommand) {
    $wslStatus = Invoke-OptionalCommand { & wsl.exe -l -v }
    $wslOsRelease = Invoke-OptionalCommand {
        if ([string]::IsNullOrWhiteSpace($WslDistro)) {
            & wsl.exe -- bash -lc "cat /etc/os-release | sed -n '1,8p'"
        } else {
            & wsl.exe -d $WslDistro -- bash -lc "cat /etc/os-release | sed -n '1,8p'"
        }
    }
    $wslRunnerCheck = Invoke-OptionalCommand {
        if ([string]::IsNullOrWhiteSpace($WslDistro)) {
            & wsl.exe -- bash -lc "command -v hl-visor || test -x ~/hl-visor && echo ~/hl-visor || true"
        } else {
            & wsl.exe -d $WslDistro -- bash -lc "command -v hl-visor || test -x ~/hl-visor && echo ~/hl-visor || true"
        }
    }
}

$nativeRunnerExists = $false
$nativeRunnerPath = $null
if (-not [string]::IsNullOrWhiteSpace($NodeExecutable)) {
    if (Test-Path -LiteralPath $NodeExecutable) {
        $nativeRunnerExists = $true
        $nativeRunnerPath = [System.IO.Path]::GetFullPath($NodeExecutable)
    } else {
        $command = Get-Command $NodeExecutable -ErrorAction SilentlyContinue
        if ($null -ne $command) {
            $nativeRunnerExists = $true
            $nativeRunnerPath = $command.Source
        }
    }
}

$dryRunReportPath = Join-Path $OutputFullPath "hyperliquid-node-output-dry-run.json"
$dryRunArgs = @(
    "-NoProfile",
    "-ExecutionPolicy",
    "Bypass",
    "-File",
    $ProbeScript,
    "-OutputDir",
    $OutputDir,
    "-JsonOutputPath",
    $dryRunReportPath,
    "-NodeArgs"
) + $NodeArgs + @(
    "-MaxRuntimeSeconds",
    $MaxRuntimeSeconds,
    "-MaxBytes",
    $MaxBytes
)
if (-not [string]::IsNullOrWhiteSpace($NodeExecutable)) {
    $dryRunArgs += @("-NodeExecutable", $NodeExecutable)
}

$dryRunOutput = Invoke-OptionalCommand {
    & powershell @dryRunArgs
}

$wslRunnerCandidates = @()
if ($wslRunnerCheck -and $wslRunnerCheck.ok) {
    $wslRunnerCandidates = @($wslRunnerCheck.output | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_)
    })
}

$ubuntu24Detected = $false
if ($wslOsRelease -and $wslOsRelease.ok) {
    $ubuntu24Detected = (@($wslOsRelease.output) -join "`n") -match 'VERSION_ID="?24\.04"?'
}

$runnerAvailable = $nativeRunnerExists -or ($wslRunnerCandidates.Count -gt 0)
$readyForBoundedRun = $runnerAvailable -and ($ubuntu24Detected -or $nativeRunnerExists) -and $dryRunOutput.ok

$warnings = New-Object 'System.Collections.Generic.List[string]'
$warnings.Add("Official Hyperliquid node docs require Ubuntu 24.04 and warn that default node output can be about 100 GB/day.")
$warnings.Add("Official machine specs for a non-validator are far above a normal laptop: 16 vCPU, 128 GB RAM, 500 GB SSD.")
$warnings.Add("This preflight is research-only. It must not be treated as production collector readiness.")
if (-not $runnerAvailable) {
    $warnings.Add("No hl-visor/native NodeExecutable was found. Do not run -Run until a verified runner path exists.")
}
if ($wslCommand -and -not $ubuntu24Detected) {
    $warnings.Add("WSL exists, but Ubuntu 24.04 was not confirmed for the selected distro.")
}
if (-not $dryRunOutput.ok) {
    $warnings.Add("Dry-run probe failed; inspect dry_run.output before any real run.")
}

$wslOutputPath = ConvertTo-WslMountPathOrNull -WindowsPath $OutputFullPath

$report = [ordered]@{
    generated_at = (Get-Date).ToUniversalTime().ToString("o")
    mode = "preflight"
    status = if ($readyForBoundedRun) { "ready-for-bounded-run" } else { "not-ready-for-run" }
    ready_for_bounded_run = [bool]$readyForBoundedRun
    limits = [ordered]@{
        max_runtime_seconds = $MaxRuntimeSeconds
        max_bytes = $MaxBytes
    }
    output_dir = $OutputFullPath
    wsl_output_dir = $wslOutputPath
    required_node_flags = $mandatoryFlags
    native = [ordered]@{
        node_executable_requested = $NodeExecutable
        node_executable_found = $nativeRunnerExists
        node_executable_path = $nativeRunnerPath
    }
    wsl = [ordered]@{
        available = [bool]$wslCommand
        command_path = $wslCommand
        distro = $WslDistro
        ubuntu_24_04_confirmed = [bool]$ubuntu24Detected
        runner_candidates = $wslRunnerCandidates
        status = $wslStatus
        os_release = $wslOsRelease
    }
    docker = [ordered]@{
        available = [bool]$dockerCommand
        command_path = $dockerCommand
        note = "Docker is not used by the Hyperliquid node-output probe; this avoids touching other project containers."
    }
    dry_run = [ordered]@{
        ok = [bool]$dryRunOutput.ok
        report_path = $dryRunReportPath
        output_tail = @($dryRunOutput.output | Select-Object -Last 20)
    }
    next_safe_command = if ($readyForBoundedRun -and $nativeRunnerExists) {
        "powershell -NoProfile -ExecutionPolicy Bypass -File scripts\probe-hyperliquid-node-output.ps1 -Run -NodeExecutable `"$nativeRunnerPath`" -MaxRuntimeSeconds $MaxRuntimeSeconds -MaxBytes $MaxBytes -KeepRaw"
    } elseif ($readyForBoundedRun -and $wslRunnerCandidates.Count -gt 0) {
        "Manual WSL run is possible only after wrapping HOME to $wslOutputPath/home; do not run without bounded supervision."
    } else {
        "Install/verify hl-visor in an isolated Ubuntu 24.04 environment first, then rerun this preflight."
    }
    warnings = @($warnings)
}

$report | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $JsonFullPath -Encoding UTF8
$report | ConvertTo-Json -Depth 30
Write-Output "Hyperliquid node runner preflight written to $JsonFullPath"
