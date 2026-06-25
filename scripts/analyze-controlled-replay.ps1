param(
    [string]$AggregateReportPath = ".cache/replay/controlled-replay-aggregate.json",
    [string]$OutputPath,
    [switch]$Json
)

$ErrorActionPreference = "Stop"

$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$AggregateReportFullPath = if ([System.IO.Path]::IsPathRooted($AggregateReportPath)) {
    $AggregateReportPath
} else {
    Join-Path $RepoRoot $AggregateReportPath
}

if (-not (Test-Path -LiteralPath $AggregateReportFullPath)) {
    throw "Aggregate report not found: $AggregateReportFullPath"
}

function Get-RunSummaryNumber {
    param(
        [object]$Attempt,
        [string]$Id,
        [string]$Prefix
    )

    $row = @($Attempt.run_summary | Where-Object { $_.id -eq $Id } | Select-Object -First 1)
    if ($row.Count -eq 0 -or -not $row[0].detail) {
        return 0
    }

    $pattern = [regex]::Escape($Prefix) + "=(\d+)"
    $match = [regex]::Match([string]$row[0].detail, $pattern)
    if (-not $match.Success) {
        return 0
    }
    return [int]$match.Groups[1].Value
}

function Get-StageCounts {
    param([object[]]$Attempts)

    $stageCounts = @{}
    $reasonCounts = @{}

    foreach ($attempt in $Attempts) {
        foreach ($reason in @($attempt.signal_rejection_reasons)) {
            $stage = if ($reason.stage) { [string]$reason.stage } else { "unknown" }
            $id = if ($reason.id) { [string]$reason.id } else { "unknown" }
            $count = [int]$reason.count

            if (-not $stageCounts.ContainsKey($stage)) {
                $stageCounts[$stage] = 0
            }
            $stageCounts[$stage] += $count

            $reasonKey = "$stage/$id"
            if (-not $reasonCounts.ContainsKey($reasonKey)) {
                $reasonCounts[$reasonKey] = [pscustomobject]@{
                    stage = $stage
                    id = $id
                    count = 0
                    latest_detail = $null
                }
            }
            $reasonCounts[$reasonKey].count += $count
            if ($reason.detail) {
                $reasonCounts[$reasonKey].latest_detail = [string]$reason.detail
            }
        }
    }

    [pscustomobject]@{
        by_stage = @($stageCounts.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object {
            [pscustomobject]@{ stage = $_.Key; count = [int]$_.Value }
        })
        by_reason = @($reasonCounts.Values | Sort-Object count -Descending)
    }
}

function Get-ResearchProfileRecommendation {
    param([object[]]$Reasons)

    $above = @($Reasons | Where-Object { $_.id -eq "liquidation_notional_above_threshold" } | Select-Object -First 1)
    $below = @($Reasons | Where-Object { $_.id -eq "liquidation_notional_below_threshold" } | Select-Object -First 1)

    if ($above.Count -gt 0 -and [int]$above[0].count -gt 0) {
        return [pscustomobject]@{
            useful = $true
            profile = "research-wide-threshold"
            reason = "above-threshold liquidations dominate; test a diagnostic wider upper band without changing baseline"
        }
    }
    if ($below.Count -gt 0 -and [int]$below[0].count -gt 0) {
        return [pscustomobject]@{
            useful = $false
            profile = "research-wide-threshold"
            reason = "below-threshold liquidations dominate; lowering the baseline threshold would likely add noise"
        }
    }

    return [pscustomobject]@{
        useful = $false
        profile = "research-wide-threshold"
        reason = "no threshold-dominant rejection pattern detected"
    }
}

$aggregate = Get-Content -Raw -LiteralPath $AggregateReportFullPath | ConvertFrom-Json
$attempts = @($aggregate.attempts)
$completedAttempts = @($attempts | Where-Object { $_.status -eq "completed" })
$failedAttempts = @($attempts | Where-Object { $_.status -ne "completed" })
$stageCounts = Get-StageCounts -Attempts $completedAttempts

