param()

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path (Join-Path $repoRoot "scripts") "check-api-docs-changelog.ps1"
$tempDir = Join-Path ([IO.Path]::GetTempPath()) ("liq-api-docs-changelog-test-" + [guid]::NewGuid().ToString("N"))

function Get-TestSha256 {
    param([Parameter(Mandatory = $true)][string]$Text)

    $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash($bytes)
        return (($hash | ForEach-Object { $_.ToString("x2") }) -join "")
    } finally {
        $sha.Dispose()
    }
}

New-Item -ItemType Directory -Force -Path $tempDir *> $null

try {
    $fixtureDir = Join-Path $tempDir "fixtures"
    $outputDir = Join-Path $tempDir "out"
    New-Item -ItemType Directory -Force -Path $fixtureDir *> $null

    $stableBinance = "# Binance changelog`nNo relevant changes."
    $changedBinance = "# Binance changelog`nLiquidation Order Streams forceOrder websocket decommission notice."
    $stableBybit = "# Bybit changelog`nNo relevant changes."
    $stableOkx = "# OKX changelog`nNo relevant changes."

    Set-Content -LiteralPath (Join-Path $fixtureDir "binance-change-log.html") -Value $changedBinance -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $fixtureDir "bybit-v5-changelog.html") -Value $stableBybit -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $fixtureDir "okx-log-en.html") -Value $stableOkx -Encoding UTF8

    $baselinePath = Join-Path $tempDir "baseline.json"
    @{
        generated_at = "2026-06-22T00:00:00Z"
        sources = @(
            @{ name = "binance"; content_sha256 = Get-TestSha256 $stableBinance },
            @{ name = "bybit"; content_sha256 = Get-TestSha256 $stableBybit },
            @{ name = "okx"; content_sha256 = Get-TestSha256 $stableOkx }
        )
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $baselinePath -Encoding UTF8

    $result = & $scriptPath `
        -FixtureDir $fixtureDir `
        -BaselinePath $baselinePath `
        -OutputDir $outputDir

    $resultJson = $result | ConvertFrom-Json
    if ($resultJson.status -ne "warn") {
        throw "expected warn status for risky Binance docs change, got $($resultJson.status)"
    }

    $binance = @($resultJson.sources | Where-Object { $_.name -eq "binance" }) | Select-Object -First 1
    if (-not $binance.changed) {
        throw "expected Binance docs to be marked changed"
    }
    if ($binance.risk_level -ne "high") {
        throw "expected Binance risk_level=high, got $($binance.risk_level)"
    }
    if (-not (@($binance.risky_matches) -contains "liquidation")) {
        throw "expected liquidation keyword match"
    }

    foreach ($path in @("api-docs-changelog.json", "api-docs-changelog.md", "manifest-latest.json")) {
        if (-not (Test-Path -LiteralPath (Join-Path $outputDir $path))) {
            throw "expected $path to be written"
        }
    }

    Write-Host "api docs changelog test ok"
} finally {
    if (Test-Path -LiteralPath $tempDir) {
        Remove-Item -LiteralPath $tempDir -Recurse -Force
    }
}
