param(
    [string]$BaselinePath = "docs/research/api-docs-baseline.json",
    [string]$OutputDir = ".cache/api-docs-changelog",
    [string]$FixtureDir = "",
    [switch]$UpdateBaseline
)

$ErrorActionPreference = "Stop"

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls11 -bor [Net.SecurityProtocolType]::Tls
} catch {
    # PowerShell 7+ handles TLS through the platform HTTP stack.
}

$sources = @(
    [ordered]@{
        name = "binance"
        url = "https://developers.binance.com/docs/derivatives/change-log"
        fixture = "binance-change-log.html"
        risk_terms = @("breaking", "deprecated", "decommission", "delisted", "removed", "forceorder", "liquidation", "websocket")
    },
    [ordered]@{
        name = "bybit"
        url = "https://bybit-exchange.github.io/docs/changelog/v5"
        fixture = "bybit-v5-changelog.html"
        risk_terms = @("breaking", "deprecated", "decommission", "delisted", "removed", "liquidation", "websocket")
    },
    [ordered]@{
        name = "okx"
        url = "https://www.okx.com/docs-v5/log_en/"
        fixture = "okx-log-en.html"
        risk_terms = @("breaking", "deprecated", "decommission", "delisted", "removed", "liquidation", "liquidation-orders", "websocket")
    }
)

function Get-Sha256Hex {
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

function Read-Baseline {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return @{}
    }

    $json = Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json
    $map = @{}
    foreach ($source in @($json.sources)) {
        if (-not [string]::IsNullOrWhiteSpace($source.name)) {
            $map[$source.name] = $source
        }
    }
    return $map
}

function Read-SourceContent {
    param(
        [Parameter(Mandatory = $true)]$Source,
        [string]$FixtureRoot
    )

    if (-not [string]::IsNullOrWhiteSpace($FixtureRoot)) {
        $fixturePath = Join-Path $FixtureRoot $Source.fixture
        if (-not (Test-Path -LiteralPath $fixturePath)) {
            throw "Fixture not found for $($Source.name): $fixturePath"
        }
        return Get-Content -Raw -LiteralPath $fixturePath
    }

    try {
        $response = Invoke-WebRequest `
            -Uri $Source.url `
            -Headers @{ "accept" = "text/html,application/json;q=0.9,*/*;q=0.8"; "user-agent" = "LIQUIDATION-api-docs-watch/1.0" } `
            -TimeoutSec 30 `
            -UseBasicParsing

        return [string]$response.Content
    } catch {
        return Invoke-NodeFetch -Url $Source.url
    }
}

function Invoke-NodeFetch {
    param([Parameter(Mandatory = $true)][string]$Url)

    $nodeScript = @"
const url = process.argv[2];
const controller = new AbortController();
const timer = setTimeout(() => controller.abort(), 30000);
fetch(url, {
  signal: controller.signal,
  headers: { "accept": "text/html,application/json;q=0.9,*/*;q=0.8", "user-agent": "LIQUIDATION-api-docs-watch/1.0" }
}).then(async (response) => {
  const body = await response.text();
  if (!response.ok) {
    console.error(body);
    process.exit(2);
  }
  process.stdout.write(body);
}).catch((error) => {
  console.error(error && error.stack ? error.stack : String(error));
  process.exit(1);
}).finally(() => clearTimeout(timer));
"@

    $tempScript = Join-Path ([IO.Path]::GetTempPath()) ("liq-api-docs-fetch-" + [guid]::NewGuid().ToString("N") + ".js")
    try {
        $nodeScript | Set-Content -LiteralPath $tempScript -Encoding UTF8
        $content = & node $tempScript $Url
        if ($LASTEXITCODE -ne 0) {
            throw "Node fetch failed for API docs URL: $Url"
        }
        return ($content -join "`n")
    } finally {
        if (Test-Path -LiteralPath $tempScript) {
            Remove-Item -LiteralPath $tempScript -Force
        }
    }
}

function Find-RiskyMatches {
    param(
        [Parameter(Mandatory = $true)][string]$Content,
        [Parameter(Mandatory = $true)][string[]]$Terms
    )

    $lower = $Content.ToLowerInvariant()
    return @($Terms | Where-Object { $lower.Contains($_.ToLowerInvariant()) } | Sort-Object -Unique)
}

$resolvedOutputDir = $OutputDir
New-Item -ItemType Directory -Force -Path $resolvedOutputDir | Out-Null

