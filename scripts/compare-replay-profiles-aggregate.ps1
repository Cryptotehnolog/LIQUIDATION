param(
    [string]$DatabaseUrl = $env:DATABASE_URL,
    [string]$OutputPath = ".cache/replay/profile-comparison-aggregate.json",
    [string]$ArtifactDirectory = ".cache/replay/profile-comparison-runs",
    [string]$OkxInstrumentsPath = ".cache/okx/instruments-BTC-USDT-SWAP.json",
    [int]$MaxComparisons = 3,
    [int]$MaxWindowsPerComparison = 6,
    [int]$MaxRuntimeSeconds = 330,
    [int]$MinFreshSeconds = 120,
    [int]$MaxWaitForFreshWindowSeconds = 360,
    [int]$PostWindowGraceSeconds = 10,
    [int]$DelayBetweenWindowsSeconds = 5,
    [int]$DelayBetweenComparisonsSeconds = 10,
    [int]$MarketStaleAfterMinutes = 15,
    [switch]$StopOnEntryFill,
    [switch]$FailFast,
    [switch]$PrintCommandsOnly
)

$ErrorActionPreference = "Stop"

$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$SingleComparisonScript = Join-Path $PSScriptRoot "compare-replay-profiles.ps1"
$OutputFullPath = Join-Path $RepoRoot $OutputPath
$ArtifactFullDirectory = Join-Path $RepoRoot $ArtifactDirectory

if (-not $DatabaseUrl) {
    throw "DatabaseUrl or DATABASE_URL is required"
}
if ($MaxComparisons -lt 1) {
    throw "MaxComparisons must be at least 1"
}
if ($MaxWindowsPerComparison -lt 1) {
    throw "MaxWindowsPerComparison must be at least 1"
}
if ($MaxRuntimeSeconds -lt 30) {
    throw "MaxRuntimeSeconds must be at least 30"
}
if (-not (Test-Path -LiteralPath $SingleComparisonScript)) {
    throw "Single-window comparator not found: $SingleComparisonScript"
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
        [System.Globalization.CultureInfo]::InvariantCulture
    )
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
    }
}

