param(
    [string]$EnvFile = "infra/lightrag/.env",
    [string]$ExampleEnvFile = "infra/lightrag/.env.example"
)

$ErrorActionPreference = "Stop"

function Write-Section {
    param([Parameter(Mandatory = $true)][string]$Name)
    Write-Output ""
    Write-Output "== $Name =="
}

function Read-DotEnv {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path $Path)) {
        throw "Env file not found: $Path"
    }

    $values = @{}
    foreach ($line in Get-Content $Path) {
        $trimmed = $line.Trim()
        if ($trimmed -eq "" -or $trimmed.StartsWith("#")) {
            continue
        }

        $parts = $trimmed -split "=", 2
        if ($parts.Count -eq 2) {
            $values[$parts[0]] = $parts[1].Trim('"').Trim("'")
        }
    }

    return $values
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

function Invoke-Step {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$Script
    )

    Write-Section $Name
    & $Script
}

if (-not (Test-Path "scripts/liq-rag.ps1")) {
    throw "Run this script from repository root"
}

Invoke-Step "compose guard" {
    & .\scripts\guard-compose.ps1 -EnvFile $ExampleEnvFile
}

Invoke-Step "health" {
    & .\scripts\liq-rag.ps1 health -EnvFile $EnvFile
}

Invoke-Step "status" {
    & .\scripts\liq-rag.ps1 status --check-commit -EnvFile $EnvFile
}

Invoke-Step "eval" {
    & .\scripts\liq-rag.ps1 eval -EnvFile $EnvFile
}

Invoke-Step "secret scan" {
    $patterns = @(
        "gh[oprus]_[A-Za-z0-9_]{20,}",
        "sk-[A-Za-z0-9]{20,}",
        "AKIA[0-9A-Z]{16}",
        "BEGIN (RSA|OPENSSH|PRIVATE) KEY"
    )

    $matches = @()
    foreach ($pattern in $patterns) {
        $output = rg -n --hidden --glob "!infra/lightrag/data/**" --glob "!infra/lightrag/backups/**" --glob "!docs/reports/rag/*.json" --glob "!.git/**" $pattern . 2>$null
        if ($LASTEXITCODE -eq 0) {
            $matches += $output
        } elseif ($LASTEXITCODE -gt 1) {
            throw "secret scan failed for pattern: $pattern"
        }
    }

    if ($matches.Count -gt 0) {
        $matches | ForEach-Object { Write-Output $_ }
        throw "secret scan found potential secrets"
    }

    Write-Output "secret scan passed"
}

Invoke-Step "docs/env consistency" {
    $envExample = Read-DotEnv $ExampleEnvFile
    $compose = Get-Content -Raw -LiteralPath "infra/lightrag/compose.yml"
    $ragOperations = Get-Content -Raw -LiteralPath "docs/runbooks/rag-operations.md"
    $lightRagMemory = Get-Content -Raw -LiteralPath "docs/runbooks/lightrag-dev-memory.md"
    $deployment = Get-Content -Raw -LiteralPath "docs/reports/rag/2026-06-19-deployment.md"

    Assert-True ($envExample["LIGHTRAG_EMBEDDING_BINDING"] -eq "ollama") ".env.example must use Ollama embeddings"
    Assert-True ($envExample["LIGHTRAG_EMBEDDING_MODEL"] -eq "all-minilm") ".env.example must use all-minilm"
    Assert-True ($envExample["LIGHTRAG_EMBEDDING_DIM"] -eq "384") ".env.example must set all-minilm dimension"
    Assert-True ($envExample["LIGHTRAG_EMBEDDING_BINDING_HOST"] -eq "http://host.docker.internal:11434") ".env.example must point Docker LightRAG to host Ollama"
    Assert-True (-not $compose.Contains("liquidation-embeddings:")) "compose must not include old hash embedding service"
    Assert-True ($ragOperations.Contains("all-minilm")) "rag-operations must document all-minilm"
    Assert-True ($lightRagMemory.Contains("FreeDeepseek availability is diagnostic-only")) "lightrag-dev-memory must not overstate fallback usability"
    Assert-True ($deployment.Contains("all-minilm")) "deployment report must document all-minilm"
    Assert-True (-not $ragOperations.Contains("liquidation-hash-embedding-1024")) "rag-operations must not document old hash model as active"

    Write-Output "docs/env consistency passed"
}

Invoke-Step "PowerShell parse" {
    $failed = @()
    foreach ($file in Get-ChildItem scripts -Filter *.ps1) {
        $errors = $null
        [System.Management.Automation.PSParser]::Tokenize((Get-Content -Raw $file.FullName), [ref]$errors) | Out-Null
        if ($errors) {
            $failed += [pscustomobject]@{
                file = $file.FullName
                errors = ($errors | ForEach-Object { $_.Message }) -join "; "
            }
        }
    }

    if ($failed.Count -gt 0) {
        $failed | ConvertTo-Json -Depth 5
        throw "PowerShell parse check failed"
    }

    Write-Output "PowerShell parse check passed"
}

Write-Output ""
Write-Output "RAG audit passed"
