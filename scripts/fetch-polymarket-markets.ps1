param(
    [string]$DatabaseUrl = $env:DATABASE_URL,
    [string]$EndpointUrl = "https://gamma-api.polymarket.com/markets",
    [string]$FixturePath,
    [string]$OutputPath,
    [switch]$Apply,
    [switch]$AllMatches,
    [switch]$Json
)

$ErrorActionPreference = "Stop"

function Invoke-LiqMarketFetch {
    param([switch]$ApplyRun)

    $args = @(
        "run", "-p", "liq-cli", "--",
        "replay", "market", "fetch",
        "--endpoint-url", $EndpointUrl
    )
    if ($FixturePath) {
        $args += @("--fixture-path", $FixturePath)
    }
    if ($OutputPath) {
        $args += @("--output-path", $OutputPath)
    }
    if ($AllMatches) {
        $args += "--all-matches"
    }
    if ($Json) {
        $args += "--json"
    }
    if ($ApplyRun) {
        if (-not $DatabaseUrl) {
            throw "DatabaseUrl or DATABASE_URL is required when -Apply is set"
        }
        $args += @("--database-url", $DatabaseUrl, "--apply")
    }

    & cargo @args
    if ($LASTEXITCODE -ne 0) {
        throw "liq replay market fetch failed with exit code $LASTEXITCODE"
    }
}

Invoke-LiqMarketFetch
if ($Apply) {
    Invoke-LiqMarketFetch -ApplyRun
}
