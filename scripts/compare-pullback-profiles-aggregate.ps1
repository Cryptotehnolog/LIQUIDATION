param(
    [string]$DatabaseUrl = $env:DATABASE_URL,
    [string[]]$MarketArtifactPath = @(),
    [string]$MarketArtifactDirectory = "",
    [string]$OutputPath = ".cache/replay/pullback-profile-aggregate.json",
    [string]$ArtifactDirectory = ".cache/replay/pullback-profile-aggregate",
    [decimal[]]$PullbackPct = @(0.30, 0.20, 0.15, 0.10),
    [string]$PullbackPctCsv = "",
    [string]$ReplayProfile = "baseline",
    [decimal]$LiquidationThresholdMinUsd = 25000,
    [decimal]$LiquidationThresholdMaxUsd = 100000,
    [decimal]$PolymarketUsdPerPosition = 15,
    [int]$OrderCancelWindowSeconds = 60,
    [int]$MarketStaleAfterMinutes = 2880,
    [switch]$SkipPreflight,
    [switch]$FailFast,
    [switch]$PrintCommandsOnly
)

$ErrorActionPreference = "Stop"

$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$SingleComparatorScript = Join-Path $PSScriptRoot "compare-pullback-profiles.ps1"
$OutputFullPath = Join-Path $RepoRoot $OutputPath
$ArtifactFullDirectory = Join-Path $RepoRoot $ArtifactDirectory
$InvariantCulture = [System.Globalization.CultureInfo]::InvariantCulture

if (-not $DatabaseUrl) {
    throw "DatabaseUrl or DATABASE_URL is required"
}
if (-not (Test-Path -LiteralPath $SingleComparatorScript)) {
    throw "Single-window pullback comparator not found: $SingleComparatorScript"
}
if (-not [string]::IsNullOrWhiteSpace($PullbackPctCsv)) {
    $PullbackPct = @($PullbackPctCsv -split "," |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ } |
        ForEach-Object {
            [decimal]::Parse(
                $_,
                [System.Globalization.NumberStyles]::Any,
                [System.Globalization.CultureInfo]::InvariantCulture
            )
        })
}
if ($PullbackPct.Count -lt 2) {
    throw "At least two pullback pct values are required"
}
foreach ($value in $PullbackPct) {
    if ($value -lt 0 -or $value -ge 1) {
        throw "PullbackPct values must be greater than or equal to 0 and less than 1"
    }
}
if (@($PullbackPct | Sort-Object -Unique).Count -ne $PullbackPct.Count) {
    throw "PullbackPct values must be unique"
}

function Format-Command {
    param([Parameter(Mandatory = $true)][string[]]$Parts)

    ($Parts | ForEach-Object {
        if ($_ -match "\s") { '"' + ($_ -replace '"', '\"') + '"' } else { $_ }
    }) -join " "
}

function Convert-ToDecimal {
    param([object]$Value)

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        return [decimal]0
    }
    [decimal]::Parse(
        [string]$Value,
        [System.Globalization.NumberStyles]::Any,
        $InvariantCulture
    )
}

function Format-Decimal {
    param([Parameter(Mandatory = $true)][decimal]$Value)

    $Value.ToString($InvariantCulture)
}

function Resolve-RepoPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return $Path
    }
    Join-Path $RepoRoot $Path
}