$totals = [pscustomobject]@{
    attempts_total = $attempts.Count
    attempts_completed = $completedAttempts.Count
    attempts_failed = $failedAttempts.Count
    liquidations = [int](@($completedAttempts | ForEach-Object { Get-RunSummaryNumber -Attempt $_ -Id "liquidation_seen" -Prefix "liquidations" } | Measure-Object -Sum).Sum)
    signals = [int](@($completedAttempts | Measure-Object -Property signal_count -Sum).Sum)
    polymarket_orders = [int](@($completedAttempts | Measure-Object -Property polymarket_orders -Sum).Sum)
    polymarket_fills = [int](@($completedAttempts | Measure-Object -Property polymarket_fills -Sum).Sum)
    hedge_attempts = [int](@($completedAttempts | Measure-Object -Property hedge_attempts -Sum).Sum)
    hedge_fills = [int](@($completedAttempts | Measure-Object -Property hedge_fills -Sum).Sum)
}

$bottleneck = if ($stageCounts.by_stage.Count -gt 0) {
    [pscustomobject]@{
        stage = [string]$stageCounts.by_stage[0].stage
        count = [int]$stageCounts.by_stage[0].count
    }
} elseif ($totals.polymarket_fills -lt $totals.polymarket_orders) {
    [pscustomobject]@{ stage = "entry_fill"; count = $totals.polymarket_orders - $totals.polymarket_fills }
} elseif ($totals.hedge_fills -lt $totals.hedge_attempts) {
    [pscustomobject]@{ stage = "hedge_fill"; count = $totals.hedge_attempts - $totals.hedge_fills }
} else {
    [pscustomobject]@{ stage = "none"; count = 0 }
}

$tradePathBlocker = if ($totals.liquidations -eq 0) {
    [pscustomobject]@{ stage = "liquidation_seen"; detail = "no liquidation events observed" }
} elseif ($totals.signals -eq 0) {
    [pscustomobject]@{ stage = "signal_gate"; detail = "liquidations observed, but no strategy signals built" }
} elseif ($totals.polymarket_fills -lt $totals.polymarket_orders) {
    [pscustomobject]@{ stage = "entry_fill"; detail = "signals created Polymarket orders, but trade_cross did not prove fills" }
} elseif ($totals.hedge_fills -lt $totals.hedge_attempts) {
    [pscustomobject]@{ stage = "hedge_fill"; detail = "entry fills exist, but hedge fills are incomplete" }
} else {
    [pscustomobject]@{ stage = "complete"; detail = "trade path reached PnL computation for all observed orders" }
}

$analysis = [pscustomobject]@{
    generated_at = ([DateTime]::UtcNow.ToString("o"))
    aggregate_report_path = [string]$AggregateReportFullPath
    aggregate_status = [string]$aggregate.status
    attempts_completed = [int]$aggregate.attempts_completed
    totals = $totals
    bottleneck = $bottleneck
    trade_path_blocker = $tradePathBlocker
    rejection_counts = $stageCounts
    research_profile_recommendation = Get-ResearchProfileRecommendation -Reasons $stageCounts.by_reason
}

if ($OutputPath) {
    $OutputFullPath = if ([System.IO.Path]::IsPathRooted($OutputPath)) {
        $OutputPath
    } else {
        Join-Path $RepoRoot $OutputPath
    }
    $parent = Split-Path -Parent $OutputFullPath
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $analysis | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $OutputFullPath -Encoding UTF8
}

if ($Json) {
    $analysis | ConvertTo-Json -Depth 20
    return
}

Write-Output "controlled replay aggregate analysis"
Write-Output "status=$($analysis.aggregate_status) attempts_total=$($totals.attempts_total) attempts_completed=$($totals.attempts_completed) attempts_failed=$($totals.attempts_failed) liquidations=$($totals.liquidations) signals=$($totals.signals) orders=$($totals.polymarket_orders) fills=$($totals.polymarket_fills) hedge_attempts=$($totals.hedge_attempts) hedge_fills=$($totals.hedge_fills)"
Write-Output "bottleneck=$($bottleneck.stage) count=$($bottleneck.count)"
Write-Output "trade_path_blocker=$($tradePathBlocker.stage) detail=$($tradePathBlocker.detail)"
foreach ($reason in $stageCounts.by_reason) {
    Write-Output "reason=$($reason.stage)/$($reason.id) count=$($reason.count) detail=$($reason.latest_detail)"
}
Write-Output "research_profile=$($analysis.research_profile_recommendation.profile) useful=$($analysis.research_profile_recommendation.useful) reason=$($analysis.research_profile_recommendation.reason)"
