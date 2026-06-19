$ErrorActionPreference = "Stop"

function Assert-True {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Assert-Contains {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Expected,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $Text.Contains($Expected)) {
        throw "$Message`nExpected: $Expected"
    }
}

function Read-DotEnv {
    param([Parameter(Mandatory = $true)][string]$Path)

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

$compose = Get-Content -Raw -LiteralPath "infra/lightrag/compose.yml"
$envExample = Read-DotEnv "infra/lightrag/.env.example"
$liqRag = Get-Content -Raw -LiteralPath "scripts/liq-rag.ps1"

Assert-True (-not $compose.Contains("liquidation-embeddings:")) "compose should not start the old hash embedding service by default"
Assert-Contains $compose "EMBEDDING_BINDING:" "LightRAG must receive the official EMBEDDING_BINDING env var"
Assert-Contains $compose "EMBEDDING_BINDING:" "LightRAG must receive the official EMBEDDING_BINDING env var"
Assert-Contains $compose "EMBEDDING_BINDING_HOST:" "LightRAG must receive the official EMBEDDING_BINDING_HOST env var"
Assert-Contains $compose "EMBEDDING_DIM:" "LightRAG must receive embedding dimension"

foreach ($key in @(
    "LIQUIDATION_EMBEDDINGS_BASE_URL",
    "LIGHTRAG_EMBEDDING_BINDING",
    "LIGHTRAG_EMBEDDING_BINDING_HOST",
    "LIGHTRAG_EMBEDDING_MODEL",
    "LIGHTRAG_EMBEDDING_DIM"
)) {
    Assert-True ($envExample.ContainsKey($key) -and -not [string]::IsNullOrWhiteSpace($envExample[$key])) ".env.example must define $key"
}

Assert-True ($envExample["LIGHTRAG_EMBEDDING_BINDING"] -eq "ollama") "LightRAG embedding binding should be ollama"
Assert-True ($envExample["LIGHTRAG_EMBEDDING_BINDING_HOST"] -eq "http://host.docker.internal:11434") "LightRAG should reach host Ollama from Docker"
Assert-True ($envExample["LIQUIDATION_EMBEDDINGS_BASE_URL"] -eq "http://127.0.0.1:11434") "host-side checks should use local Ollama"
Assert-True ($envExample["LIGHTRAG_EMBEDDING_MODEL"] -eq "all-minilm") "LightRAG embedding model should be all-minilm"
Assert-True ($envExample["LIGHTRAG_EMBEDDING_DIM"] -eq "384") "all-minilm embedding dimension should be 384"
Assert-True ($envExample["FREE_DEEPSEEK_REF"] -match "^[0-9a-f]{40}$") "FREE_DEEPSEEK_REF must be pinned to a commit SHA"

Assert-Contains $liqRag "/api/tags" "liq-rag health must check host Ollama tags"
Assert-Contains $liqRag "/api/embed" "liq-rag health must smoke-test Ollama embeddings"
Assert-Contains $liqRag "/documents/scan" "liq-rag ingest must call real LightRAG document scan"
Assert-Contains $liqRag "/documents/pipeline_status" "liq-rag ingest must wait for the LightRAG pipeline"
Assert-Contains $liqRag "Assert-LightRagRuntimeConfig" "liq-rag ingest must validate LightRAG runtime config before indexing"
Assert-Contains $liqRag "failed_documents" "liq-rag ingest must fail when LightRAG reports failed documents"
Assert-Contains $liqRag "Test-RagDenylistedPath" "liq-rag ingest must apply a denylist before copying docs into LightRAG"
Assert-True (-not $liqRag.Contains("metadata-only")) "liq-rag ingest must not be metadata-only"
Assert-True (-not $liqRag.Contains("degraded-but-usable")) "liq-rag health must not mark RAG usable when only FreeDeepseek fallback is available"
Assert-True (Test-Path "scripts/benchmark-ollama-embeddings.ps1") "Ollama embedding benchmark script should exist"
Assert-True (Test-Path "scripts/audit-rag.ps1") "RAG audit script should exist"
Assert-Contains (Get-Content -Raw -LiteralPath "scripts/audit-rag.ps1") "secret scan" "RAG audit script should run a secret scan"
Assert-Contains (Get-Content -Raw -LiteralPath "scripts/audit-rag.ps1") "docs/env consistency" "RAG audit script should check docs/env consistency"

Write-Output "lightrag dev memory tests passed"
