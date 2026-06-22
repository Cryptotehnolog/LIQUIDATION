param()

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path (Join-Path $repoRoot "scripts") "market-data-report-history.ps1"
$tempDir = Join-Path ([IO.Path]::GetTempPath()) ("liq-market-data-history-test-" + [guid]::NewGuid().ToString("N"))

function Write-RunFixture {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$GeneratedAt,
        [Parameter(Mandatory = $true)][int]$BybitRaw,
        [Parameter(Mandatory = $true)][int]$BybitCanonical,
        [Parameter(Mandatory = $true)][int]$OkxRaw,
        [Parameter(Mandatory = $true)][int]$OkxCanonical,
        [Parameter(Mandatory = $true)][int]$OverlapBuckets
    )

    $runDir = Join-Path $Root $Name
    New-Item -ItemType Directory -Force -Path $runDir *> $null
    @"
# Nightly Market Data Check

- generated_at: $GeneratedAt
- bybit_status: ok
- okx_status: ok
- okx_metadata_valid: true
- bybit_raw_events: $BybitRaw
- bybit_canonical_events: $BybitCanonical
- okx_raw_events: $OkxRaw
- okx_canonical_events: $OkxCanonical
- overlap_buckets: $OverlapBuckets
"@ | Set-Content -LiteralPath (Join-Path $runDir "summary.md") -Encoding UTF8

    $buckets = @()
    for ($index = 0; $index -lt $OverlapBuckets; $index += 1) {
        $buckets += @{
            bucket_start = "2026-06-22T00:$($index.ToString("00")):00Z"
            primary_raw_events = 1
            primary_canonical_events = 1
            diagnostic_raw_events = 1
            diagnostic_canonical_events = 0
        }
    }

    @{
        window_seconds = 3600
        bucket_seconds = 60
        primary = @{
            source = "bybit"
            raw_events = $BybitRaw
            canonical_events = $BybitCanonical
        }
        diagnostic = @{
            source = "okx"
            raw_events = $OkxRaw
            canonical_events = $OkxCanonical
        }
        buckets = $buckets
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $runDir "overlap-report.json") -Encoding UTF8

    @{
        sources = @(
            @{ source = "bybit"; status = "ok" },
            @{ source = "okx"; status = "ok" }
        )
    } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $runDir "collector-status.json") -Encoding UTF8
}

New-Item -ItemType Directory -Force -Path $tempDir *> $null

try {
    Write-RunFixture -Root $tempDir -Name "run-1" -GeneratedAt "2026-06-22T01:00:00Z" -BybitRaw 3 -BybitCanonical 2 -OkxRaw 0 -OkxCanonical 0 -OverlapBuckets 1
    Write-RunFixture -Root $tempDir -Name "run-2" -GeneratedAt "2026-06-22T02:00:00Z" -BybitRaw 4 -BybitCanonical 3 -OkxRaw 2 -OkxCanonical 0 -OverlapBuckets 2
    Write-RunFixture -Root $tempDir -Name "run-3" -GeneratedAt "2026-06-22T03:00:00Z" -BybitRaw 5 -BybitCanonical 4 -OkxRaw 1 -OkxCanonical 0 -OverlapBuckets 3

    $outputPath = Join-Path $tempDir "trend.md"
    $jsonPath = Join-Path $tempDir "trend.json"
    $result = & $scriptPath `
        -InputRoot $tempDir `
        -OutputPath $outputPath `
        -JsonOutputPath $jsonPath `
        -MinRunsForSignal 3

    $resultJson = $result | ConvertFrom-Json
    if ($resultJson.conclusion -ne "useful-diagnostic") {
        throw "expected useful-diagnostic conclusion, got $($resultJson.conclusion)"
    }
    if (-not (Test-Path -LiteralPath $outputPath)) {
        throw "markdown trend report was not written"
    }
    if (-not (Test-Path -LiteralPath $jsonPath)) {
        throw "json trend report was not written"
    }

    $trend = Get-Content -Raw -LiteralPath $jsonPath | ConvertFrom-Json
    if ($trend.run_count -ne 3) {
        throw "expected three runs in trend JSON"
    }
    if ($trend.metrics.okx_raw_events -ne 3) {
        throw "expected aggregated OKX raw events to equal 3"
    }

    $markdown = Get-Content -Raw -LiteralPath $outputPath
    if (-not $markdown.Contains("OKX remains diagnostic-only")) {
        throw "markdown report must keep diagnostic-only warning visible"
    }

    Write-Host "market data report history test ok"
} finally {
    if (Test-Path -LiteralPath $tempDir) {
        Remove-Item -LiteralPath $tempDir -Recurse -Force
    }
}
