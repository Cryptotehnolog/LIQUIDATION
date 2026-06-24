param(
    [string]$DatabaseUrl = $env:DATABASE_URL,
    [string]$MarketArtifactPath = ".cache/replay/latest-polymarket-market.json",
    [string]$ReplayArtifactPath = ".cache/replay/latest-polymarket-baseline.json",
    [string]$OkxInstrumentsPath = ".cache/okx/instruments-BTC-USDT-SWAP.json",
    [int]$MaxWindows = 6,
    [int]$MaxRuntimeSeconds = 330,
    [int]$MinFreshSeconds = 120,
    [int]$MaxWaitForFreshWindowSeconds = 360,
    [int]$PostWindowGraceSeconds = 10,
    [int]$DelayBetweenWindowsSeconds = 5
)

$ErrorActionPreference = "Stop"

if (-not $DatabaseUrl) {
    throw "DatabaseUrl or DATABASE_URL is required"
}
if ($MaxWindows -lt 1) {
    throw "MaxWindows must be at least 1"
}

$collectScript = Join-Path $PSScriptRoot "collect-paper-replay-window.ps1"

function Test-EmptyLiquidationWindow {
    param([Parameter(Mandatory = $true)][string]$OutputText)

    # Continue automatically only when replay preflight failed because liquidations=0.
    return $OutputText -match '"id"\s*:\s*"liquidations"' -and
        $OutputText -match '"observed"\s*:\s*"0"'
}

for ($window = 1; $window -le $MaxWindows; $window++) {
    Write-Output "wait-for-liquidation replay window $window/$MaxWindows"

    $args = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", $collectScript,
        "-DatabaseUrl", $DatabaseUrl,
        "-MarketArtifactPath", $MarketArtifactPath,
        "-ArtifactPath", $ReplayArtifactPath,
        "-OkxInstrumentsPath", $OkxInstrumentsPath,
        "-MaxRuntimeSeconds", [string]$MaxRuntimeSeconds,
        "-MinFreshSeconds", [string]$MinFreshSeconds,
        "-MaxWaitForFreshWindowSeconds", [string]$MaxWaitForFreshWindowSeconds,
        "-PostWindowGraceSeconds", [string]$PostWindowGraceSeconds,
        "-RunReplay"
    )

    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $output = & powershell @args 2>&1
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    $output | ForEach-Object { Write-Output ([string]$_) }
    $outputText = ($output | Out-String)

    if ($exitCode -eq 0) {
        Write-Output "wait-for-liquidation replay succeeded on window $window"
        exit 0
    }

    if (-not (Test-EmptyLiquidationWindow -OutputText $outputText)) {
        throw "collect-paper-replay-window.ps1 failed for a reason other than liquidations=0; refusing to continue automatically"
    }

    if ($window -lt $MaxWindows) {
        Write-Output "liquidations=0; waiting $DelayBetweenWindowsSeconds seconds before next replay window"
        Start-Sleep -Seconds $DelayBetweenWindowsSeconds
    }
}

throw "No replay-ready liquidation window found after $MaxWindows attempt(s)"
