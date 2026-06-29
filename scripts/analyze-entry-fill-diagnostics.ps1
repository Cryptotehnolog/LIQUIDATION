param(
    [string[]]$ReplayArtifactPath = @(),
    [string]$ReplayArtifactListPath = "",
    [string]$ReplayArtifactDirectory = ".cache/replay",
    [string]$ProfileComparisonAggregatePath = "",
    [string]$OutputPath = ".cache/replay/entry-fill-diagnostics-analysis.json",
    [int]$LateEntrySeconds = 30,
    [decimal]$MaxUsefulTradeDistance = 0.05,
    [switch]$DisableReplayArtifactDirectory,
    [switch]$Json
)

$ErrorActionPreference = "Stop"

$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")

function Resolve-RepoPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return $Path
    }
    Join-Path $RepoRoot $Path
}

function Convert-ToDecimal {
    param([object]$Value)

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        return $null
    }
    [decimal]::Parse(
        [string]$Value,
        [System.Globalization.NumberStyles]::Any,
        [System.Globalization.CultureInfo]::InvariantCulture
    )
}

function Add-UniquePath {
    param(
        [Parameter(Mandatory = $true)]$Set,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $resolved = Resolve-RepoPath -Path $Path
    if (Test-Path -LiteralPath $resolved) {
        $Set[$resolved] = $true
    }
}

function Add-PathsFromComparisonAggregate {
    param(
        [Parameter(Mandatory = $true)]$Set,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $fullPath = Resolve-RepoPath -Path $Path
    if (-not (Test-Path -LiteralPath $fullPath)) {
        throw "Profile comparison aggregate not found: $fullPath"
    }

    $aggregate = Get-Content -Raw -LiteralPath $fullPath | ConvertFrom-Json
    foreach ($attempt in @($aggregate.attempts)) {
        foreach ($profile in @($attempt.profiles)) {
            if ($profile.artifact_path) {
                Add-UniquePath -Set $Set -Path ([string]$profile.artifact_path)
            }
        }
    }
}

function Read-ReplayReport {
    param([Parameter(Mandatory = $true)][string]$Path)

    try {
        $value = Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json
    } catch {
        return $null
    }

    if ($null -eq $value.trades -or $null -eq $value.signal_count) {
        return $null
    }
    $value
}

function New-Totals {
    [ordered]@{
        artifacts = 0
        artifacts_with_entry_diagnostics = 0
        signals = 0
        polymarket_orders = 0
        polymarket_fills = 0
        missing_entry_diagnostics = 0
        entry_diagnostics = 0
        late_entries = 0
        no_trade_liquidity = 0
        trade_cross_reachable = 0
        book_touch_reachable_without_trade = 0
        distance_samples = 0
        trade_distance_sum = [decimal]0
        book_distance_sum = [decimal]0
        seconds_to_expiry_sum = [decimal]0
    }
}

function Add-ReportToAnalysis {
    param(
        [Parameter(Mandatory = $true)]$Totals,
        [Parameter(Mandatory = $true)]$Rows,
        [Parameter(Mandatory = $true)]$Report,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $Totals.artifacts += 1
    $Totals.signals += [int]$Report.signal_count
    $Totals.polymarket_orders += [int]$Report.polymarket_orders
    $Totals.polymarket_fills += [int]$Report.polymarket_fills

    $hasDiagnostics = $false
    foreach ($trade in @($Report.trades)) {
        $diagnostics = $trade.entry_fill_diagnostics
        if ($null -eq $diagnostics) {
            $Totals.missing_entry_diagnostics += 1
            continue
        }
        $hasDiagnostics = $true
        $Totals.entry_diagnostics += 1

        $seconds = [int]$diagnostics.seconds_to_order_expiry
        $tradeDistance = Convert-ToDecimal $diagnostics.trade_distance_to_fill
        $bookDistance = Convert-ToDecimal $diagnostics.book_distance_to_fill
        $tradesInWindow = [int]$diagnostics.trades_in_order_window
        $entryFilled = [string]$trade.polymarket_fill.status -eq "filled"

        $Totals.seconds_to_expiry_sum += [decimal]$seconds
        if ($seconds -le $LateEntrySeconds) {
            $Totals.late_entries += 1
        }
        if ($tradesInWindow -eq 0) {
            $Totals.no_trade_liquidity += 1
        }
        if ($null -ne $tradeDistance) {
            $Totals.distance_samples += 1
            $Totals.trade_distance_sum += $tradeDistance
            if ($tradeDistance -eq [decimal]0) {
                $Totals.trade_cross_reachable += 1
            }
        }
        if ($null -ne $bookDistance) {
            $Totals.book_distance_sum += $bookDistance
            if ($bookDistance -eq [decimal]0 -and ($null -eq $tradeDistance -or $tradeDistance -gt [decimal]0)) {
                $Totals.book_touch_reachable_without_trade += 1
            }
        }

        $Rows.Add([pscustomobject]@{
            artifact_path = $Path
            signal_id = [string]$trade.signal.signal_id
            outcome = [string]$trade.outcome
            entry_filled = $entryFilled
            signal_best_ask = [string]$diagnostics.signal_best_ask
            limit_price = [string]$diagnostics.limit_price
            pullback_pct = [string]$diagnostics.pullback_pct
            seconds_to_order_expiry = $seconds
            trades_in_order_window = $tradesInWindow
            best_trade_price_in_window = [string]$diagnostics.best_trade_price_in_window
            trade_distance_to_fill = if ($null -eq $tradeDistance) { $null } else { $tradeDistance.ToString([System.Globalization.CultureInfo]::InvariantCulture) }
            books_in_order_window = [int]$diagnostics.books_in_order_window
            best_book_touch_price_in_window = [string]$diagnostics.best_book_touch_price_in_window
            book_distance_to_fill = if ($null -eq $bookDistance) { $null } else { $bookDistance.ToString([System.Globalization.CultureInfo]::InvariantCulture) }
            fill_reason = [string]$diagnostics.fill_reason
        }) | Out-Null
    }

    if ($hasDiagnostics) {
        $Totals.artifacts_with_entry_diagnostics += 1
    }
}

function New-Decision {
    param([Parameter(Mandatory = $true)]$Summary)

    if ($Summary.signals -eq 0) {
        return [pscustomobject]@{
            classification = "no_signals_built"
            detail = "Replay artifacts contain no strategy signals; inspect signal_gate/expiry rejection reasons before entry-fill tuning."
        }
    }
    if ($Summary.entry_diagnostics -eq 0) {
        return [pscustomobject]@{
            classification = "insufficient_diagnostics"
            detail = "No entry_fill_diagnostics rows were found; rerun replay with the current code."
        }
    }
    if ($Summary.polymarket_fills -gt 0) {
        return [pscustomobject]@{
            classification = "entry_fill_observed"
            detail = "At least one Polymarket entry filled; inspect hedge path and net PnL before changing baseline."
        }
    }
    if ($Summary.late_entry_ratio -ge 0.5) {
        return [pscustomobject]@{
            classification = "late_signal_dominates"
            detail = "Most signals had too little time before forced cancel; do not tune pullback or thresholds from these windows."
        }
    }
    if ($Summary.no_trade_liquidity_ratio -ge 0.5) {
        return [pscustomobject]@{
            classification = "polymarket_trade_liquidity_gap"
            detail = "Most signals had no Polymarket trades inside the order window; collect more liquid windows before tuning."
        }
    }
    if ($Summary.book_touch_reachable_without_trade -gt 0) {
        return [pscustomobject]@{
            classification = "trade_cross_conservative"
            detail = "Book touch reached the limit without recorded trade_cross; compare trade_cross vs book_touch as diagnostics only."
        }
    }
    if ($Summary.average_trade_distance_to_fill -gt $MaxUsefulTradeDistance) {
        return [pscustomobject]@{
            classification = "pullback_too_deep_candidate"
            detail = "Average trade distance to fill is above the configured useful threshold; test pullback profiles on more windows."
        }
    }
    [pscustomobject]@{
        classification = "needs_more_windows"
        detail = "No dominant entry-fill failure mode yet; collect more replay windows."
    }
}

$paths = @{}
foreach ($path in $ReplayArtifactPath) {
    Add-UniquePath -Set $paths -Path $path
}
if ($ReplayArtifactListPath) {
    $listFullPath = Resolve-RepoPath -Path $ReplayArtifactListPath
    if (-not (Test-Path -LiteralPath $listFullPath)) {
        throw "Replay artifact list not found: $listFullPath"
    }
    Get-Content -LiteralPath $listFullPath | ForEach-Object {
        $line = ([string]$_).Trim()
        if ($line) {
            Add-UniquePath -Set $paths -Path $line
        }
    }
}
if (-not $DisableReplayArtifactDirectory -and $ReplayArtifactDirectory) {
    $directory = Resolve-RepoPath -Path $ReplayArtifactDirectory
    if (Test-Path -LiteralPath $directory) {
        Get-ChildItem -LiteralPath $directory -Recurse -Filter *.json | ForEach-Object {
            Add-UniquePath -Set $paths -Path $_.FullName
        }
    }
}
if ($ProfileComparisonAggregatePath) {
    Add-PathsFromComparisonAggregate -Set $paths -Path $ProfileComparisonAggregatePath
}

$totals = New-Totals
$rows = [System.Collections.ArrayList]::new()

foreach ($path in @($paths.Keys | Sort-Object)) {
    $report = Read-ReplayReport -Path $path
    if ($null -ne $report) {
        Add-ReportToAnalysis -Totals $totals -Rows $rows -Report $report -Path $path
    }
}

$entryDiagnostics = [int]$totals.entry_diagnostics
$distanceSamples = [int]$totals.distance_samples
$summary = [pscustomobject]@{
    artifacts = [int]$totals.artifacts
    artifacts_with_entry_diagnostics = [int]$totals.artifacts_with_entry_diagnostics
    signals = [int]$totals.signals
    polymarket_orders = [int]$totals.polymarket_orders
    polymarket_fills = [int]$totals.polymarket_fills
    missing_entry_diagnostics = [int]$totals.missing_entry_diagnostics
    entry_diagnostics = $entryDiagnostics
    late_entries = [int]$totals.late_entries
    late_entry_ratio = if ($entryDiagnostics -gt 0) { [decimal]$totals.late_entries / [decimal]$entryDiagnostics } else { [decimal]0 }
    no_trade_liquidity = [int]$totals.no_trade_liquidity
    no_trade_liquidity_ratio = if ($entryDiagnostics -gt 0) { [decimal]$totals.no_trade_liquidity / [decimal]$entryDiagnostics } else { [decimal]0 }
    trade_cross_reachable = [int]$totals.trade_cross_reachable
    book_touch_reachable_without_trade = [int]$totals.book_touch_reachable_without_trade
    average_trade_distance_to_fill = if ($distanceSamples -gt 0) { $totals.trade_distance_sum / [decimal]$distanceSamples } else { [decimal]0 }
    average_book_distance_to_fill = if ($distanceSamples -gt 0) { $totals.book_distance_sum / [decimal]$distanceSamples } else { [decimal]0 }
    average_seconds_to_order_expiry = if ($entryDiagnostics -gt 0) { $totals.seconds_to_expiry_sum / [decimal]$entryDiagnostics } else { [decimal]0 }
}

$analysis = [pscustomobject]@{
    generated_at = ([DateTime]::UtcNow.ToString("o"))
    replay_artifact_directory = if ($ReplayArtifactDirectory) { [string](Resolve-RepoPath -Path $ReplayArtifactDirectory) } else { $null }
    profile_comparison_aggregate_path = if ($ProfileComparisonAggregatePath) { [string](Resolve-RepoPath -Path $ProfileComparisonAggregatePath) } else { $null }
    late_entry_seconds = $LateEntrySeconds
    max_useful_trade_distance = $MaxUsefulTradeDistance.ToString([System.Globalization.CultureInfo]::InvariantCulture)
    summary = $summary
    decision = New-Decision -Summary $summary
    rows = @($rows)
}

if ($OutputPath) {
    $outputFullPath = Resolve-RepoPath -Path $OutputPath
    $parent = Split-Path -Parent $outputFullPath
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $analysis | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $outputFullPath -Encoding UTF8
}

if ($Json) {
    $analysis | ConvertTo-Json -Depth 30
    return
}

Write-Output "entry fill diagnostics analysis"
Write-Output "artifacts=$($summary.artifacts) diagnostics=$($summary.entry_diagnostics) signals=$($summary.signals) orders=$($summary.polymarket_orders) fills=$($summary.polymarket_fills)"
Write-Output "late_entries=$($summary.late_entries) late_entry_ratio=$($summary.late_entry_ratio) avg_seconds_to_order_expiry=$($summary.average_seconds_to_order_expiry)"
Write-Output "avg_trade_distance_to_fill=$($summary.average_trade_distance_to_fill) avg_book_distance_to_fill=$($summary.average_book_distance_to_fill)"
Write-Output "no_trade_liquidity=$($summary.no_trade_liquidity) book_touch_without_trade=$($summary.book_touch_reachable_without_trade)"
Write-Output "classification=$($analysis.decision.classification) detail=$($analysis.decision.detail)"
if ($OutputPath) {
    Write-Output "analysis_written=$((Resolve-RepoPath -Path $OutputPath))"
}
