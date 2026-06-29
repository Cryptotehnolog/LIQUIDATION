param(
    [string]$OutputDir = ".cache/hyperliquid-node-output",
    [string]$ExistingDataPath = "",
    [string]$JsonOutputPath = "",
    [string]$NodeExecutable = "",
    [string[]]$NodeArgs = @("run-non-validator"),
    [int]$MaxRuntimeSeconds = 60,
    [long]$MaxBytes = 52428800,
    [switch]$Run,
    [switch]$KeepRaw
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
    $JsonOutputPath = Join-Path $OutputFullPath "hyperliquid-node-output-probe.json"
} elseif (-not [System.IO.Path]::IsPathRooted($JsonOutputPath)) {
    $JsonOutputPath = Join-Path $RepoRoot $JsonOutputPath
}
$JsonFullPath = [System.IO.Path]::GetFullPath($JsonOutputPath)

$NodeHomePath = Join-Path $OutputFullPath "home"
$NodeDataPath = Join-Path $NodeHomePath "hl\data"

function Get-DirectorySizeBytes {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return 0
    }

    $sum = 0L
    Get-ChildItem -LiteralPath $Path -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
        $sum += $_.Length
    }
    return $sum
}

function Get-NumericValue {
    param($Value)

    if ($null -eq $Value) {
        return $null
    }

    try {
        return [decimal]::Parse(([string]$Value), [System.Globalization.CultureInfo]::InvariantCulture)
    } catch {
        return $null
    }
}

function Get-PropertyValue {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($null -eq $Object) {
        return $null
    }

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }
    return $property.Value
}

function ConvertTo-EventRecords {
    param($JsonObject)

    $events = Get-PropertyValue -Object $JsonObject -Name "events"
    if ($events -is [System.Array]) {
        foreach ($event in $events) {
            [pscustomobject][ordered]@{
                block_time = Get-PropertyValue -Object $JsonObject -Name "block_time"
                block_number = Get-PropertyValue -Object $JsonObject -Name "block_number"
                event = $event
            }
        }
        return
    }

    [pscustomobject][ordered]@{
        block_time = Get-PropertyValue -Object $JsonObject -Name "block_time"
        block_number = Get-PropertyValue -Object $JsonObject -Name "block_number"
        event = $JsonObject
    }
}

