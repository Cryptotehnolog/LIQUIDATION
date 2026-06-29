param(
    [string]$OutputDir = ".cache/websocket-endpoint-contracts",
    [string]$FixtureDir = ""
)

$ErrorActionPreference = "Stop"

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls11 -bor [Net.SecurityProtocolType]::Tls
} catch {
    # PowerShell 7+ handles TLS through the platform HTTP stack.
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$sourcePath = Join-Path $repoRoot "crates\liq-collector\src\source.rs"

$contracts = @(
    [ordered]@{
        name = "binance_force_order"
        docs_url = "https://developers.binance.com/docs/derivatives/usds-margined-futures/websocket-market-streams/Important-WebSocket-Change-Notice"
        fixture = "binance-websocket-change-notice.html"
        code_terms = @("wss://fstream.binance.com/market/ws/", "@forceOrder")
        docs_terms = @("/market", "forceOrder")
    },
    [ordered]@{
        name = "bybit_all_liquidation"
        docs_url = "https://bybit-exchange.github.io/docs/v5/ws/connect"
        fixture = "bybit-all-liquidation.html"
        code_terms = @("wss://stream.bybit.com/v5/public/linear", "allLiquidation.")
        docs_terms = @("stream.bybit.com/v5/public/linear")
    },
    [ordered]@{
        name = "okx_liquidation_orders"
        docs_url = "https://www.okx.com/docs-v5/en/#public-data-websocket-liquidation-orders-channel"
        fixture = "okx-liquidation-orders.html"
        code_terms = @("wss://ws.okx.com:8443/ws/v5/public", "liquidation-orders")
        docs_terms = @("ws.okx.com:8443/ws/v5/public", "liquidation-orders")
    },
    [ordered]@{
        name = "bitget_uta_liquidation"
        docs_url = "https://www.bitget.com/api-doc/uta/websocket/public/Liquidation-Channel"
        fixture = "bitget-liquidation-channel.html"
        code_terms = @("wss://ws.bitget.com/v3/ws/public", "`"topic`":`"liquidation`"")
        docs_terms = @("wss://ws.bitget.com/v3/ws/public", "liquidation")
    }
)

function Read-EndpointDocs {
    param(
        [Parameter(Mandatory = $true)]$Contract,
        [string]$FixtureRoot
    )

    if (-not [string]::IsNullOrWhiteSpace($FixtureRoot)) {
        $fixturePath = Join-Path $FixtureRoot $Contract.fixture
        if (-not (Test-Path -LiteralPath $fixturePath)) {
            throw "Fixture not found for $($Contract.name): $fixturePath"
        }
        return Get-Content -Raw -LiteralPath $fixturePath
    }

    try {
        $response = Invoke-WebRequest `
            -Uri $Contract.docs_url `
            -Headers @{ "accept" = "text/html,application/json;q=0.9,*/*;q=0.8"; "user-agent" = "LIQUIDATION-websocket-endpoint-contracts/1.0" } `
            -TimeoutSec 30 `
            -UseBasicParsing
        return [string]$response.Content
    } catch {
        return Invoke-NodeFetch -Url $Contract.docs_url
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
  headers: { "accept": "text/html,application/json;q=0.9,*/*;q=0.8", "user-agent": "LIQUIDATION-websocket-endpoint-contracts/1.0" }
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

    $tempScript = Join-Path ([IO.Path]::GetTempPath()) ("liq-ws-contract-fetch-" + [guid]::NewGuid().ToString("N") + ".js")
    try {
        $nodeScript | Set-Content -LiteralPath $tempScript -Encoding UTF8
        $content = & node $tempScript $Url
        if ($LASTEXITCODE -ne 0) {
            throw "Node fetch failed for WebSocket endpoint docs URL: $Url"
        }
        return ($content -join "`n")
    } finally {
        if (Test-Path -LiteralPath $tempScript) {
            Remove-Item -LiteralPath $tempScript -Force
        }
    }
}

function Test-Terms {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string[]]$Terms
    )

    $lower = $Text.ToLowerInvariant()
    $missing = @($Terms | Where-Object { -not $lower.Contains($_.ToLowerInvariant()) })
    [ordered]@{
        ok = $missing.Count -eq 0
        missing = $missing
    }
}

$source = Get-Content -Raw -LiteralPath $sourcePath
$resolvedOutputDir = $OutputDir
New-Item -ItemType Directory -Force -Path $resolvedOutputDir | Out-Null

$results = New-Object System.Collections.Generic.List[object]
foreach ($contract in $contracts) {
    try {
        $docs = Read-EndpointDocs -Contract $contract -FixtureRoot $FixtureDir
        $codeCheck = Test-Terms -Text $source -Terms $contract.code_terms
        $docsCheck = Test-Terms -Text $docs -Terms $contract.docs_terms
        $results.Add([ordered]@{
            name = $contract.name
            status = if ($codeCheck.ok -and $docsCheck.ok) { "ok" } else { "warn" }
            docs_url = $contract.docs_url
            code_ok = $codeCheck.ok
            docs_ok = $docsCheck.ok
            missing_code_terms = @($codeCheck.missing)
            missing_docs_terms = @($docsCheck.missing)
            fetched_from = if ([string]::IsNullOrWhiteSpace($FixtureDir)) { "url" } else { "fixture" }
        })
    } catch {
        $results.Add([ordered]@{
            name = $contract.name
            status = "warn"
            docs_url = $contract.docs_url
            code_ok = $false
            docs_ok = $false
            missing_code_terms = @()
            missing_docs_terms = @()
            fetched_from = if ([string]::IsNullOrWhiteSpace($FixtureDir)) { "url" } else { "fixture" }
            error = $_.Exception.Message
        })
    }
}

$status = if (@($results | Where-Object { $_.status -ne "ok" }).Count -eq 0) { "ok" } else { "warn" }
$generatedAt = (Get-Date).ToUniversalTime().ToString("o")
$report = [ordered]@{
    generated_at = $generatedAt
    status = $status
    source_path = "crates/liq-collector/src/source.rs"
    contracts = @($results.ToArray())
}

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$jsonPath = Join-Path $resolvedOutputDir "websocket-endpoint-contracts.json"
$markdownPath = Join-Path $resolvedOutputDir "websocket-endpoint-contracts.md"
[IO.File]::WriteAllText($jsonPath, ($report | ConvertTo-Json -Depth 8), $utf8NoBom)

$rows = @($results | ForEach-Object {
    "| $($_.name) | $($_.status) | $($_.code_ok) | $($_.docs_ok) | $(@($_.missing_code_terms) -join ', ') | $(@($_.missing_docs_terms) -join ', ') |"
})
$markdown = @(
    "# WebSocket Endpoint Contracts",
    "",
    "- generated_at: $generatedAt",
    "- status: $status",
    "",
    "This guard checks that source code still uses the expected WebSocket base",
    "URLs and that current official docs still contain the endpoint contract",
    "terms we depend on.",
    "",
    "| contract | status | code_ok | docs_ok | missing_code_terms | missing_docs_terms |",
    "| --- | --- | --- | --- | --- | --- |"
) + $rows
[IO.File]::WriteAllText($markdownPath, ($markdown -join "`n"), $utf8NoBom)

$report | ConvertTo-Json -Depth 8