function Add-ProfileToTotals {
    param(
        [Parameter(Mandatory = $true)]$Totals,
        [Parameter(Mandatory = $true)]$RejectionTotals,
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

    if ($signals -gt 0) {
        $target.windows_with_signals += 1
    }
    if ($fills -gt 0) {
        $target.windows_with_entry_fills += 1
    }

    foreach ($reason in @($Profile.signal_rejection_reasons)) {
        $id = [string]$reason.id
        $stage = [string]$reason.stage
        $label = [string]$reason.label
        $key = "$profileName|$stage|$id|$label"
        if (-not $RejectionTotals.Contains($key)) {
            $RejectionTotals[$key] = [ordered]@{
                profile = $profileName
                stage = $stage
                id = $id
                label = $label
                count = 0
            }
        }
        $RejectionTotals[$key].count += [int]$reason.count
    }
}

function Convert-ProfileTotals {
    param([Parameter(Mandatory = $true)]$Totals)

    @($Totals.Values | ForEach-Object {
        $orders = [int]$_.polymarket_orders
        $fills = [int]$_.polymarket_fills
        $fillRate = if ($orders -gt 0) { [decimal]$fills / [decimal]$orders } else { [decimal]0 }
        [pscustomobject]@{
            profile = [string]$_.profile
            comparisons = [int]$_.comparisons
            windows_with_signals = [int]$_.windows_with_signals
            windows_with_entry_fills = [int]$_.windows_with_entry_fills
            signal_count = [int]$_.signal_count
            polymarket_orders = $orders
            polymarket_fills = $fills
            fill_rate = $fillRate.ToString([System.Globalization.CultureInfo]::InvariantCulture)
            hedge_attempts = [int]$_.hedge_attempts
            hedge_fills = [int]$_.hedge_fills
            gross_pnl_usd = $_.gross_pnl_usd.ToString([System.Globalization.CultureInfo]::InvariantCulture)
            total_fees_usd = $_.total_fees_usd.ToString([System.Globalization.CultureInfo]::InvariantCulture)
            total_funding_usd = $_.total_funding_usd.ToString([System.Globalization.CultureInfo]::InvariantCulture)
            total_slippage_usd = $_.total_slippage_usd.ToString([System.Globalization.CultureInfo]::InvariantCulture)
            net_pnl_usd = $_.net_pnl_usd.ToString([System.Globalization.CultureInfo]::InvariantCulture)
        }
    })
}

function Get-ProfileTotalByName {
    param(
        [Parameter(Mandatory = $true)][object[]]$ProfileTotals,
        [Parameter(Mandatory = $true)][string]$Name
    )

    @($ProfileTotals | Where-Object { $_.profile -eq $Name } | Select-Object -First 1)[0]
}

function Get-Delta {
    param(
        [object]$Baseline,
        [object]$Research,
        [Parameter(Mandatory = $true)][string]$Field
    )

    $researchValue = if ($null -ne $Research) { Convert-ToDecimal $Research.$Field } else { [decimal]0 }
    $baselineValue = if ($null -ne $Baseline) { Convert-ToDecimal $Baseline.$Field } else { [decimal]0 }
    ($researchValue - $baselineValue).ToString([System.Globalization.CultureInfo]::InvariantCulture)
}

function Get-DominantRejectionReasons {
    param([Parameter(Mandatory = $true)][object[]]$Reasons)

    @($Reasons |
        Sort-Object @{ Expression = { [int]$_.count }; Descending = $true }, profile, stage, id |
        Select-Object -First 10)
}

function New-DiagnosticSummary {
    param(
        [int]$CompletedComparisons,
        [object]$Baseline,
        [object]$Research,
        [object[]]$DominantReasons
    )

    if ($CompletedComparisons -eq 0) {
        return "No completed comparisons; aggregate result is not usable."
    }

    $baselineSignals = if ($null -ne $Baseline) { [int]$Baseline.signal_count } else { 0 }
    $researchSignals = if ($null -ne $Research) { [int]$Research.signal_count } else { 0 }
    $baselineFills = if ($null -ne $Baseline) { [int]$Baseline.polymarket_fills } else { 0 }
    $researchFills = if ($null -ne $Research) { [int]$Research.polymarket_fills } else { 0 }

    if (($baselineSignals + $researchSignals) -eq 0) {
        $topReason = @($DominantReasons | Select-Object -First 1)
        if ($topReason.Count -gt 0) {
            return "No signals were built across completed comparisons; dominant blocker is $($topReason[0].profile)/$($topReason[0].stage)/$($topReason[0].id) count=$($topReason[0].count)."
        }
        return "No signals were built across completed comparisons; no rejection reason was reported."
    }

    if (($baselineFills + $researchFills) -eq 0) {
        return "Signals were observed, but no Polymarket entry filled; do not infer profitability."
    }

    "At least one entry filled; inspect hedge fills and net PnL before changing baseline defaults."
}

function Invoke-ComparisonAttempt {
    param(
        [Parameter(Mandatory = $true)][int]$Attempt,
        [Parameter(Mandatory = $true)][string]$AttemptDirectoryRelative
    )

    $marketPath = Join-Path $AttemptDirectoryRelative "market.json"
    $baselinePath = Join-Path $AttemptDirectoryRelative "baseline.json"
    $researchPath = Join-Path $AttemptDirectoryRelative "research-wide-threshold.json"
    $comparisonPath = Join-Path $AttemptDirectoryRelative "comparison.json"

    $args = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", $SingleComparisonScript,
        "-DatabaseUrl", $DatabaseUrl,
        "-MarketArtifactPath", $marketPath,
        "-BaselineArtifactPath", $baselinePath,
        "-ResearchArtifactPath", $researchPath,
        "-OutputPath", $comparisonPath,
        "-OkxInstrumentsPath", $OkxInstrumentsPath,
        "-MaxWindows", [string]$MaxWindowsPerComparison,
        "-MaxRuntimeSeconds", [string]$MaxRuntimeSeconds,
        "-MinFreshSeconds", [string]$MinFreshSeconds,
        "-MaxWaitForFreshWindowSeconds", [string]$MaxWaitForFreshWindowSeconds,
        "-PostWindowGraceSeconds", [string]$PostWindowGraceSeconds,
        "-DelayBetweenWindowsSeconds", [string]$DelayBetweenWindowsSeconds,
        "-MarketStaleAfterMinutes", [string]$MarketStaleAfterMinutes
    )

    $command = "powershell " + (Format-Command -Parts $args)
    if ($PrintCommandsOnly) {
        return [pscustomobject]@{
            attempt = $Attempt
            status = "planned"
            comparison_artifact_path = [string](Join-Path $RepoRoot $comparisonPath)
            command = $command
            error = $null
        }
    }

    $attemptFullDirectory = Join-Path $RepoRoot $AttemptDirectoryRelative
    if (-not (Test-Path -LiteralPath $attemptFullDirectory)) {
        New-Item -ItemType Directory -Force -Path $attemptFullDirectory | Out-Null
    }

    Write-Output ("profile comparison attempt $Attempt/$MaxComparisons")
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        & powershell @args 2>&1 | ForEach-Object {
            Write-Output ([string]$_)
        }
        $childExitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    if ($childExitCode -ne 0) {
        throw "profile comparison attempt $Attempt failed with exit code $childExitCode"
    }

    $comparisonFullPath = Join-Path $RepoRoot $comparisonPath
    if (-not (Test-Path -LiteralPath $comparisonFullPath)) {
        throw "profile comparison attempt $Attempt did not write artifact: $comparisonFullPath"
    }

    $comparison = Get-Content -Raw -LiteralPath $comparisonFullPath | ConvertFrom-Json
    [pscustomobject]@{
        attempt = $Attempt
        status = "completed"
        comparison_artifact_path = [string]$comparisonFullPath
        market = $comparison.market
        higher_net_pnl_profile = [string]$comparison.higher_net_pnl_profile
        more_valid_signals_profile = [string]$comparison.more_valid_signals_profile
        more_entry_fills_profile = [string]$comparison.more_entry_fills_profile
        profiles = @($comparison.profiles)
        error = $null
    }
}

