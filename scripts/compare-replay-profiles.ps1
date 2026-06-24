param(
    [string]$DatabaseUrl = $env:DATABASE_URL,
    [string]$MarketArtifactPath = ".cache/replay/compare-polymarket-market.json",
    [string]$BaselineArtifactPath = ".cache/replay/compare-baseline.json",
    [string]$ResearchArtifactPath = ".cache/replay/compare-research-wide-threshold.json",
    [string]$OutputPath = ".cache/replay/profile-comparison.json",
    [string]$OkxInstrumentsPath = ".cache/okx/instruments-BTC-USDT-SWAP.json",
    [int]$MaxWindows = 6,
    [int]$MaxRuntimeSeconds = 330,
    [int]$MinFreshSeconds = 120,
    [int]$MaxWaitForFreshWindowSeconds = 360,
    [int]$PostWindowGraceSeconds = 10,
    [int]$DelayBetweenWindowsSeconds = 5,
    [int]$MarketStaleAfterMinutes = 15,
    [switch]$SkipCollect,
    [switch]$PrintCommandsOnly
)

$ErrorActionPreference = "Stop"

$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$WaitScript = Join-Path $PSScriptRoot "wait-for-liquidation-replay.ps1"
$MarketArtifactFullPath = Join-Path $RepoRoot $MarketArtifactPath
$BaselineArtifactFullPath = Join-Path $RepoRoot $BaselineArtifactPath
$ResearchArtifactFullPath = Join-Path $RepoRoot $ResearchArtifactPath
$OutputFullPath = Join-Path $RepoRoot $OutputPath

if (-not $DatabaseUrl) {
    throw "DatabaseUrl or DATABASE_URL is required"
}
if ($MaxWindows -lt 1) {
    throw "MaxWindows must be at least 1"
}
if ($MaxRuntimeSeconds -lt 30) {
    throw "MaxRuntimeSeconds must be at least 30"
}
if ($SkipCollect -and -not $PrintCommandsOnly -and -not (Test-Path -LiteralPath $BaselineArtifactFullPath)) {
    throw "SkipCollect requires existing baseline replay artifact: $BaselineArtifactFullPath"
}

function Format-Command {
    param([Parameter(Mandatory = $true)][string[]]$Parts)

    ($Parts | ForEach-Object {
        if ($_ -match "\s") { '"' + ($_ -replace '"', '\"') + '"' } else { $_ }
    }) -join " "
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

function Read-LatestMarketArtifact {
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

function Convert-ToDecimal {
    param([object]$Value)

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        return [decimal]0
    }
    [decimal]::Parse(
        [string]$Value,
        [System.Globalization.NumberStyles]::Any,
        [System.Globalization.CultureInfo]::InvariantCulture
    )
}

function Read-ReplaySummary {
    param(
        [Parameter(Mandatory = $true)][string]$Profile,
        [Parameter(Mandatory = $true)][string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Replay artifact not found for ${Profile}: $Path"
    }

    $artifact = Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json
    $orders = [int]$artifact.polymarket_orders
    $fills = [int]$artifact.polymarket_fills
    $fillRate = if ($orders -gt 0) {
        [decimal]$fills / [decimal]$orders
    } else {
        [decimal]0
    }

    [pscustomobject]@{
        profile = $Profile
        artifact_path = [string]$Path
        strategy_parameters = $artifact.strategy_parameters
        signal_count = [int]$artifact.signal_count
        polymarket_orders = $orders
        polymarket_fills = $fills
        fill_rate = $fillRate.ToString([System.Globalization.CultureInfo]::InvariantCulture)
        hedge_attempts = [int]$artifact.hedge_attempts
        hedge_fills = [int]$artifact.hedge_fills
        gross_pnl_usd = [string]$artifact.gross_pnl_usd
        total_fees_usd = [string]$artifact.total_fees_usd
        total_funding_usd = [string]$artifact.total_funding_usd
        total_slippage_usd = [string]$artifact.total_slippage_usd
        net_pnl_usd = [string]$artifact.net_pnl_usd
        max_drawdown_usd = [string]$artifact.max_drawdown_usd
        settlement_status = [string]$artifact.settlement_status
        run_summary = @($artifact.run_summary)
        signal_rejection_reasons = @($artifact.signal_rejection_reasons)
    }
}

function Select-BetterProfile {
    param(
        [Parameter(Mandatory = $true)][object]$Baseline,
        [Parameter(Mandatory = $true)][object]$Research,
        [Parameter(Mandatory = $true)][string]$Metric
    )

    $baselineValue = Convert-ToDecimal $Baseline.$Metric
    $researchValue = Convert-ToDecimal $Research.$Metric
    if ($researchValue -gt $baselineValue) {
        return "research-wide-threshold"
    }
    if ($baselineValue -gt $researchValue) {
        return "baseline"
    }
    "tie"
}

if (-not $SkipCollect) {
    if (Test-Path -LiteralPath $BaselineArtifactFullPath) {
        Remove-Item -LiteralPath $BaselineArtifactFullPath -Force
    }
    if (Test-Path -LiteralPath $ResearchArtifactFullPath) {
        Remove-Item -LiteralPath $ResearchArtifactFullPath -Force
    }

    $baselineArgs = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", $WaitScript,
        "-DatabaseUrl", $DatabaseUrl,
        "-MarketArtifactPath", $MarketArtifactPath,
        "-ReplayArtifactPath", $BaselineArtifactPath,
        "-OkxInstrumentsPath", $OkxInstrumentsPath,
        "-MaxWindows", [string]$MaxWindows,
        "-MaxRuntimeSeconds", [string]$MaxRuntimeSeconds,
        "-MinFreshSeconds", [string]$MinFreshSeconds,
        "-MaxWaitForFreshWindowSeconds", [string]$MaxWaitForFreshWindowSeconds,
        "-PostWindowGraceSeconds", [string]$PostWindowGraceSeconds,
        "-DelayBetweenWindowsSeconds", [string]$DelayBetweenWindowsSeconds,
        "-ReplayProfile", "baseline",
        "-RunReplay"
    )
    Invoke-Checked -Executable "powershell" -Arguments $baselineArgs -Label "baseline collect/replay"
}

if ($PrintCommandsOnly) {
    return
}

$market = Read-LatestMarketArtifact
$startUnixMs = ([DateTimeOffset]::Parse([string]$market.start_ts)).ToUnixTimeMilliseconds()
$endUnixMs = ([DateTimeOffset]::Parse([string]$market.end_ts)).ToUnixTimeMilliseconds()

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
    "--replay-profile", "research-wide-threshold",
    "--json"
)

