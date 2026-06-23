param(
    [Parameter(Mandatory = $true)]
    [string]$MarketArtifactPath,

    [int]$StaleAfterMinutes = 15,

    [switch]$FailOnStale,

    [switch]$Json
)

$ErrorActionPreference = "Stop"

if ($StaleAfterMinutes -lt 1) {
    throw "StaleAfterMinutes must be at least 1"
}

if (-not (Test-Path -LiteralPath $MarketArtifactPath)) {
    throw "Polymarket market artifact not found: $MarketArtifactPath"
}

$payload = Get-Content -Raw -LiteralPath $MarketArtifactPath | ConvertFrom-Json
$markets = @($payload)
if ($markets.Count -eq 0) {
    throw "Polymarket market artifact contains no markets: $MarketArtifactPath"
}

$latest = $markets |
    Sort-Object -Property @{ Expression = { [DateTimeOffset]::Parse($_.end_ts) } } -Descending |
    Select-Object -First 1

$endTs = [DateTimeOffset]::Parse($latest.end_ts)
$now = [DateTimeOffset]::UtcNow
$ageMinutes = [math]::Max(0, [math]::Floor(($now - $endTs).TotalMinutes))
$isStale = $ageMinutes -gt $StaleAfterMinutes

$result = [ordered]@{
    status = if ($isStale) { "stale" } else { "ok" }
    market_id = [string]$latest.market_id
    start_ts = [string]$latest.start_ts
    end_ts = [string]$latest.end_ts
    age_minutes = [int]$ageMinutes
    stale_after_minutes = $StaleAfterMinutes
    warning = if ($isStale) {
        "latest Polymarket market metadata is stale: age=$ageMinutes min threshold=$StaleAfterMinutes min"
    } else {
        $null
    }
}

if ($Json) {
    $result | ConvertTo-Json -Depth 4
} elseif ($isStale) {
    Write-Warning $result.warning
} else {
    Write-Output "Polymarket market metadata freshness ok: market=$($result.market_id) age=$ageMinutes min"
}

if ($FailOnStale -and $isStale) {
    exit 1
}
