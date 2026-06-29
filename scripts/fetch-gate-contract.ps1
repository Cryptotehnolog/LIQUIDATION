param(
    [Parameter(Mandatory = $true)][string]$Contract,
    [string]$OutputPath,
    [string]$InputPath,
    [string]$Settle = "usdt",
    [int]$TimeoutSeconds = 30
)

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

function Test-PositiveDecimalString {
    param(
        [Parameter(Mandatory = $true)][string]$Field,
        [Parameter(Mandatory = $true)][string]$Value
    )

    if ($Value -notmatch '^[0-9]+(\.[0-9]+)?$') {
        throw "Gate contract validation failed: $Field must be a positive decimal string"
    }

    $parsed = [decimal]::Parse($Value, [Globalization.CultureInfo]::InvariantCulture)
    if ($parsed -le 0) {
        throw "Gate contract validation failed: $Field must be greater than zero"
    }
}

function Get-GateContractViaNode {
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
  headers: { "accept": "application/json", "user-agent": "LIQUIDATION-gate-contract-fetcher/1.0" }
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

    $tempScript = Join-Path ([IO.Path]::GetTempPath()) ("liq-gate-fetch-" + [guid]::NewGuid().ToString("N") + ".js")
    try {
        $nodeScript | Set-Content -LiteralPath $tempScript -Encoding UTF8
        $content = & node $tempScript $Url $TimeoutSeconds
        if ($LASTEXITCODE -ne 0) {
            throw "Node fetch failed for Gate contract URL: $Url"
        }

        return ($content -join "`n")
    } finally {
        if (Test-Path -LiteralPath $tempScript) {
            Remove-Item -LiteralPath $tempScript -Force
        }
    }
}

function Get-GateContractPayload {
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

    return Get-GateContractViaNode -Url $Url -TimeoutSeconds $TimeoutSeconds
}

function Assert-GateContractPayload {
    param(
        [Parameter(Mandatory = $true)][string]$Payload,
        [Parameter(Mandatory = $true)][string]$Contract
    )

    $json = $Payload | ConvertFrom-Json
    if ([string]$json.name -ne $Contract) {
        throw "Gate contract validation failed: expected name=$Contract, got name=$($json.name)"
    }
    if ([string]::IsNullOrWhiteSpace([string]$json.quanto_multiplier)) {
        throw "Gate contract validation failed: missing quanto_multiplier"
    }

    Test-PositiveDecimalString -Field "quanto_multiplier" -Value ([string]$json.quanto_multiplier)
}

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path ".cache\gate" ("contract-" + $Contract + ".json")
}

$encodedSettle = [uri]::EscapeDataString($Settle.ToLowerInvariant())
$encodedContract = [uri]::EscapeDataString($Contract)
$url = "https://api.gateio.ws/api/v4/futures/$encodedSettle/contracts/$encodedContract"
$payload = Get-GateContractPayload -InputPath $InputPath -Url $url -TimeoutSeconds $TimeoutSeconds
Assert-GateContractPayload -Payload $payload -Contract $Contract

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
    contract = $Contract
    settle = $Settle.ToLowerInvariant()
    output_path = $resolvedOutput
    source = if ([string]::IsNullOrWhiteSpace($InputPath)) { "gate_api" } else { "input_path" }
} | ConvertTo-Json -Compress)
