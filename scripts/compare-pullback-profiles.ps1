param(
    [string]$DatabaseUrl = $env:DATABASE_URL,
    [string]$MarketArtifactPath = ".cache/replay/latest-polymarket-market.json",
    [string]$OutputPath = ".cache/replay/pullback-profile-comparison.json",
    [string]$ArtifactDirectory = ".cache/replay/pullback-profile-comparison",
    [decimal[]]$PullbackPct = @(0.30, 0.20, 0.15, 0.10),
    [string]$PullbackPctCsv = "",
    [string]$ReplayProfile = "baseline",
    [decimal]$LiquidationThresholdMinUsd = 25000,
    [decimal]$LiquidationThresholdMaxUsd = 100000,
    [decimal]$PolymarketUsdPerPosition = 15,
    [int]$OrderCancelWindowSeconds = 60,
    [int]$MarketStaleAfterMinutes = 2880,
    [switch]$SkipPreflight,
    [switch]$PrintCommandsOnly
)

$ErrorActionPreference = "Stop"

$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$MarketArtifactFullPath = Join-Path $RepoRoot $MarketArtifactPath
$OutputFullPath = Join-Path $RepoRoot $OutputPath
$ArtifactFullDirectory = Join-Path $RepoRoot $ArtifactDirectory
$InvariantCulture = [System.Globalization.CultureInfo]::InvariantCulture

if (-not $DatabaseUrl) {
    throw "DatabaseUrl or DATABASE_URL is required"
}
$ResolvedPullbackPct = @($PullbackPct)
if ($PullbackPctCsv) {
    $ResolvedPullbackPct = @(
        [string]$PullbackPctCsv -split "," |
            ForEach-Object { ([string]$_).Trim() } |
            Where-Object { $_ } |
            ForEach-Object {
                [decimal]::Parse(
                    [string]$_,
                    [System.Globalization.NumberStyles]::Any,
                    $InvariantCulture
                )
            }
    )
}

if ($ResolvedPullbackPct.Count -lt 2) {
    throw "At least two pullback pct values are required"
}
foreach ($value in $ResolvedPullbackPct) {
    if ($value -lt 0 -or $value -ge 1) {
        throw "PullbackPct values must be greater than or equal to 0 and less than 1"
    }
}
if (@($ResolvedPullbackPct | Sort-Object -Unique).Count -ne $ResolvedPullbackPct.Count) {
    throw "PullbackPct values must be unique"
}

function Format-Command {
    param([Parameter(Mandatory = $true)][string[]]$Parts)

    ($Parts | ForEach-Object {
        if ($_ -match "\s") { '"' + ($_ -replace '"', '\"') + '"' } else { $_ }
    }) -join " "
}

function Format-Decimal {
    param([Parameter(Mandatory = $true)][decimal]$Value)

    $Value.ToString("0.00##", $InvariantCulture)
}

function Convert-ToDecimal {
    param([object]$Value)

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        return [decimal]0
    }
    [decimal]::Parse([string]$Value, [System.Globalization.NumberStyles]::Any, $InvariantCulture)
}

function Read-MarketArtifact {
    if (-not (Test-Path -LiteralPath $MarketArtifactFullPath)) {
        throw "Polymarket market artifact not found: $MarketArtifactFullPath"
    }

    $markets = @(Get-Content -Raw -LiteralPath $MarketArtifactFullPath | ConvertFrom-Json)
    if ($markets.Count -lt 1) {
        throw "Polymarket market artifact is empty: $MarketArtifactFullPath"
    }

    $market = $markets[0]
    foreach ($field in @("market_id", "up_token_id", "down_token_id", "start_ts", "end_ts")) {
        if (-not $market.$field) {
            throw "Polymarket market artifact is missing $field"
        }
    }
    $market
}