if (-not $PrintCommandsOnly -and -not (Test-Path -LiteralPath $ArtifactFullDirectory)) {
    New-Item -ItemType Directory -Force -Path $ArtifactFullDirectory | Out-Null
}

$attempts = @()
$profileTotals = @{}
$rejectionReasonTotals = @{}
$completedComparisons = 0
$failedComparisons = 0
$stoppedReason = "max_comparisons_reached"

for ($attempt = 1; $attempt -le $MaxComparisons; $attempt++) {
    $attemptDirectoryRelative = Join-Path $ArtifactDirectory ("attempt-{0:D3}" -f $attempt)
    try {
        $result = Invoke-ComparisonAttempt -Attempt $attempt -AttemptDirectoryRelative $attemptDirectoryRelative
        $attempts += $result

        if (-not $PrintCommandsOnly -and $result.status -eq "completed") {
            $completedComparisons += 1
            foreach ($profile in @($result.profiles)) {
                Add-ProfileToTotals -Totals $profileTotals -RejectionTotals $rejectionReasonTotals -Profile $profile
            }

            $filledProfiles = @($result.profiles | Where-Object { [int]$_.polymarket_fills -gt 0 })
            if ($StopOnEntryFill -and $filledProfiles.Count -gt 0) {
                $stoppedReason = "entry_fill_observed"
                break
            }
        }
    } catch {
        $failedComparisons += 1
        $attempts += [pscustomobject]@{
            attempt = $attempt
            status = "failed"
            comparison_artifact_path = [string](Join-Path $RepoRoot (Join-Path $attemptDirectoryRelative "comparison.json"))
            market = $null
            higher_net_pnl_profile = $null
            more_valid_signals_profile = $null
            more_entry_fills_profile = $null
            profiles = @()
            error = $_.Exception.Message
        }
        Write-Warning $_.Exception.Message
        if ($FailFast) {
            $stoppedReason = "failed_fast"
            break
        }
    }

    if (-not $PrintCommandsOnly -and $attempt -lt $MaxComparisons -and $DelayBetweenComparisonsSeconds -gt 0) {
        Start-Sleep -Seconds $DelayBetweenComparisonsSeconds
    }
}