function Analyze-HyperliquidNodeData {
    param([Parameter(Mandatory = $true)][string]$DataPath)

    $files = @()
    foreach ($subdir in @("node_fills", "misc_events")) {
        $path = Join-Path $DataPath $subdir
        if (Test-Path -LiteralPath $path) {
            $files += @(Get-ChildItem -LiteralPath $path -Recurse -File)
        }
    }

    $lineCount = 0
    $jsonLineCount = 0
    $parseErrors = 0
    $recordsSeen = 0
    $fillRecords = 0
    $miscRecords = 0
    $fillLiquidationRecords = 0
    $miscLiquidationRecords = 0
    $liquidationMarkerRecords = 0
    $notionalCandidates = 0
    $maxNotionalUsd = [decimal]0
    $candidateIds = New-Object 'System.Collections.Generic.HashSet[string]'
    $largest = New-Object 'System.Collections.Generic.List[object]'

    foreach ($file in $files) {
        $normalizedFileName = $file.FullName -replace '\\', '/'
        $sourceKind = if ($normalizedFileName -like "*/node_fills/*") {
            "node_fills"
        } elseif ($normalizedFileName -like "*/misc_events/*") {
            "misc_events"
        } else {
            "unknown"
        }

        foreach ($line in [System.IO.File]::ReadLines($file.FullName)) {
            $trimmed = $line.Trim()
            if ([string]::IsNullOrWhiteSpace($trimmed)) {
                continue
            }
            $lineCount += 1

            try {
                $json = $trimmed | ConvertFrom-Json
                $jsonLineCount += 1
            } catch {
                $parseErrors += 1
                continue
            }

            foreach ($record in (ConvertTo-EventRecords -JsonObject $json)) {
                $recordsSeen += 1
                $event = $record.event
                $eventText = $event | ConvertTo-Json -Depth 50 -Compress
                $hasLiquidationText = ($eventText -match '(?i)liquidation')
                if ($hasLiquidationText) {
                    $liquidationMarkerRecords += 1
                }

                $notional = $null
                $candidateId = $null
                $coin = Get-PropertyValue -Object $event -Name "coin"
                $hash = Get-PropertyValue -Object $event -Name "hash"
                $tid = Get-PropertyValue -Object $event -Name "tid"
                if ([string]::IsNullOrWhiteSpace([string]$coin) -and $eventText -match '"coin"\s*:\s*"([^"]+)"') {
                    $coin = $Matches[1]
                }
                if ([string]::IsNullOrWhiteSpace([string]$hash) -and $eventText -match '"hash"\s*:\s*"([^"]+)"') {
                    $hash = $Matches[1]
                }
                if ([string]::IsNullOrWhiteSpace([string]$tid) -and $eventText -match '"tid"\s*:\s*"?([^",}]+)"?') {
                    $tid = $Matches[1]
                }

                if ($sourceKind -eq "node_fills") {
                    $fillRecords += 1
                    $liquidation = Get-PropertyValue -Object $event -Name "liquidation"
                    if ($null -ne $liquidation -or $eventText -match '"liquidation"\s*:') {
                        $fillLiquidationRecords += 1
                    }

                    $price = Get-NumericValue (Get-PropertyValue -Object $event -Name "px")
                    $size = Get-NumericValue (Get-PropertyValue -Object $event -Name "sz")
                    if ($null -eq $price -and $eventText -match '"px"\s*:\s*"?([0-9.]+)"?') {
                        $price = Get-NumericValue $Matches[1]
                    }
                    if ($null -eq $size -and $eventText -match '"sz"\s*:\s*"?([0-9.]+)"?') {
                        $size = Get-NumericValue $Matches[1]
                    }
                    if ($null -ne $price -and $null -ne $size) {
                        $notional = [Math]::Abs($price * $size)
                    }

                    $candidateId = @($hash, $tid, $coin) |
                        Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
                        ForEach-Object { [string]$_ }
                    if ($candidateId.Count -gt 0) {
                        $candidateId = "fill:" + ($candidateId -join ":")
                    }
                } elseif ($sourceKind -eq "misc_events") {
                    $miscRecords += 1
                    if ($hasLiquidationText) {
                        $miscLiquidationRecords += 1
                    }

                    if ($eventText -match '"liquidatedNtlPos"\s*:\s*"?([0-9.]+)"?') {
                        $notional = Get-NumericValue $Matches[1]
                    }

                    if (-not [string]::IsNullOrWhiteSpace([string]$hash)) {
                        $candidateId = "misc:$hash"
                    }
                }

                if (-not [string]::IsNullOrWhiteSpace([string]$candidateId)) {
                    [void]$candidateIds.Add([string]$candidateId)
                }

                if ($null -ne $notional) {
                    $notionalCandidates += 1
                    if ($notional -gt $maxNotionalUsd) {
                        $maxNotionalUsd = $notional
                    }
                    $largest.Add([ordered]@{
                        source_kind = $sourceKind
                        notional_usd = [double]$notional
                        coin = if ($coin) { [string]$coin } else { $null }
                        candidate_id = if ($candidateId) { [string]$candidateId } else { $null }
                        has_liquidation_marker = [bool]$hasLiquidationText
                    })
                }
            }
        }
    }

    $largestRows = @(
        $largest |
            Sort-Object -Property @{ Expression = { $_.notional_usd }; Descending = $true } |
            Select-Object -First 10
    )

    return [ordered]@{
        data_path = $DataPath
        file_count = $files.Count
        total_bytes = Get-DirectorySizeBytes -Path $DataPath
        line_count = $lineCount
        json_line_count = $jsonLineCount
        parse_error_count = $parseErrors
        records_seen = $recordsSeen
        node_fills_records = $fillRecords
        misc_events_records = $miscRecords
        fill_liquidation_records = $fillLiquidationRecords
        misc_liquidation_records = $miscLiquidationRecords
        liquidation_marker_records = $liquidationMarkerRecords
        notional_candidates = $notionalCandidates
        unique_liquidation_candidate_ids = $candidateIds.Count
        max_notional_usd = [double]$maxNotionalUsd
        largest_notional_records = $largestRows
    }
}

$mandatoryFlags = @(
    "--write-fills",
    "--write-misc-events",
    "--batch-by-block",
    "--stream-with-block-info",
    "--disable-output-file-buffering"
)