function Invoke-Checked {
    param(
        [Parameter(Mandatory = $true)][string]$Executable,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$Label
    )

    Write-Output ("$Label command: $Executable " + (Format-Command -Parts $Arguments))
    if ($PrintCommandsOnly) {
        return
    }

    & $Executable @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$Label failed with exit code $LASTEXITCODE"
    }
}

function Get-AverageDecimalText {
    param([object[]]$Values)

    $decimalValues = @($Values | Where-Object { $null -ne $_ -and -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { Convert-ToDecimal $_ })
    if ($decimalValues.Count -eq 0) {
        return $null
    }

    $sum = [decimal]0
    foreach ($value in $decimalValues) {
        $sum += $value
    }
    ($sum / [decimal]$decimalValues.Count).ToString($InvariantCulture)
}

function Get-MinDecimalText {
    param([object[]]$Values)

    $decimalValues = @($Values | Where-Object { $null -ne $_ -and -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { Convert-ToDecimal $_ })
    if ($decimalValues.Count -eq 0) {
        return $null
    }

    ($decimalValues | Sort-Object | Select-Object -First 1).ToString($InvariantCulture)
}

function Get-AverageIntegerText {
    param([object[]]$Values)

    $integerValues = @($Values | Where-Object { $null -ne $_ -and -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { [decimal]$_ })
    if ($integerValues.Count -eq 0) {
        return $null
    }

    $sum = [decimal]0
    foreach ($value in $integerValues) {
        $sum += $value
    }
    ($sum / [decimal]$integerValues.Count).ToString($InvariantCulture)
}

function Read-ReplaySummary {
    param(
        [Parameter(Mandatory = $true)][decimal]$Pullback,
        [Parameter(Mandatory = $true)][string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Replay artifact not found for pullback $(Format-Decimal $Pullback): $Path"
    }

    $artifact = Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json
    $orders = [int]$artifact.polymarket_orders
    $fills = [int]$artifact.polymarket_fills
    $fillRate = if ($orders -gt 0) { [decimal]$fills / [decimal]$orders } else { [decimal]0 }
    $diagnostics = @($artifact.trades | ForEach-Object { $_.entry_fill_diagnostics } | Where-Object { $null -ne $_ })

    [pscustomobject]@{
        profile = "pullback-$(Format-Decimal $Pullback)"
        pullback_pct = Format-Decimal $Pullback
        artifact_path = [string]$Path
        strategy_parameters = $artifact.strategy_parameters
        signal_count = [int]$artifact.signal_count
        polymarket_orders = $orders
        polymarket_fills = $fills
        fill_rate = $fillRate.ToString($InvariantCulture)
        hedge_attempts = [int]$artifact.hedge_attempts
        hedge_fills = [int]$artifact.hedge_fills
        gross_pnl_usd = [string]$artifact.gross_pnl_usd
        total_fees_usd = [string]$artifact.total_fees_usd
        total_funding_usd = [string]$artifact.total_funding_usd
        total_slippage_usd = [string]$artifact.total_slippage_usd
        net_pnl_usd = [string]$artifact.net_pnl_usd
        max_drawdown_usd = [string]$artifact.max_drawdown_usd
        settlement_status = [string]$artifact.settlement_status
        entry_fill_diagnostics = [pscustomobject]@{
            count = $diagnostics.Count
            average_seconds_to_order_expiry = Get-AverageIntegerText @($diagnostics | ForEach-Object { $_.seconds_to_order_expiry })
            average_trade_distance_to_fill = Get-AverageDecimalText @($diagnostics | ForEach-Object { $_.trade_distance_to_fill })
            closest_trade_distance_to_fill = Get-MinDecimalText @($diagnostics | ForEach-Object { $_.trade_distance_to_fill })
            average_book_distance_to_fill = Get-AverageDecimalText @($diagnostics | ForEach-Object { $_.book_distance_to_fill })
            closest_book_distance_to_fill = Get-MinDecimalText @($diagnostics | ForEach-Object { $_.book_distance_to_fill })
            total_trades_in_order_window = [int](@($diagnostics | ForEach-Object { [int]$_.trades_in_order_window } | Measure-Object -Sum).Sum)
            total_books_in_order_window = [int](@($diagnostics | ForEach-Object { [int]$_.books_in_order_window } | Measure-Object -Sum).Sum)
        }
        signal_rejection_reasons = @($artifact.signal_rejection_reasons)
    }
}

function New-DiagnosticSummary {
    param([Parameter(Mandatory = $true)][object[]]$Profiles)

    $totalSignals = [int](@($Profiles | ForEach-Object { [int]$_.signal_count } | Measure-Object -Sum).Sum)
    $totalFills = [int](@($Profiles | ForEach-Object { [int]$_.polymarket_fills } | Measure-Object -Sum).Sum)
    if ($totalSignals -eq 0) {
        return "No pullback profile built a signal on the pinned window; compare another signal_count > 0 window."
    }
    if ($totalFills -eq 0) {
        return "Signals were built, but no pullback profile produced a conservative trade_cross entry fill; compare more pinned signal windows before changing baseline."
    }
    "At least one pullback profile produced an entry fill; inspect hedge fills and net PnL before changing baseline defaults."
}

function Select-HigherMetricWinner {
    param(
        [Parameter(Mandatory = $true)][object[]]$Profiles,
        [Parameter(Mandatory = $true)][scriptblock]$Value
    )

    if ($Profiles.Count -eq 0) {
        return $null
    }

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
        if ($null -eq $rawValue) {
            continue
        }
        $currentValue = [decimal]$rawValue
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

$market = Read-MarketArtifact
$startUnixMs = ([DateTimeOffset]::Parse([string]$market.start_ts)).ToUnixTimeMilliseconds()
$endUnixMs = ([DateTimeOffset]::Parse([string]$market.end_ts)).ToUnixTimeMilliseconds()

$plannedCommands = @()
$profiles = @()

if (-not $PrintCommandsOnly -and -not (Test-Path -LiteralPath $ArtifactFullDirectory)) {
    New-Item -ItemType Directory -Force -Path $ArtifactFullDirectory | Out-Null
}

foreach ($pullback in $ResolvedPullbackPct) {
    $pullbackText = Format-Decimal $pullback
    $pullbackId = $pullbackText -replace "[^0-9A-Za-z]+", "_"
    $artifactPath = Join-Path $ArtifactFullDirectory "pullback-$pullbackId.json"

    $commonReplayArgs = @(
        "--database-url", $DatabaseUrl,
        "--strategy", "baseline",
        "--market-id", [string]$market.market_id,
        "--up-token-id", [string]$market.up_token_id,
        "--down-token-id", [string]$market.down_token_id,
        "--start-unix-ms", [string]$startUnixMs,
        "--end-unix-ms", [string]$endUnixMs,
        "--fill-model", "trade_cross",
        "--hedge-notional-usd", "15",
        "--hyperliquid-taker-bps", "5",
        "--hyperliquid-funding-bps-per-hour", "1",
        "--hedge-slippage-usd", "0.10",
        "--funding-hours", "1",
        "--market-stale-after-minutes", [string]$MarketStaleAfterMinutes,
        "--replay-profile", $ReplayProfile,
        "--liquidation-threshold-min-usd", [string]$LiquidationThresholdMinUsd,
        "--liquidation-threshold-max-usd", [string]$LiquidationThresholdMaxUsd,
        "--pullback-pct", $pullbackText,
        "--polymarket-usd-per-position", [string]$PolymarketUsdPerPosition,
        "--order-cancel-window-seconds", [string]$OrderCancelWindowSeconds,
        "--json"
    )

    if (-not $SkipPreflight) {
        $preflightArgs = @("run", "-p", "liq-cli", "--", "replay", "preflight") + $commonReplayArgs
        $plannedCommands += "cargo " + (Format-Command -Parts $preflightArgs)
        Invoke-Checked -Executable "cargo" -Arguments $preflightArgs -Label "pullback $pullbackText preflight"
    }

    if (-not $PrintCommandsOnly -and (Test-Path -LiteralPath $artifactPath)) {
        Remove-Item -LiteralPath $artifactPath -Force
    }

    $runArgs = @("run", "-p", "liq-cli", "--", "replay", "run") + $commonReplayArgs + @("--artifact-path", $artifactPath)
    $plannedCommands += "cargo " + (Format-Command -Parts $runArgs)
    Invoke-Checked -Executable "cargo" -Arguments $runArgs -Label "pullback $pullbackText replay"

    if (-not $PrintCommandsOnly) {
        $profiles += Read-ReplaySummary -Pullback $pullback -Path $artifactPath
    }
}

if ($PrintCommandsOnly) {
    [pscustomobject]@{
        generated_at = ([DateTime]::UtcNow.ToString("o"))
        diagnostic_only = $true
        market = [pscustomobject]@{
            market_id = [string]$market.market_id
            slug = [string]$market.slug
            start_ts = [string]$market.start_ts
            end_ts = [string]$market.end_ts
        }
        planned_commands = $plannedCommands
    } | ConvertTo-Json -Depth 8
    return
}

$bestByEntryFills = Select-HigherMetricWinner -Profiles $profiles -Value { param($profile) [decimal]$profile.polymarket_fills }
$bestByNetPnl = Select-HigherMetricWinner -Profiles $profiles -Value { param($profile) Convert-ToDecimal $profile.net_pnl_usd }
$closestTradeDistance = Select-LowerMetricWinner -Profiles $profiles -Value {
    param($profile)
    if ($null -eq $profile.entry_fill_diagnostics.closest_trade_distance_to_fill) {
        return $null
    }
    Convert-ToDecimal $profile.entry_fill_diagnostics.closest_trade_distance_to_fill
}

$comparison = [pscustomobject]@{
    generated_at = ([DateTime]::UtcNow.ToString("o"))
    diagnostic_only = $true
    decision_note = "Pullback profile comparison is diagnostic-only; require multiple pinned signal windows, entry fills, hedge fills, and net PnL evidence before changing baseline defaults."
    market = [pscustomobject]@{
        market_id = [string]$market.market_id
        slug = [string]$market.slug
        start_ts = [string]$market.start_ts
        end_ts = [string]$market.end_ts
    }
    replay_profile = $ReplayProfile
    profiles = $profiles
    best_by_entry_fills = $bestByEntryFills
    best_by_net_pnl = $bestByNetPnl
    closest_trade_distance_profile = $closestTradeDistance
    diagnostic_summary = New-DiagnosticSummary -Profiles $profiles
}

$parent = Split-Path -Parent $OutputFullPath
if ($parent -and -not (Test-Path -LiteralPath $parent)) {
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
}
$comparison | ConvertTo-Json -Depth 40 | Set-Content -LiteralPath $OutputFullPath -Encoding UTF8

Write-Output "pullback profile comparison written: $OutputFullPath"
Write-Output "market_id=$($comparison.market.market_id) start=$($comparison.market.start_ts) end=$($comparison.market.end_ts)"
foreach ($profile in $comparison.profiles) {
    Write-Output "profile=$($profile.profile) signals=$($profile.signal_count) orders=$($profile.polymarket_orders) fills=$($profile.polymarket_fills) fill_rate=$($profile.fill_rate) closest_trade_distance=$($profile.entry_fill_diagnostics.closest_trade_distance_to_fill) net_pnl_usd=$($profile.net_pnl_usd)"
}
Write-Output "best_by_entry_fills=$($comparison.best_by_entry_fills) best_by_net_pnl=$($comparison.best_by_net_pnl) closest_trade_distance_profile=$($comparison.closest_trade_distance_profile)"
Write-Output "diagnostic_summary=$($comparison.diagnostic_summary)"
