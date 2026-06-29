param(
    [Parameter(Mandatory = $true)][string[]]$SourceUsefulnessArtifactPath,
    [string]$OutputPath = ".cache/source-usefulness/signal-readiness.json",
    [string[]]$IncludedSources = @("bybit", "binance", "okx", "bitget", "gate"),
    [switch]$Json
)

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot

function Resolve-RepoPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    if ([IO.Path]::IsPathRooted($Path)) {
        return $Path
    }

    return Join-Path $repoRoot $Path
}

function ConvertTo-DecimalOrNull {
    param($Value)

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        return $null
    }

    return [decimal]::Parse(
        [string]$Value,
        [Globalization.NumberStyles]::Number,
        [Globalization.CultureInfo]::InvariantCulture
    )
}

function New-SourceAccumulator {
    param([Parameter(Mandatory = $true)][string]$Source)

    [pscustomobject]@{
        source = $Source
        reports_seen = 0
        symbols = @()
        coverage_role = $null
        source_quality = $null
        participates_in_signals = $false
        raw_events = 0
        canonical_events = 0
        signal_ready_windows_proxy = 0
        overlap_buckets_with_primary = 0
        max_notional_usd = $null
        verdict_counts = [ordered]@{}
    }
}

function Add-Verdict {
    param(
        [Parameter(Mandatory = $true)]$Accumulator,
        [string]$Verdict
    )

    if ([string]::IsNullOrWhiteSpace($Verdict)) {
        return
    }

    if (-not $Accumulator.verdict_counts.Contains($Verdict)) {
        $Accumulator.verdict_counts[$Verdict] = 0
    }
    $Accumulator.verdict_counts[$Verdict] = [int]$Accumulator.verdict_counts[$Verdict] + 1
}

if ($IncludedSources.Count -eq 0) {
    throw "IncludedSources must not be empty."
}

if (@($IncludedSources | Where-Object { $_ -eq "htx" }).Count -gt 0) {
    throw "HTX must not be included in the default current-source readiness report. Use an explicit future HTX report after a documented decision."
}

$resolvedArtifacts = @($SourceUsefulnessArtifactPath | ForEach-Object { Resolve-RepoPath $_ })
foreach ($path in $resolvedArtifacts) {
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Source usefulness artifact not found: $path"
    }
}

$sourceAccumulators = [ordered]@{}
foreach ($source in $IncludedSources) {
    $sourceAccumulators[$source] = New-SourceAccumulator -Source $source
}

$reports = @()
foreach ($path in $resolvedArtifacts) {
    $report = Get-Content -Raw -LiteralPath $path | ConvertFrom-Json
    $reports += [pscustomobject]@{
        path = $path
        report = $report
    }

    foreach ($source in $IncludedSources) {
        $row = @($report.sources | Where-Object { $_.source -eq $source }) | Select-Object -First 1
        if ($null -eq $row) {
            continue
        }

        $accumulator = $sourceAccumulators[$source]
        $accumulator.reports_seen = [int]$accumulator.reports_seen + 1
        $accumulator.raw_events = [int64]$accumulator.raw_events + [int64]$row.raw_events
        $accumulator.canonical_events = [int64]$accumulator.canonical_events + [int64]$row.canonical_events
        $accumulator.signal_ready_windows_proxy = [int64]$accumulator.signal_ready_windows_proxy + [int64]$row.liquidation_ready_buckets_without_primary
        $accumulator.overlap_buckets_with_primary = [int64]$accumulator.overlap_buckets_with_primary + [int64]$row.overlap_buckets_with_primary
        $accumulator.coverage_role = [string]$row.coverage_role
        $accumulator.source_quality = [string]$row.source_quality
        $accumulator.participates_in_signals = [bool]$row.participates_in_signals

        $symbols = @($accumulator.symbols) + @($row.symbols)
        $accumulator.symbols = @($symbols | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Sort-Object -Unique)

        $maxNotional = ConvertTo-DecimalOrNull $row.max_notional_usd
        if ($null -ne $maxNotional -and ($null -eq $accumulator.max_notional_usd -or $maxNotional -gt [decimal]$accumulator.max_notional_usd)) {
            $accumulator.max_notional_usd = $maxNotional
        }

        Add-Verdict -Accumulator $accumulator -Verdict ([string]$row.verdict)
    }
}

