param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]] $GhArgs
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$env:GH_CONFIG_DIR = Join-Path $repoRoot ".cache\gh-cli"
New-Item -ItemType Directory -Force -Path $env:GH_CONFIG_DIR | Out-Null

Set-Location $repoRoot
& gh @GhArgs
exit $LASTEXITCODE
