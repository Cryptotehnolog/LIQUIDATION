param(
    [string]$DatabaseUrl = $env:REPLAY_DATABASE_URL,

    [string]$Repository = "Cryptotehnolog/LIQUIDATION"
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($DatabaseUrl)) {
    throw "DatabaseUrl or REPLAY_DATABASE_URL is required. Use a database reachable from GitHub Actions, not local 127.0.0.1."
}

$uri = [Uri]$DatabaseUrl
if ($uri.Host -in @("127.0.0.1", "localhost", "::1")) {
    throw "Refusing to store local database URL in GitHub secret: $($uri.Host). GitHub Actions cannot reach your local machine."
}

$ghProject = Join-Path $PSScriptRoot "gh-project.ps1"
& $ghProject secret set REPLAY_DATABASE_URL --repo $Repository --body $DatabaseUrl
if ($LASTEXITCODE -ne 0) {
    throw "gh secret set failed with exit code $LASTEXITCODE"
}

Write-Output "GitHub secret REPLAY_DATABASE_URL updated for $Repository"
