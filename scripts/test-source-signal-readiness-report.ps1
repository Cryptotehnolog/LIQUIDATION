$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot

function Assert-True {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Assert-Equal {
    param(
        [Parameter(Mandatory = $true)]$Actual,
        [Parameter(Mandatory = $true)]$Expected,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if ($Actual -ne $Expected) {
        throw "$Message. Expected '$Expected', got '$Actual'."
    }
}

$scripts = @(
    "scripts/analyze-source-signal-readiness.ps1",
    "scripts/source-signal-readiness-report.ps1"
)

foreach ($relative in $scripts) {
    $path = Join-Path $repoRoot $relative
    Assert-True (Test-Path -LiteralPath $path) "$relative must exist"
    $tokens = $null
    $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$parseErrors) | Out-Null
    Assert-True ($parseErrors.Count -eq 0) "$relative has PowerShell parse errors: $($parseErrors | ConvertTo-Json -Compress)"
}

$tmpRoot = Join-Path $repoRoot ".cache\test-source-signal-readiness"
New-Item -ItemType Directory -Force -Path $tmpRoot *> $null

$artifactPath = Join-Path $tmpRoot "source-usefulness.json"
$analysisPath = Join-Path $tmpRoot "analysis.json"
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

$fixture = [pscustomobject]@{
    primary_source = "bybit"
    window_seconds = 7200
    bucket_seconds = 60
    stale_after_seconds = 120
    sources = @(
        [pscustomobject]@{
            source = "bybit"
            symbols = @("BTCUSDT")
            source_quality = "all_events"
            coverage_role = "strategy_primary"
            participates_in_signals = $true
            health_rows = 2
            raw_events = 10
            canonical_events = 3
            max_notional_usd = "125000"
            liquidation_ready_buckets_without_primary = 0
            verdict = "strategy-primary"
        },
        [pscustomobject]@{
            source = "binance"
            symbols = @("BTCUSDT")
            source_quality = "snapshot_only"
            coverage_role = "diagnostic_only"
            participates_in_signals = $false
            health_rows = 2
            raw_events = 4
            canonical_events = 2
            max_notional_usd = "30000"
            liquidation_ready_buckets_without_primary = 0
            verdict = "overlapping-diagnostic"
        },
        [pscustomobject]@{
            source = "okx"
            symbols = @("BTC-USDT-SWAP")
            source_quality = "websocket_only"
            coverage_role = "diagnostic_only"
            participates_in_signals = $false
            health_rows = 2
            raw_events = 3
            canonical_events = 1
            max_notional_usd = "50000"
            liquidation_ready_buckets_without_primary = 1
            verdict = "useful-diagnostic"
        },
        [pscustomobject]@{
            source = "bitget"
            symbols = @("BTCUSDT")
            source_quality = "snapshot_only"
            coverage_role = "diagnostic_only"
            participates_in_signals = $false
            health_rows = 2
            raw_events = 5
            canonical_events = 2
            max_notional_usd = "79000"
            liquidation_ready_buckets_without_primary = 2
            verdict = "useful-diagnostic"
        },
        [pscustomobject]@{
            source = "gate"
            symbols = @("BTC_USDT")
            source_quality = "websocket_only"
            coverage_role = "diagnostic_only"
            participates_in_signals = $false
            health_rows = 1
            raw_events = 1
            canonical_events = 0
            max_notional_usd = $null
            liquidation_ready_buckets_without_primary = 0
            verdict = "raw-only-diagnostic"
        }
    )
}

[IO.File]::WriteAllText($artifactPath, ($fixture | ConvertTo-Json -Depth 16), $utf8NoBom)

& (Join-Path $repoRoot "scripts/analyze-source-signal-readiness.ps1") `
    -SourceUsefulnessArtifactPath $artifactPath `
    -OutputPath $analysisPath `
    -Json *> $null

Assert-True (Test-Path -LiteralPath $analysisPath) "analyzer must write JSON artifact"
$analysis = Get-Content -Raw -LiteralPath $analysisPath | ConvertFrom-Json

Assert-Equal ([int]$analysis.report_count) 1 "analysis must count input reports"
Assert-True (-not @($analysis.included_sources).Contains("htx")) "HTX must not be part of current default source set"
Assert-Equal ([int]$analysis.totals.signal_ready_windows_proxy) 3 "analysis must aggregate additive signal-ready proxy buckets"
Assert-Equal ([int]$analysis.sources.bitget.signal_ready_windows_proxy) 2 "Bitget contribution must be visible"
Assert-Equal ([int]$analysis.sources.okx.signal_ready_windows_proxy) 1 "OKX contribution must be visible"
Assert-Equal ([string]$analysis.htx_decision.classification) "defer_htx" "HTX must stay deferred when current sources add signal-ready proxy buckets"

$wrapper = Get-Content -Raw -LiteralPath (Join-Path $repoRoot "scripts/source-signal-readiness-report.ps1")
Assert-True ($wrapper.Contains("source-usefulness-report.ps1")) "wrapper must reuse source-usefulness-report.ps1"
Assert-True ($wrapper.Contains("analyze-source-signal-readiness.ps1")) "wrapper must run the signal-readiness analyzer"
Assert-True ($wrapper.Contains('"bybit", "binance", "okx", "bitget", "gate"')) "wrapper defaults must include current sources and exclude HTX"
Assert-True ($wrapper.Contains("if (-not `$Json)")) "wrapper must suppress source-usefulness text output when -Json is requested"

Write-Output "source signal readiness report checks passed"