function Convert-ToRepoRelativePath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $fullPath = Resolve-RepoPath -Path $Path
    $repoRootText = ([string]$RepoRoot).TrimEnd("\")
    if ($fullPath.StartsWith($repoRootText, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $fullPath.Substring($repoRootText.Length).TrimStart("\")
    }
    $fullPath
}

function Get-MarketArtifactPaths {
    $paths = [System.Collections.ArrayList]::new()

    foreach ($rawPath in $MarketArtifactPath) {
        $candidatePaths = @([string]$rawPath -split "," | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
        foreach ($path in $candidatePaths) {
            if ([string]::IsNullOrWhiteSpace($path)) {
                continue
            }
            $fullPath = Resolve-RepoPath -Path $path
            if (-not (Test-Path -LiteralPath $fullPath)) {
                throw "Market artifact not found: $fullPath"
            }
            $paths.Add((Convert-ToRepoRelativePath -Path $fullPath)) | Out-Null
        }
    }

    if ($MarketArtifactDirectory) {
        $directory = Resolve-RepoPath -Path $MarketArtifactDirectory
        if (-not (Test-Path -LiteralPath $directory)) {
            throw "Market artifact directory not found: $directory"
        }
        Get-ChildItem -LiteralPath $directory -Recurse -File -Filter "market.json" |
            Sort-Object FullName |
            ForEach-Object {
                $relative = Convert-ToRepoRelativePath -Path $_.FullName
                if (-not $paths.Contains($relative)) {
                    $paths.Add($relative) | Out-Null
                }
            }
    }

    if ($paths.Count -eq 0) {
        throw "At least one MarketArtifactPath or MarketArtifactDirectory with market.json files is required"
    }

    @($paths)
}

function New-ProfileTotal {
    param([Parameter(Mandatory = $true)][string]$Profile)

    [ordered]@{
        profile = $Profile
        comparisons = 0
        windows_with_signals = 0
        windows_with_entry_fills = 0
        signal_count = 0
        polymarket_orders = 0
        polymarket_fills = 0
        hedge_attempts = 0
        hedge_fills = 0
        gross_pnl_usd = [decimal]0
        total_fees_usd = [decimal]0
        total_funding_usd = [decimal]0
        total_slippage_usd = [decimal]0
        net_pnl_usd = [decimal]0
        max_drawdown_usd = [decimal]0
        distance_samples = 0
        trade_distance_sum = [decimal]0
        book_distance_sum = [decimal]0
        expiry_samples = 0
        seconds_to_expiry_sum = [decimal]0
        closest_trade_distance_to_fill = $null
        closest_book_distance_to_fill = $null
    }
}

function Add-ProfileToTotals {
    param(
        [Parameter(Mandatory = $true)]$Totals,
        [Parameter(Mandatory = $true)]$Profile
    )

    $profileName = [string]$Profile.profile
    if (-not $Totals.Contains($profileName)) {
        $Totals[$profileName] = New-ProfileTotal -Profile $profileName
    }

    $target = $Totals[$profileName]
    $signals = [int]$Profile.signal_count
    $orders = [int]$Profile.polymarket_orders
    $fills = [int]$Profile.polymarket_fills

    $target.comparisons += 1
    $target.signal_count += $signals
    $target.polymarket_orders += $orders
    $target.polymarket_fills += $fills
    $target.hedge_attempts += [int]$Profile.hedge_attempts
    $target.hedge_fills += [int]$Profile.hedge_fills
    $target.gross_pnl_usd += Convert-ToDecimal $Profile.gross_pnl_usd
    $target.total_fees_usd += Convert-ToDecimal $Profile.total_fees_usd
    $target.total_funding_usd += Convert-ToDecimal $Profile.total_funding_usd
    $target.total_slippage_usd += Convert-ToDecimal $Profile.total_slippage_usd
    $target.net_pnl_usd += Convert-ToDecimal $Profile.net_pnl_usd
    $target.max_drawdown_usd += Convert-ToDecimal $Profile.max_drawdown_usd

    if ($signals -gt 0) {
        $target.windows_with_signals += 1
    }
    if ($fills -gt 0) {
        $target.windows_with_entry_fills += 1
    }

    $diagnostics = $Profile.entry_fill_diagnostics
    if ($null -ne $diagnostics) {
        $diagnosticCount = [int]$diagnostics.count
        if ($diagnosticCount -gt 0) {
            $tradeDistance = $diagnostics.average_trade_distance_to_fill
            if ($null -ne $tradeDistance -and -not [string]::IsNullOrWhiteSpace([string]$tradeDistance)) {
                $target.trade_distance_sum += (Convert-ToDecimal $tradeDistance) * [decimal]$diagnosticCount
                $target.distance_samples += $diagnosticCount
            }

            $bookDistance = $diagnostics.average_book_distance_to_fill
            if ($null -ne $bookDistance -and -not [string]::IsNullOrWhiteSpace([string]$bookDistance)) {
                $target.book_distance_sum += (Convert-ToDecimal $bookDistance) * [decimal]$diagnosticCount
            }

            $secondsToExpiry = $diagnostics.average_seconds_to_order_expiry
            if ($null -ne $secondsToExpiry -and -not [string]::IsNullOrWhiteSpace([string]$secondsToExpiry)) {
                $target.seconds_to_expiry_sum += (Convert-ToDecimal $secondsToExpiry) * [decimal]$diagnosticCount
                $target.expiry_samples += $diagnosticCount
            }
        }

        $closestTrade = $diagnostics.closest_trade_distance_to_fill
        if ($null -ne $closestTrade -and -not [string]::IsNullOrWhiteSpace([string]$closestTrade)) {
            $closestTradeValue = Convert-ToDecimal $closestTrade
            if ($null -eq $target.closest_trade_distance_to_fill -or $closestTradeValue -lt $target.closest_trade_distance_to_fill) {
                $target.closest_trade_distance_to_fill = $closestTradeValue
            }
        }

        $closestBook = $diagnostics.closest_book_distance_to_fill
        if ($null -ne $closestBook -and -not [string]::IsNullOrWhiteSpace([string]$closestBook)) {
            $closestBookValue = Convert-ToDecimal $closestBook
            if ($null -eq $target.closest_book_distance_to_fill -or $closestBookValue -lt $target.closest_book_distance_to_fill) {
                $target.closest_book_distance_to_fill = $closestBookValue
            }
        }
    }
}

function Convert-ProfileTotals {
    param([Parameter(Mandatory = $true)]$Totals)

    @($Totals.Values | ForEach-Object {
        $orders = [int]$_.polymarket_orders
        $fills = [int]$_.polymarket_fills
        $hedgeAttempts = [int]$_.hedge_attempts
        $hedgeFills = [int]$_.hedge_fills
        $fillRate = if ($orders -gt 0) { [decimal]$fills / [decimal]$orders } else { [decimal]0 }
        $hedgeFillRate = if ($hedgeAttempts -gt 0) { [decimal]$hedgeFills / [decimal]$hedgeAttempts } else { [decimal]0 }
        $averageTradeDistance = if ([int]$_.distance_samples -gt 0) { $_.trade_distance_sum / [decimal]$_.distance_samples } else { $null }
        $averageBookDistance = if ([int]$_.distance_samples -gt 0) { $_.book_distance_sum / [decimal]$_.distance_samples } else { $null }
        $averageExpiry = if ([int]$_.expiry_samples -gt 0) { $_.seconds_to_expiry_sum / [decimal]$_.expiry_samples } else { $null }

        [pscustomobject]@{
            profile = [string]$_.profile
            comparisons = [int]$_.comparisons
            windows_with_signals = [int]$_.windows_with_signals
            windows_with_entry_fills = [int]$_.windows_with_entry_fills
            signal_count = [int]$_.signal_count
            polymarket_orders = $orders
            polymarket_fills = $fills
            fill_rate = $fillRate.ToString($InvariantCulture)
            hedge_attempts = $hedgeAttempts
            hedge_fills = $hedgeFills
            hedge_fill_rate = $hedgeFillRate.ToString($InvariantCulture)
            gross_pnl_usd = $_.gross_pnl_usd.ToString($InvariantCulture)
            total_fees_usd = $_.total_fees_usd.ToString($InvariantCulture)
            total_funding_usd = $_.total_funding_usd.ToString($InvariantCulture)
            total_slippage_usd = $_.total_slippage_usd.ToString($InvariantCulture)
            net_pnl_usd = $_.net_pnl_usd.ToString($InvariantCulture)
            max_drawdown_usd = $_.max_drawdown_usd.ToString($InvariantCulture)
            entry_fill_diagnostics = [pscustomobject]@{
                distance_samples = [int]$_.distance_samples
                average_trade_distance_to_fill = if ($null -ne $averageTradeDistance) { $averageTradeDistance.ToString($InvariantCulture) } else { $null }
                closest_trade_distance_to_fill = if ($null -ne $_.closest_trade_distance_to_fill) { $_.closest_trade_distance_to_fill.ToString($InvariantCulture) } else { $null }
                average_book_distance_to_fill = if ($null -ne $averageBookDistance) { $averageBookDistance.ToString($InvariantCulture) } else { $null }
                closest_book_distance_to_fill = if ($null -ne $_.closest_book_distance_to_fill) { $_.closest_book_distance_to_fill.ToString($InvariantCulture) } else { $null }
                average_seconds_to_order_expiry = if ($null -ne $averageExpiry) { $averageExpiry.ToString($InvariantCulture) } else { $null }
            }
        }
    } | Sort-Object profile)
}

function Select-HigherMetricWinner {
    param(
        [Parameter(Mandatory = $true)][object[]]$Profiles,
        [Parameter(Mandatory = $true)][scriptblock]$Value
    )

    $bestProfile = $null
    $bestValue = $null
    $winnerCount = 0
    foreach ($profile in $Profiles) {
        $currentValue = [decimal](& $Value $profile)
        if ($null -eq $bestValue -or $currentValue -gt $bestValue) {
            $bestValue = $currentValue
            $bestProfile = $profile
            $winnerCount = 1
            continue
        }
        if ($currentValue -eq $bestValue) {
            $winnerCount += 1
        }
    }

    if ($null -eq $bestProfile) {
        return $null
    }
    if ($winnerCount -gt 1) {
        return "tie"
    }
    [string]$bestProfile.profile
}

function Select-LowerMetricWinner {
    param(
        [Parameter(Mandatory = $true)][object[]]$Profiles,
        [Parameter(Mandatory = $true)][scriptblock]$Value
    )

    $bestProfile = $null
    $bestValue = $null
    $winnerCount = 0
    foreach ($profile in $Profiles) {
        $rawValue = & $Value $profile
        if ($null -eq $rawValue -or [string]::IsNullOrWhiteSpace([string]$rawValue)) {
            continue
        }
        $currentValue = Convert-ToDecimal $rawValue
        if ($null -eq $bestValue -or $currentValue -lt $bestValue) {
            $bestValue = $currentValue
            $bestProfile = $profile
            $winnerCount = 1
            continue
        }
        if ($currentValue -eq $bestValue) {
            $winnerCount += 1
        }
    }

    if ($null -eq $bestProfile) {
        return $null
    }
    if ($winnerCount -gt 1) {
        return "tie"
    }
    [string]$bestProfile.profile
}

function New-DiagnosticSummary {
    param(
        [int]$CompletedComparisons,
        [object[]]$ProfileTotals
    )

    if ($CompletedComparisons -eq 0) {
        return "No completed pullback comparisons; aggregate result is not usable."
    }

    $totalSignals = [int](@($ProfileTotals | ForEach-Object { [int]$_.signal_count } | Measure-Object -Sum).Sum)
    $totalFills = [int](@($ProfileTotals | ForEach-Object { [int]$_.polymarket_fills } | Measure-Object -Sum).Sum)
    if ($totalSignals -eq 0) {
        return "No pullback profile built signals across pinned windows; collect more signal windows before tuning pullback."
    }
    if ($totalFills -eq 0) {
        return "Signals were built, but no diagnostic pullback profile produced conservative trade_cross fills across pinned windows."
    }

    $bestByFills = Select-HigherMetricWinner -Profiles $ProfileTotals -Value { param($profile) [decimal]$profile.polymarket_fills }
    $bestByPnl = Select-HigherMetricWinner -Profiles $ProfileTotals -Value { param($profile) Convert-ToDecimal $profile.net_pnl_usd }
    "At least one pullback profile produced entry fills; inspect hedge fills and net PnL before changing baseline. best_by_fills=$bestByFills best_by_net_pnl=$bestByPnl."
}

function Invoke-PullbackComparison {
    param(
        [Parameter(Mandatory = $true)][int]$Index,
        [Parameter(Mandatory = $true)][string]$MarketPath
    )

    $attemptDirectoryRelative = Join-Path $ArtifactDirectory ("window-{0:D3}" -f $Index)
    $comparisonPathRelative = Join-Path $attemptDirectoryRelative "comparison.json"
    $args = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", $SingleComparatorScript,
        "-DatabaseUrl", $DatabaseUrl,
        "-MarketArtifactPath", $MarketPath,
        "-OutputPath", $comparisonPathRelative,
        "-ArtifactDirectory", $attemptDirectoryRelative,
        "-ReplayProfile", $ReplayProfile,
        "-LiquidationThresholdMinUsd", [string]$LiquidationThresholdMinUsd,
        "-LiquidationThresholdMaxUsd", [string]$LiquidationThresholdMaxUsd,
        "-PolymarketUsdPerPosition", [string]$PolymarketUsdPerPosition,
        "-OrderCancelWindowSeconds", [string]$OrderCancelWindowSeconds,
        "-MarketStaleAfterMinutes", [string]$MarketStaleAfterMinutes
    )

    $args += @("-PullbackPctCsv", (($PullbackPct | ForEach-Object { Format-Decimal $_ }) -join ","))
    if ($SkipPreflight) {
        $args += "-SkipPreflight"
    }
    if ($PrintCommandsOnly) {
        $args += "-PrintCommandsOnly"
    }

    $command = "powershell " + (Format-Command -Parts ([string[]]$args))
    if ($PrintCommandsOnly) {
        return [pscustomobject]@{
            window = $Index
            market_artifact_path = $MarketPath
            comparison_path = $comparisonPathRelative
            command = $command
        }
    }

    Write-Output "pullback aggregate window $Index command: $command"
    & powershell @args
    if ($LASTEXITCODE -ne 0) {
        throw "pullback comparison window $Index failed with exit code $LASTEXITCODE"
    }

    $comparisonFullPath = Resolve-RepoPath -Path $comparisonPathRelative
    if (-not (Test-Path -LiteralPath $comparisonFullPath)) {
        throw "pullback comparison did not write expected artifact: $comparisonFullPath"
    }
    Get-Content -Raw -LiteralPath $comparisonFullPath | ConvertFrom-Json
}

$marketPaths = @(Get-MarketArtifactPaths)
$plannedCommands = @()
$comparisons = [System.Collections.ArrayList]::new()
$failedComparisons = [System.Collections.ArrayList]::new()
$profileTotals = @{}

if (-not $PrintCommandsOnly -and -not (Test-Path -LiteralPath $ArtifactFullDirectory)) {
    New-Item -ItemType Directory -Force -Path $ArtifactFullDirectory | Out-Null
}

$index = 0
foreach ($marketPath in $marketPaths) {
    $index += 1
    try {
        $comparison = Invoke-PullbackComparison -Index $index -MarketPath $marketPath
        if ($PrintCommandsOnly) {
            $plannedCommands += $comparison
            continue
        }

        $comparisons.Add([pscustomobject]@{
            window = $index
            market_artifact_path = $marketPath
            market = $comparison.market
            best_by_entry_fills = $comparison.best_by_entry_fills
            best_by_net_pnl = $comparison.best_by_net_pnl
            closest_trade_distance_profile = $comparison.closest_trade_distance_profile
            diagnostic_summary = $comparison.diagnostic_summary
            profiles = $comparison.profiles
        }) | Out-Null

        foreach ($profile in @($comparison.profiles)) {
            Add-ProfileToTotals -Totals $profileTotals -Profile $profile
        }
    } catch {
        $failedComparisons.Add([pscustomobject]@{
            window = $index
            market_artifact_path = $marketPath
            error = $_.Exception.Message
        }) | Out-Null
        Write-Warning $_.Exception.Message
        if ($FailFast) {
            break
        }
    }
}

if ($PrintCommandsOnly) {
    [pscustomobject]@{
        generated_at = ([DateTime]::UtcNow.ToString("o"))
        diagnostic_only = $true
        market_artifact_paths = $marketPaths
        planned_commands = $plannedCommands
        output_path = [string]$OutputFullPath
    } | ConvertTo-Json -Depth 20
    return
}

$profileTotalObjects = @(Convert-ProfileTotals -Totals $profileTotals)
$completedComparisons = [int]$comparisons.Count
$bestByEntryFills = $null
$bestByNetPnl = $null
$closestTradeDistance = $null
if ($profileTotalObjects.Count -gt 0) {
    $bestByEntryFills = Select-HigherMetricWinner -Profiles $profileTotalObjects -Value { param($profile) [decimal]$profile.polymarket_fills }
    $bestByNetPnl = Select-HigherMetricWinner -Profiles $profileTotalObjects -Value { param($profile) Convert-ToDecimal $profile.net_pnl_usd }
    $closestTradeDistance = Select-LowerMetricWinner -Profiles $profileTotalObjects -Value {
        param($profile)
        $profile.entry_fill_diagnostics.closest_trade_distance_to_fill
    }
}

$aggregate = [pscustomObject]@{
    generated_at = ([DateTime]::UtcNow.ToString("o"))
    diagnostic_only = $true
    decision_note = "Pullback aggregate comparison is diagnostic-only; require more pinned signal windows, entry fills, hedge fills, and positive net PnL evidence before changing baseline defaults."
    market_artifact_paths = $marketPaths
    completed_comparisons = $completedComparisons
    failed_comparisons = [int]$failedComparisons.Count
    comparisons = @($comparisons)
    failures = @($failedComparisons)
    profile_totals = $profileTotalObjects
    best_by_entry_fills = $bestByEntryFills
    best_by_net_pnl = $bestByNetPnl
    closest_trade_distance_profile = $closestTradeDistance
    diagnostic_summary = New-DiagnosticSummary -CompletedComparisons $completedComparisons -ProfileTotals $profileTotalObjects
}

$parent = Split-Path -Parent $OutputFullPath
if ($parent -and -not (Test-Path -LiteralPath $parent)) {
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
}
$aggregate | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $OutputFullPath -Encoding UTF8

Write-Output "pullback aggregate comparison written: $OutputFullPath"
Write-Output "completed_comparisons=$($aggregate.completed_comparisons) failed_comparisons=$($aggregate.failed_comparisons)"
foreach ($profile in $aggregate.profile_totals) {
    Write-Output "profile=$($profile.profile) windows=$($profile.comparisons) signals=$($profile.signal_count) orders=$($profile.polymarket_orders) fills=$($profile.polymarket_fills) fill_rate=$($profile.fill_rate) hedge_fills=$($profile.hedge_fills) net_pnl_usd=$($profile.net_pnl_usd) avg_trade_distance=$($profile.entry_fill_diagnostics.average_trade_distance_to_fill) avg_seconds_to_expiry=$($profile.entry_fill_diagnostics.average_seconds_to_order_expiry)"
}
Write-Output "best_by_entry_fills=$($aggregate.best_by_entry_fills) best_by_net_pnl=$($aggregate.best_by_net_pnl) closest_trade_distance_profile=$($aggregate.closest_trade_distance_profile)"
Write-Output "diagnostic_summary=$($aggregate.diagnostic_summary)"