$researchPreflightArgs = @("run", "-p", "liq-cli", "--", "replay", "preflight") + $commonReplayArgs
Invoke-Checked -Executable "cargo" -Arguments $researchPreflightArgs -Label "research-wide-threshold preflight"

if (-not $PrintCommandsOnly -and (Test-Path -LiteralPath $ResearchArtifactFullPath)) {
    Remove-Item -LiteralPath $ResearchArtifactFullPath -Force
}
$researchRunArgs = @("run", "-p", "liq-cli", "--", "replay", "run") + $commonReplayArgs + @("--artifact-path", $ResearchArtifactFullPath)
Invoke-Checked -Executable "cargo" -Arguments $researchRunArgs -Label "research-wide-threshold replay"

if ($PrintCommandsOnly) {
    return
}

$baseline = Read-ReplaySummary -Profile "baseline" -Path $BaselineArtifactFullPath
$research = Read-ReplaySummary -Profile "research-wide-threshold" -Path $ResearchArtifactFullPath
$baselineNet = Convert-ToDecimal $baseline.net_pnl_usd
$researchNet = Convert-ToDecimal $research.net_pnl_usd

$comparison = [pscustomobject]@{
    generated_at = ([DateTime]::UtcNow.ToString("o"))
    market = [pscustomobject]@{
        market_id = [string]$market.market_id
        slug = [string]$market.slug
        start_ts = [string]$market.start_ts
        end_ts = [string]$market.end_ts
    }
    baseline_artifact_path = [string]$BaselineArtifactFullPath
    research_artifact_path = [string]$ResearchArtifactFullPath
    profiles = @($baseline, $research)
    deltas = [pscustomobject]@{
        signal_count = [int]$research.signal_count - [int]$baseline.signal_count
        polymarket_orders = [int]$research.polymarket_orders - [int]$baseline.polymarket_orders
        polymarket_fills = [int]$research.polymarket_fills - [int]$baseline.polymarket_fills
        hedge_fills = [int]$research.hedge_fills - [int]$baseline.hedge_fills
        net_pnl_usd = ($researchNet - $baselineNet).ToString([System.Globalization.CultureInfo]::InvariantCulture)
    }
    higher_net_pnl_profile = Select-BetterProfile -Baseline $baseline -Research $research -Metric "net_pnl_usd"
    more_valid_signals_profile = if ([int]$research.signal_count -gt [int]$baseline.signal_count) {
        "research-wide-threshold"
    } elseif ([int]$baseline.signal_count -gt [int]$research.signal_count) {
        "baseline"
    } else {
        "tie"
    }
    more_entry_fills_profile = if ([int]$research.polymarket_fills -gt [int]$baseline.polymarket_fills) {
        "research-wide-threshold"
    } elseif ([int]$baseline.polymarket_fills -gt [int]$research.polymarket_fills) {
        "baseline"
    } else {
        "tie"
    }
    decision_note = "research-wide-threshold is diagnostic only; compare economics before changing baseline defaults"
}

$parent = Split-Path -Parent $OutputFullPath
if ($parent -and -not (Test-Path -LiteralPath $parent)) {
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
}
$comparison | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $OutputFullPath -Encoding UTF8

Write-Output "profile comparison written: $OutputFullPath"
Write-Output "market_id=$($comparison.market.market_id) start=$($comparison.market.start_ts) end=$($comparison.market.end_ts)"
foreach ($profile in $comparison.profiles) {
    Write-Output "profile=$($profile.profile) signals=$($profile.signal_count) orders=$($profile.polymarket_orders) fills=$($profile.polymarket_fills) fill_rate=$($profile.fill_rate) hedge_fills=$($profile.hedge_fills) net_pnl_usd=$($profile.net_pnl_usd)"
}
Write-Output "delta_signals=$($comparison.deltas.signal_count) delta_fills=$($comparison.deltas.polymarket_fills) delta_net_pnl_usd=$($comparison.deltas.net_pnl_usd)"
Write-Output "higher_net_pnl_profile=$($comparison.higher_net_pnl_profile) more_valid_signals_profile=$($comparison.more_valid_signals_profile) more_entry_fills_profile=$($comparison.more_entry_fills_profile)"