$sourceOutput = [ordered]@{}
foreach ($source in $IncludedSources) {
    $accumulator = $sourceAccumulators[$source]
    $sourceOutput[$source] = [pscustomobject]@{
        source = $accumulator.source
        reports_seen = [int]$accumulator.reports_seen
        symbols = @($accumulator.symbols)
        coverage_role = $accumulator.coverage_role
        source_quality = $accumulator.source_quality
        participates_in_signals = [bool]$accumulator.participates_in_signals
        raw_events = [int64]$accumulator.raw_events
        canonical_events = [int64]$accumulator.canonical_events
        signal_ready_windows_proxy = [int64]$accumulator.signal_ready_windows_proxy
        overlap_buckets_with_primary = [int64]$accumulator.overlap_buckets_with_primary
        max_notional_usd = if ($null -eq $accumulator.max_notional_usd) { $null } else { ([decimal]$accumulator.max_notional_usd).ToString([Globalization.CultureInfo]::InvariantCulture) }
        verdict_counts = [pscustomobject]$accumulator.verdict_counts
    }
}

$diagnosticSources = @($IncludedSources | Where-Object { $_ -ne "bybit" })
$totalSignalReady = [int64](@($diagnosticSources | ForEach-Object { [int64]$sourceAccumulators[$_].signal_ready_windows_proxy } | Measure-Object -Sum).Sum)
$totalCanonical = [int64](@($IncludedSources | ForEach-Object { [int64]$sourceAccumulators[$_].canonical_events } | Measure-Object -Sum).Sum)
$diagnosticWithAdditive = @($diagnosticSources | Where-Object { [int64]$sourceAccumulators[$_].signal_ready_windows_proxy -gt 0 })

if ($reports.Count -eq 0) {
    $htxClassification = "insufficient_data"
    $htxDetail = "No source usefulness artifacts were provided."
} elseif ($totalSignalReady -gt 0) {
    $htxClassification = "defer_htx"
    $htxDetail = "Current sources already produced signal-ready proxy buckets without HTX; continue replay/fill/PnL analysis first."
} elseif ($totalCanonical -gt 0) {
    $htxClassification = "keep_htx_deferred_but_watch"
    $htxDetail = "Current sources produced canonical liquidation events but no additive buckets versus primary in this sample; collect more windows before reopening HTX."
} else {
    $htxClassification = "coverage_gap_watch"
    $htxDetail = "Current artifacts show no canonical liquidation coverage; keep collecting current sources before starting HTX."
}

$analysis = [pscustomobject]@{
    generated_at = (Get-Date).ToUniversalTime().ToString("o")
    report_count = [int]$reports.Count
    input_artifacts = @($resolvedArtifacts)
    included_sources = @($IncludedSources)
    primary_source = "bybit"
    signal_ready_window_definition = "proxy: source usefulness bucket where a diagnostic source had canonical liquidation events and the primary source had none"
    totals = [pscustomobject]@{
        canonical_events = $totalCanonical
        signal_ready_windows_proxy = $totalSignalReady
        diagnostic_sources_with_signal_ready_proxy = [int]$diagnosticWithAdditive.Count
    }
    sources = [pscustomobject]$sourceOutput
    htx_decision = [pscustomobject]@{
        classification = $htxClassification
        detail = $htxDetail
        rule = "HTX remains deferred unless repeated current-source reports prove source coverage is the blocker."
    }
}

$resolvedOutputPath = Resolve-RepoPath $OutputPath
$outputDir = Split-Path -Parent $resolvedOutputPath
if (-not [string]::IsNullOrWhiteSpace($outputDir)) {
    New-Item -ItemType Directory -Force -Path $outputDir *> $null
}

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[IO.File]::WriteAllText($resolvedOutputPath, ($analysis | ConvertTo-Json -Depth 16), $utf8NoBom)

if ($Json) {
    Write-Output ($analysis | ConvertTo-Json -Depth 16)
} else {
    Write-Output "source signal-readiness report"
    Write-Output "reports=$($analysis.report_count) signal_ready_windows_proxy=$($analysis.totals.signal_ready_windows_proxy) diagnostic_sources_with_signal_ready_proxy=$($analysis.totals.diagnostic_sources_with_signal_ready_proxy)"
    foreach ($source in $IncludedSources) {
        $row = $analysis.sources.$source
        Write-Output "source=$source canonical_events=$($row.canonical_events) signal_ready_windows_proxy=$($row.signal_ready_windows_proxy) max_notional_usd=$($row.max_notional_usd)"
    }
    Write-Output "htx_decision=$($analysis.htx_decision.classification): $($analysis.htx_decision.detail)"
    Write-Output "artifact=$resolvedOutputPath"
}
