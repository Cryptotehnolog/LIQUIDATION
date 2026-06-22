param(
    [Parameter(Mandatory = $true)][string]$Symbol,
    [string]$OutputPath,
    [string]$InputPath,
    [string]$InstType = "SWAP",
    [int]$TimeoutSeconds = 30
)

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

function Get-BaseAsset {
    param([Parameter(Mandatory = $true)][string]$InstrumentId)

    $parts = $InstrumentId.Split("-")
    if ($parts.Count -lt 2 -or [string]::IsNullOrWhiteSpace($parts[0])) {
        throw "OKX symbol must look like BASE-QUOTE-SWAP: $InstrumentId"
    }

    return $parts[0]
}

function Test-PositiveDecimalString {
    param(
        [Parameter(Mandatory = $true)][string]$Field,
        [Parameter(Mandatory = $true)][string]$Value
    )

    if ($Value -notmatch '^[0-9]+(\.[0-9]+)?$') {
        throw "OKX instruments validation failed: $Field must be a positive decimal string"
    }

    $parsed = [decimal]::Parse($Value, [Globalization.CultureInfo]::InvariantCulture)
    if ($parsed -le 0) {
        throw "OKX instruments validation failed: $Field must be greater than zero"
    }
}

function Get-OkxInstrumentsViaNode {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds
    )

    $nodeScript = @"
const url = process.argv[2];
const timeoutMs = Number(process.argv[3]) * 1000;
const controller = new AbortController();
const timer = setTimeout(() => controller.abort(), timeoutMs);
fetch(url, {
  signal: controller.signal,
  headers: { "accept": "application/json", "user-agent": "LIQUIDATION-okx-instruments-fetcher/1.0" }
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

    $tempScript = Join-Path ([IO.Path]::GetTempPath()) ("liq-okx-fetch-" + [guid]::NewGuid().ToString("N") + ".js")
    try {
        $nodeScript | Set-Content -LiteralPath $tempScript -Encoding UTF8
        $content = & node $tempScript $Url $TimeoutSeconds
        if ($LASTEXITCODE -ne 0) {
            throw "Node fetch failed for OKX instruments URL: $Url"
        }

        return ($content -join "`n")
    } finally {
        if (Test-Path -LiteralPath $tempScript) {
            Remove-Item -LiteralPath $tempScript -Force
        }
    }
}

function Get-OkxInstrumentsPayload {
    param(
        [string]$InputPath,
        [string]$Url,
        [int]$TimeoutSeconds
    )

    if (-not [string]::IsNullOrWhiteSpace($InputPath)) {
        if (-not (Test-Path -LiteralPath $InputPath)) {
            throw "InputPath does not exist: $InputPath"
        }
        return Get-Content -Raw -LiteralPath $InputPath
    }

    return Get-OkxInstrumentsViaNode -Url $Url -TimeoutSeconds $TimeoutSeconds
}

function Assert-OkxInstrumentsPayload {
    param(
        [Parameter(Mandatory = $true)][string]$Payload,
        [Parameter(Mandatory = $true)][string]$Symbol,
        [Parameter(Mandatory = $true)][string]$InstType
    )

    $json = $Payload | ConvertFrom-Json
    if ([string]$json.code -ne "0") {
        throw "OKX instruments validation failed: expected code=0, got code=$($json.code)"
    }
    if ($null -eq $json.data) {
        throw "OKX instruments validation failed: missing data array"
    }

    $items = @($json.data | Where-Object { $_.instId -eq $Symbol })
    if ($items.Count -ne 1) {
        throw "OKX instruments validation failed: expected exactly one $Symbol item, got $($items.Count)"
    }

    $item = $items[0]
    if ([string]$item.instType -ne $InstType) {
        throw "OKX instruments validation failed: expected instType=$InstType, got $($item.instType)"
    }
    if ([string]::IsNullOrWhiteSpace([string]$item.ctVal)) {
        throw "OKX instruments validation failed: missing ctVal"
    }
    if ([string]::IsNullOrWhiteSpace([string]$item.ctValCcy)) {
        throw "OKX instruments validation failed: missing ctValCcy"
    }

    Test-PositiveDecimalString -Field "ctVal" -Value ([string]$item.ctVal)

    $baseAsset = Get-BaseAsset -InstrumentId $Symbol
    if ([string]$item.ctValCcy -ne $baseAsset) {
        throw "OKX instruments validation failed: ctValCcy=$($item.ctValCcy) does not match base asset $baseAsset"
    }
}

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path ".cache\okx" ("instruments-" + $Symbol + ".json")
}

$encodedInstType = [uri]::EscapeDataString($InstType)
$encodedSymbol = [uri]::EscapeDataString($Symbol)
$url = "https://www.okx.com/api/v5/public/instruments?instType=$encodedInstType&instId=$encodedSymbol"
$payload = Get-OkxInstrumentsPayload -InputPath $InputPath -Url $url -TimeoutSeconds $TimeoutSeconds
Assert-OkxInstrumentsPayload -Payload $payload -Symbol $Symbol -InstType $InstType

$resolvedOutput = if ([IO.Path]::IsPathRooted($OutputPath)) {
    $OutputPath
} else {
    Join-Path $repoRoot $OutputPath
}
$outputDir = Split-Path -Parent $resolvedOutput
if (-not [string]::IsNullOrWhiteSpace($outputDir)) {
    New-Item -ItemType Directory -Force -Path $outputDir *> $null
}

$tempPath = $resolvedOutput + ".tmp"
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[IO.File]::WriteAllText($tempPath, $payload, $utf8NoBom)
Move-Item -LiteralPath $tempPath -Destination $resolvedOutput -Force

Write-Output (@{
    status = "ok"
    symbol = $Symbol
    inst_type = $InstType
    output_path = $resolvedOutput
    source = if ([string]::IsNullOrWhiteSpace($InputPath)) { "okx_api" } else { "input_path" }
} | ConvertTo-Json -Compress)