if ($PrintCommandsOnly) {
    [pscustomobject]@{
        generated_at = ([DateTime]::UtcNow.ToString("o"))
        max_comparisons = $MaxComparisons
        planned_commands = @($attempts | ForEach-Object { $_.command })
        attempts = $attempts
    } | ConvertTo-Json -Depth 8
    return
}

$profileTotalObjects = Convert-ProfileTotals -Totals $profileTotals
$baselineTotal = Get-ProfileTotalByName -ProfileTotals $profileTotalObjects -Name "baseline"
$researchTotal = Get-ProfileTotalByName -ProfileTotals $profileTotalObjects -Name "research-wide-threshold"
$rejectionReasonObjects = @($rejectionReasonTotals.Values | ForEach-Object { [pscustomobject]$_ } | Sort-Object profile, stage, id)
$dominantRejectionReasons = Get-DominantRejectionReasons -Reasons $rejectionReasonObjects
$diagnosticSummary = New-DiagnosticSummary -CompletedComparisons $completedComparisons -Baseline $baselineTotal -Research $researchTotal -DominantReasons $dominantRejectionReasons

$aggregate = [pscustomobject]@{
    generated_at = ([DateTime]::UtcNow.ToString("o"))
    max_comparisons = $MaxComparisons
    completed_comparisons = $completedComparisons
    failed_comparisons = $failedComparisons
    stopped_reason = $stoppedReason
    attempts = $attempts
    profile_totals = $profileTotalObjects
    rejection_reasons_by_profile = $rejectionReasonObjects
    dominant_rejection_reasons = $dominantRejectionReasons
    baseline_vs_research_delta = [pscustomobject]@{
        signal_count = Get-Delta -Baseline $baselineTotal -Research $researchTotal -Field "signal_count"
        polymarket_orders = Get-Delta -Baseline $baselineTotal -Research $researchTotal -Field "polymarket_orders"
        polymarket_fills = Get-Delta -Baseline $baselineTotal -Research $researchTotal -Field "polymarket_fills"
        hedge_fills = Get-Delta -Baseline $baselineTotal -Research $researchTotal -Field "hedge_fills"
        net_pnl_usd = Get-Delta -Baseline $baselineTotal -Research $researchTotal -Field "net_pnl_usd"
    }
    diagnostic_summary = $diagnosticSummary
    decision_note = "Aggregate comparison is diagnostic; require filled entries, hedge path, and net PnL evidence before changing baseline defaults."
}

$parent = Split-Path -Parent $OutputFullPath
if ($parent -and -not (Test-Path -LiteralPath $parent)) {
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
}
$aggregate | ConvertTo-Json -Depth 40 | Set-Content -LiteralPath $OutputFullPath -Encoding UTF8

Write-Output "profile aggregate comparison written: $OutputFullPath"
Write-Output "completed_comparisons=$completedComparisons failed_comparisons=$failedComparisons stopped_reason=$stoppedReason"
Write-Output "diagnostic_summary=$diagnosticSummary"
foreach ($profile in $profileTotalObjects) {
    Write-Output "profile=$($profile.profile) comparisons=$($profile.comparisons) signals=$($profile.signal_count) orders=$($profile.polymarket_orders) fills=$($profile.polymarket_fills) fill_rate=$($profile.fill_rate) hedge_fills=$($profile.hedge_fills) net_pnl_usd=$($profile.net_pnl_usd)"
}
Write-Output "delta_signals=$($aggregate.baseline_vs_research_delta.signal_count) delta_fills=$($aggregate.baseline_vs_research_delta.polymarket_fills) delta_net_pnl_usd=$($aggregate.baseline_vs_research_delta.net_pnl_usd)"

if ($completedComparisons -eq 0) {
    exit 1
}