$baseline = Read-Baseline $BaselinePath
$results = New-Object System.Collections.Generic.List[object]

foreach ($source in $sources) {
    try {
        $content = Read-SourceContent -Source $source -FixtureRoot $FixtureDir
        $sha = Get-Sha256Hex $content
        $previous = if ($baseline.ContainsKey($source.name)) { $baseline[$source.name] } else { $null }
        $previousSha = if ($previous) { [string]$previous.content_sha256 } else { "" }
        $changed = -not [string]::IsNullOrWhiteSpace($previousSha) -and $previousSha -ne $sha
        $riskyMatches = Find-RiskyMatches -Content $content -Terms $source.risk_terms
        $riskLevel = if ($changed -and @($riskyMatches).Count -gt 0) {
            "high"
        } elseif ($changed) {
            "medium"
        } elseif (-not $previous) {
            "baseline-missing"
        } else {
            "low"
        }
        $status = if ($riskLevel -eq "high") { "warn" } elseif ($riskLevel -eq "medium") { "warn" } else { "ok" }

        $results.Add([ordered]@{
            name = $source.name
            url = $source.url
            status = $status
            changed = $changed
            risk_level = $riskLevel
            risky_matches = @($riskyMatches)
            content_sha256 = $sha
            previous_sha256 = $previousSha
            bytes = [Text.Encoding]::UTF8.GetByteCount($content)
            fetched_from = if ([string]::IsNullOrWhiteSpace($FixtureDir)) { "url" } else { "fixture" }
        })
    } catch {
        $results.Add([ordered]@{
            name = $source.name
            url = $source.url
            status = "warn"
            changed = $false
            risk_level = "fetch-error"
            risky_matches = @()
            content_sha256 = ""
            previous_sha256 = ""
            bytes = 0
            fetched_from = if ([string]::IsNullOrWhiteSpace($FixtureDir)) { "url" } else { "fixture" }
            error = $_.Exception.Message
        })
    }
}

$status = if (@($results | Where-Object { $_.status -eq "warn" }).Count -gt 0) { "warn" } else { "ok" }
$generatedAt = (Get-Date).ToUniversalTime().ToString("o")
$report = [ordered]@{
    generated_at = $generatedAt
    status = $status
    baseline_path = $BaselinePath
    sources = @($results.ToArray())
}

$jsonPath = Join-Path $resolvedOutputDir "api-docs-changelog.json"
$markdownPath = Join-Path $resolvedOutputDir "api-docs-changelog.md"
$manifestPath = Join-Path $resolvedOutputDir "manifest-latest.json"

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[IO.File]::WriteAllText($jsonPath, ($report | ConvertTo-Json -Depth 8), $utf8NoBom)

$manifest = [ordered]@{
    generated_at = $generatedAt
    sources = @($results | ForEach-Object {
        [ordered]@{
            name = $_.name
            url = $_.url
            content_sha256 = $_.content_sha256
            bytes = $_.bytes
        }
    })
}
[IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 8), $utf8NoBom)

if ($UpdateBaseline -and @($results | Where-Object { [string]::IsNullOrWhiteSpace($_.content_sha256) }).Count -gt 0) {
    throw "Refusing to update API docs baseline because at least one source was not fetched successfully."
}

if ($UpdateBaseline) {
    $baselineDir = Split-Path -Parent $BaselinePath
    if (-not [string]::IsNullOrWhiteSpace($baselineDir)) {
        New-Item -ItemType Directory -Force -Path $baselineDir | Out-Null
    }
    [IO.File]::WriteAllText($BaselinePath, ($manifest | ConvertTo-Json -Depth 8), $utf8NoBom)
}

$rows = @($results | ForEach-Object {
    "| $($_.name) | $($_.status) | $($_.changed) | $($_.risk_level) | $(@($_.risky_matches) -join ', ') | $($_.bytes) |"
})
$markdown = @(
    "# API Docs Changelog Watch",
    "",
    "- generated_at: $generatedAt",
    "- status: $status",
    "- baseline_path: $BaselinePath",
    "",
    "This report watches official exchange docs/changelogs for source changes",
    "that may affect liquidation collectors. A warning is a review trigger, not",
    "automatic proof that runtime behavior changed.",
    "",
    "| source | status | changed | risk_level | risky_matches | bytes |",
    "| --- | --- | --- | --- | --- | --- |"
) + $rows
[IO.File]::WriteAllText($markdownPath, ($markdown -join "`n"), $utf8NoBom)

$report | ConvertTo-Json -Depth 8
