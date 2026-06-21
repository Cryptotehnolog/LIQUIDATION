param(
    [string]$EnvFile = "infra/aperag/.env.example",
    [switch]$RequireRuntime
)

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $PSCommandPath
$RepoRoot = Split-Path -Parent $ScriptDir
if (-not [System.IO.Path]::IsPathRooted($EnvFile)) {
    $EnvFile = [System.IO.Path]::GetFullPath((Join-Path $RepoRoot $EnvFile))
}

function Assert-True {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function New-Term {
    param([Parameter(Mandatory = $true)][int[]]$Codes)
    return -join ($Codes | ForEach-Object { [char]$_ })
}

$legacyTerms = @(
    (New-Term -Codes @(108,105,103,104,116,114,97,103)),
    (New-Term -Codes @(111,108,108,97,109,97)),
    (New-Term -Codes @(110,111,109,105,99)),
    (New-Term -Codes @(98,103,101,45,109,51)),
    (New-Term -Codes @(97,108,108,45,109,105,110,105,108,109)),
    (New-Term -Codes @(108,105,113,45,114,97,103)),
    (New-Term -Codes @(114,97,103,45,105,110,100,101,120))
)
$legacyPattern = ($legacyTerms | ForEach-Object { [regex]::Escape($_) }) -join "|"

$forbidden = rg -n -i $legacyPattern . `
    --glob "!.git/**" `
    --glob "!infra/aperag/data/**" `
    --glob "!docs/research/raw/**" `
    2>$null

Assert-True (-not $forbidden) "Forbidden legacy memory references remain:`n$($forbidden | Out-String)"

$guardCompose = Join-Path $ScriptDir "guard-compose.ps1"
$liqAperag = Join-Path $ScriptDir "liq-aperag.ps1"

& $guardCompose -EnvFile $EnvFile
if ($LASTEXITCODE -ne 0) {
    throw "compose guard failed"
}

$envLeaf = Split-Path -Leaf $EnvFile
$metadataPath = Join-Path $RepoRoot "docs/reports/aperag/index-metadata.json"
$adminSecretsPath = Join-Path $RepoRoot "infra/aperag/data/secrets/aperag-admin.env"
if ($envLeaf -ne ".env.example" -and (Test-Path -LiteralPath $EnvFile) -and (Test-Path -LiteralPath $metadataPath) -and (Test-Path -LiteralPath $adminSecretsPath)) {
    & $liqAperag status docs/ -EnvFile $EnvFile -CheckCommit -CheckDrift | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "ApeRAG runtime status/drift check failed"
    }
    Write-Output "ApeRAG runtime status/drift check passed"
} else {
    if ($RequireRuntime) {
        throw "ApeRAG runtime status/drift check required but unavailable. Use a real env file with metadata and admin secrets."
    }
    Write-Output "ApeRAG runtime drift check skipped: pass a real env file with metadata and admin secrets to enable it"
}

Write-Output "ApeRAG audit passed"
