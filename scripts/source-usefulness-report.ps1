param(
    [string]$DatabaseUrl = $env:DATABASE_URL,
    [string]$PrimarySource = "bybit",
    [int]$WindowMinutes = 60,
    [int]$BucketSeconds = 60,
    [int]$StaleAfterSeconds = 120,
    [string]$ArtifactPath = ".cache/source-usefulness/latest.json",
    [switch]$Json
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($DatabaseUrl)) {
    throw "DatabaseUrl is required. Pass -DatabaseUrl or set DATABASE_URL."
}

if ($WindowMinutes -lt 1) {
    throw "WindowMinutes must be >= 1."
}

if ($BucketSeconds -lt 1) {
    throw "BucketSeconds must be >= 1."
}

if ($StaleAfterSeconds -lt 1) {
    throw "StaleAfterSeconds must be >= 1."
}

$args = @(
    "run", "-p", "liq-cli", "--",
    "collector", "usefulness-report",
    "--database-url", $DatabaseUrl,
    "--primary-source", $PrimarySource,
    "--window-minutes", "$WindowMinutes",
    "--bucket-seconds", "$BucketSeconds",
    "--stale-after-seconds", "$StaleAfterSeconds",
    "--artifact-path", $ArtifactPath
)

if ($Json) {
    $args += "--json"
}

cargo @args
