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
    & .\scripts\guard-compose.ps1 -EnvFile $EnvFile
}

Invoke-Step "status" {
    & .\scripts\liq-rag.ps1 status --check-commit -EnvFile $EnvFile
}

Invoke-Step "eval" {
    & .\scripts\liq-rag.ps1 eval -EnvFile $EnvFile
}

Invoke-Step "health" {
    & .\scripts\liq-rag.ps1 health -EnvFile $EnvFile
}

Invoke-Step "report integrity" {
    $envActive = Read-DotEnv $EnvFile
    $reportDir = "docs/reports/rag"
    if ($envActive.ContainsKey("LIGHTRAG_REPORT_PATH") -and -not [string]::IsNullOrWhiteSpace($envActive["LIGHTRAG_REPORT_PATH"])) {
        $reportDir = $envActive["LIGHTRAG_REPORT_PATH"]
    }

    $metadataPath = Join-Path $reportDir "index-metadata.json"
    $evalPath = Join-Path $reportDir "eval-report.json"
    $healthPath = Join-Path $reportDir "health-report.json"

    Assert-True (Test-Path $metadataPath) "metadata report is missing"
    Assert-True (Test-Path $evalPath) "eval report is missing"
    Assert-True (Test-Path $healthPath) "health report is missing"

    $metadata = Get-Content -Raw -LiteralPath $metadataPath | ConvertFrom-Json
    $eval = Get-Content -Raw -LiteralPath $evalPath | ConvertFrom-Json
    $health = Get-Content -Raw -LiteralPath $healthPath | ConvertFrom-Json

    Assert-True ($metadata.status -eq "indexed") "metadata status must be indexed"
    Assert-True ($metadata.ingestion_config_version -eq "lightrag-dev-memory-v2") "metadata must include current ingestion config version"
    Assert-True ($metadata.sentinel_retrieval_ok -eq $true) "metadata must include passing sentinel retrieval"
    Assert-True ([int]$metadata.indexed_counts.processed -gt 0) "metadata must record processed indexed documents"
    Assert-True ([int]$metadata.indexed_counts.all -ge [int]$metadata.mirror.copied_files) "metadata indexed count must cover mirrored docs"

    Assert-True ($eval.status -eq "passed") "eval report must pass"
    Assert-True ($eval.real_lightrag_retrieval -eq $true) "eval must use real LightRAG retrieval"
    Assert-True ($eval.docs_tree_hash -eq $metadata.docs_tree_hash) "eval docs hash must match metadata docs hash"

    Assert-True ($health.status -eq "ok") "health report must be ok"
    Assert-True ($health.freshness.docs_tree_hash_match -eq $true) "health freshness must confirm docs tree hash"
    Assert-True ([int]$health.freshness.indexed_processed -gt 0) "health freshness must confirm nonempty index"
    Assert-True ($health.embeddings.embedding_dimension_match -eq $true) "health must confirm embedding dimension"
    Assert-True ($health.omniroute.chat_completion_ok -eq $true) "health must confirm Omniroute chat completion"

    Write-Output "report integrity passed"
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
    $envActive = Read-DotEnv $EnvFile
    $compose = Get-Content -Raw -LiteralPath "infra/lightrag/compose.yml"
    $ragOperations = Get-Content -Raw -LiteralPath "docs/runbooks/rag-operations.md"
    $lightRagMemory = Get-Content -Raw -LiteralPath "docs/runbooks/lightrag-dev-memory.md"
    $deployment = Get-Content -Raw -LiteralPath "docs/reports/rag/2026-06-19-deployment.md"

    Assert-True ($envExample["LIGHTRAG_EMBEDDING_BINDING"] -eq "ollama") ".env.example must use Ollama embeddings"
    Assert-True ($envExample["LIGHTRAG_EMBEDDING_MODEL"] -eq "nomic-embed-text") ".env.example must use nomic-embed-text"
    Assert-True ($envExample["LIGHTRAG_EMBEDDING_DIM"] -eq "768") ".env.example must set nomic-embed-text dimension"
    Assert-True ($envExample["LIGHTRAG_EMBEDDING_BINDING_HOST"] -eq "http://host.docker.internal:11434") ".env.example must point Docker LightRAG to host Ollama"
    Assert-True ($envActive["LIGHTRAG_HOST"] -in @("127.0.0.1", "localhost")) "active .env must keep LIGHTRAG_HOST loopback-only"
    Assert-True ($envActive["LIGHTRAG_INDEXED_PATHS"] -eq "docs/") "active .env must index docs/ by default"
    Assert-True ($envActive["LIGHTRAG_REPORT_PATH"] -eq "docs/reports/rag") "active .env must write reports to documented path"
    Assert-True (-not $compose.Contains("liquidation-embeddings:")) "compose must not include old hash embedding service"
    Assert-True ($ragOperations.Contains("nomic-embed-text")) "rag-operations must document nomic-embed-text"
    Assert-True ($lightRagMemory.Contains("FreeDeepseek availability is diagnostic-only")) "lightrag-dev-memory must not overstate fallback usability"
    Assert-True ($deployment.Contains("nomic-embed-text")) "deployment report must document nomic-embed-text"
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