$report = [ordered]@{
    generated_at = (Get-Date).ToUniversalTime().ToString("o")
    mode = if ($Run) { "run" } elseif (-not [string]::IsNullOrWhiteSpace($ExistingDataPath)) { "analyze-existing" } else { "dry-run" }
    status = "ok"
    limits = [ordered]@{
        max_runtime_seconds = $MaxRuntimeSeconds
        max_bytes = $MaxBytes
    }
    official_node_flags = $mandatoryFlags
    warnings = @(
        "Hyperliquid node writes to ~/hl/data and official docs warn about large log volume.",
        "This probe is research-only and must not enable production collection by itself."
    )
}

if (-not [string]::IsNullOrWhiteSpace($ExistingDataPath)) {
    $dataPath = if ([System.IO.Path]::IsPathRooted($ExistingDataPath)) {
        [System.IO.Path]::GetFullPath($ExistingDataPath)
    } else {
        [System.IO.Path]::GetFullPath((Join-Path $RepoRoot $ExistingDataPath))
    }
    if (-not (Test-Path -LiteralPath $dataPath)) {
        throw "ExistingDataPath not found: $dataPath"
    }
    $report["analysis"] = Analyze-HyperliquidNodeData -DataPath $dataPath
} elseif ($Run) {
    if ([string]::IsNullOrWhiteSpace($NodeExecutable)) {
        throw "NodeExecutable is required with -Run. Use dry-run first, then pass an explicit hl-visor/runner path."
    }

    if (Test-Path -LiteralPath $NodeHomePath) {
        Remove-Item -LiteralPath $NodeHomePath -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $NodeHomePath | Out-Null

    $fullArgs = @($NodeArgs) + $mandatoryFlags
    $report["node_home_path"] = $NodeHomePath
    $report["node_data_path"] = $NodeDataPath
    $report["command"] = ([string]$NodeExecutable + " " + ($fullArgs -join " "))

    $oldHome = $env:HOME
    $oldUserProfile = $env:USERPROFILE
    $process = $null
    $stopReason = "max_runtime_seconds"
    $startedAt = Get-Date
    try {
        $env:HOME = $NodeHomePath
        $env:USERPROFILE = $NodeHomePath
        $process = Start-Process -FilePath $NodeExecutable -ArgumentList $fullArgs -PassThru -NoNewWindow

        while (-not $process.HasExited) {
            Start-Sleep -Seconds 1
            $elapsed = ((Get-Date) - $startedAt).TotalSeconds
            $bytes = Get-DirectorySizeBytes -Path $NodeDataPath
            if ($bytes -ge $MaxBytes) {
                $stopReason = "max_bytes"
                break
            }
            if ($elapsed -ge $MaxRuntimeSeconds) {
                $stopReason = "max_runtime_seconds"
                break
            }
        }
    } finally {
        if ($null -ne $process -and -not $process.HasExited) {
            Stop-Process -Id $process.Id -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 3
            if (-not $process.HasExited -and (Get-Command taskkill.exe -ErrorAction SilentlyContinue)) {
                & taskkill.exe /PID $process.Id /T /F | Out-Null
            }
        }
        $env:HOME = $oldHome
        $env:USERPROFILE = $oldUserProfile
    }

    $report["runtime_seconds"] = [math]::Round(((Get-Date) - $startedAt).TotalSeconds, 3)
    $report["stop_reason"] = $stopReason
    $report["analysis"] = Analyze-HyperliquidNodeData -DataPath $NodeDataPath

    if (-not $KeepRaw -and (Test-Path -LiteralPath $NodeHomePath)) {
        Remove-Item -LiteralPath $NodeHomePath -Recurse -Force
        $report["raw_cleanup"] = "removed_probe_home"
    } else {
        $report["raw_cleanup"] = "kept"
    }
} else {
    $plannedArgs = @($NodeArgs) + $mandatoryFlags
    $report["status"] = "dry-run-only"
    $report["node_home_path"] = $NodeHomePath
    $report["node_data_path"] = $NodeDataPath
    $report["planned_command"] = if ([string]::IsNullOrWhiteSpace($NodeExecutable)) {
        "<NodeExecutable> " + ($plannedArgs -join " ")
    } else {
        ([string]$NodeExecutable + " " + ($plannedArgs -join " "))
    }
    $report["next_action"] = "Pass -Run -NodeExecutable <hl-visor path> only after reviewing the command and limits."
}

$report | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $JsonFullPath -Encoding UTF8
$report | ConvertTo-Json -Depth 20
Write-Output "Probe report written to $JsonFullPath"
