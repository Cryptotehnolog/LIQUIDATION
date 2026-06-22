param(
    [string]$InputRoot = ".cache/nightly-market-data",
    [string]$OutputPath = ".cache/market-data-report-history/trend.md",
    [string]$JsonOutputPath = ".cache/market-data-report-history/trend.json",
    [int]$MinRunsForSignal = 3
)

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

function Resolve-RepoPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    if ([IO.Path]::IsPathRooted($Path)) {
        return $Path
    }

    return Join-Path $repoRoot $Path
}

function Read-SummaryFields {
    param([Parameter(Mandatory = $true)][string]$Path)

    $fields = @{}
    if (-not (Test-Path -LiteralPath $Path)) {
        return $fields
    }

    foreach ($line in Get-Content -LiteralPath $Path) {
        if ($line -match '^\s*-\s*([^:]+):\s*(.*)\s*$') {
            $fields[$Matches[1].Trim()] = $Matches[2].Trim()
        }
    }

    return $fields
}

function ConvertTo-OptionalBool {
    param([object]$Value)

    if ($null -eq $Value) {
        return $null
    }

    $text = "$Value".Trim().ToLowerInvariant()
    if ($text -eq "true") {
        return $true
    }
    if ($text -eq "false") {
        return $false
    }

    return $null
}

function Get-StatusForSource {
    param(
        [object]$Status,
        [Parameter(Mandatory = $true)][string]$Source
    )

    if ($null -eq $Status -or $null -eq $Status.sources) {
        return $null
    }

    $row = @($Status.sources | Where-Object { $_.source -eq $Source } | Select-Object -First 1)
    if ($row.Count -eq 0) {
        return $null
    }

    return $row[0].status
}

function New-MarketDataRun {
    param([Parameter(Mandatory = $true)][string]$OverlapPath)

    $runDir = Split-Path -Parent $OverlapPath
    $summaryPath = Join-Path $runDir "summary.md"
    $statusPath = Join-Path $runDir "collector-status.json"
    $fields = Read-SummaryFields -Path $summaryPath
    $overlap = Get-Content -Raw -LiteralPath $OverlapPath | ConvertFrom-Json
    $status = $null
    if (Test-Path -LiteralPath $statusPath) {
        $status = Get-Content -Raw -LiteralPath $statusPath | ConvertFrom-Json
    }

    $generatedAt = $fields["generated_at"]
    if ([string]::IsNullOrWhiteSpace($generatedAt)) {
        $generatedAt = ([IO.FileInfo]$OverlapPath).LastWriteTimeUtc.ToString("o")
    }

    [pscustomobject]@{
        run_id = Split-Path -Leaf $runDir
        report_dir = $runDir
        generated_at = $generatedAt
        bybit_status = if ($fields.ContainsKey("bybit_status")) { $fields["bybit_status"] } else { Get-StatusForSource -Status $status -Source "bybit" }
        okx_status = if ($fields.ContainsKey("okx_status")) { $fields["okx_status"] } else { Get-StatusForSource -Status $status -Source "okx" }
        okx_metadata_valid = ConvertTo-OptionalBool $fields["okx_metadata_valid"]
        bybit_raw_events = [int64]$overlap.primary.raw_events
        bybit_canonical_events = [int64]$overlap.primary.canonical_events
        okx_raw_events = [int64]$overlap.diagnostic.raw_events
        okx_canonical_events = [int64]$overlap.diagnostic.canonical_events
        overlap_buckets = @($overlap.buckets).Count
    }
}

function Format-Percent {
    param([double]$Value)

    return "{0:P0}" -f $Value
}

$resolvedInputRoot = Resolve-RepoPath $InputRoot
$resolvedOutputPath = Resolve-RepoPath $OutputPath
$resolvedJsonOutputPath = Resolve-RepoPath $JsonOutputPath

if (-not (Test-Path -LiteralPath $resolvedInputRoot)) {
    throw "InputRoot does not exist: $resolvedInputRoot"
}

$runs = @(
    Get-ChildItem -LiteralPath $resolvedInputRoot -Recurse -Filter "overlap-report.json" |
        ForEach-Object { New-MarketDataRun -OverlapPath $_.FullName } |
        Sort-Object generated_at
)

if ($runs.Count -eq 0) {
    throw "No overlap-report.json files found under $resolvedInputRoot"
}

$okxStatusOkCount = @($runs | Where-Object { $_.okx_status -eq "ok" }).Count
$metadataValidCount = @($runs | Where-Object { $_.okx_metadata_valid -eq $true }).Count
$eventSeenCount = @($runs | Where-Object { $_.okx_raw_events -gt 0 -or $_.okx_canonical_events -gt 0 }).Count
$totalOkxRaw = ($runs | Measure-Object -Property okx_raw_events -Sum).Sum
$totalOkxCanonical = ($runs | Measure-Object -Property okx_canonical_events -Sum).Sum
$totalOverlapBuckets = ($runs | Measure-Object -Property overlap_buckets -Sum).Sum

$okxStatusOkRate = $okxStatusOkCount / [double]$runs.Count
$metadataValidRate = $metadataValidCount / [double]$runs.Count
$eventSeenRate = $eventSeenCount / [double]$runs.Count
$averageOverlapBuckets = $totalOverlapBuckets / [double]$runs.Count

$conclusion = "insufficient-history"
$recommendation = "Нужно накопить больше nightly запусков перед выводом о полезности OKX."
if ($runs.Count -ge $MinRunsForSignal) {
    if ($metadataValidRate -lt 1.0) {
        $conclusion = "unreliable-metadata"
        $recommendation = "Сначала чинить metadata pipeline OKX; использовать OKX в стратегии рано."
    } elseif ($okxStatusOkRate -ge 0.8 -and $eventSeenRate -ge 0.3) {
        $conclusion = "useful-diagnostic"
        $recommendation = "OKX выглядит полезным diagnostic source; можно продолжать overlap validation, но не включать в сигнал автоматически."
    } elseif ($okxStatusOkRate -ge 0.8) {
        $conclusion = "healthy-but-sparse"
        $recommendation = "OKX технически живой, но событий мало; пока держать как diagnostic-only."
    } else {
        $conclusion = "unreliable-source"
        $recommendation = "OKX нестабилен в nightly checks; не тратить время на стратегию поверх него до стабилизации."
    }
}

$trend = [pscustomobject]@{
    generated_at = (Get-Date).ToUniversalTime().ToString("o")
    input_root = $resolvedInputRoot
    run_count = $runs.Count
    min_runs_for_signal = $MinRunsForSignal
    conclusion = $conclusion
    recommendation = $recommendation
    metrics = [pscustomobject]@{
        okx_status_ok_count = $okxStatusOkCount
        okx_status_ok_rate = $okxStatusOkRate
        okx_metadata_valid_count = $metadataValidCount
        okx_metadata_valid_rate = $metadataValidRate
        okx_event_seen_count = $eventSeenCount
        okx_event_seen_rate = $eventSeenRate
        okx_raw_events = $totalOkxRaw
        okx_canonical_events = $totalOkxCanonical
        average_overlap_buckets = $averageOverlapBuckets
    }
    runs = $runs
}

$tableRows = $runs | ForEach-Object {
    "| $($_.generated_at) | $($_.bybit_status) | $($_.okx_status) | $($_.okx_metadata_valid) | $($_.bybit_raw_events) | $($_.okx_raw_events) | $($_.okx_canonical_events) | $($_.overlap_buckets) |"
}

$markdown = @(
    "# Market Data Nightly Trend",
    "",
    "- generated_at: $($trend.generated_at)",
    "- run_count: $($trend.run_count)",
    "- conclusion: $conclusion",
    "- recommendation: $recommendation",
    "- okx_status_ok_rate: $(Format-Percent $okxStatusOkRate)",
    "- okx_metadata_valid_rate: $(Format-Percent $metadataValidRate)",
    "- okx_event_seen_rate: $(Format-Percent $eventSeenRate)",
    "- okx_raw_events: $totalOkxRaw",
    "- okx_canonical_events: $totalOkxCanonical",
    "- average_overlap_buckets: $([math]::Round($averageOverlapBuckets, 2))",
    "",
    "OKX remains diagnostic-only. This report measures whether OKX is useful",
    "as a reliability and coverage signal, not whether it should adjust strategy",
    "thresholds or liquidation notionals.",
    "",
    "| generated_at | bybit | okx | metadata | bybit_raw | okx_raw | okx_canonical | overlap_buckets |",
    "| --- | --- | --- | --- | ---: | ---: | ---: | ---: |"
) + $tableRows

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $resolvedOutputPath) *> $null
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $resolvedJsonOutputPath) *> $null
[IO.File]::WriteAllText($resolvedOutputPath, ($markdown -join "`n"), $utf8NoBom)
[IO.File]::WriteAllText($resolvedJsonOutputPath, ($trend | ConvertTo-Json -Depth 8), $utf8NoBom)

Write-Output (@{
    status = "ok"
    run_count = $runs.Count
    conclusion = $conclusion
    output_path = $resolvedOutputPath
    json_output_path = $resolvedJsonOutputPath
} | ConvertTo-Json -Compress)
