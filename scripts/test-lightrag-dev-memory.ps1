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

Assert-Contains $compose "liquidation-embeddings:" "compose should include an isolated LIQUIDATION embedding service"
Assert-Contains $compose "container_name: liquidation-embeddings" "Embedding container must be project-scoped"
Assert-Contains $compose "EMBEDDING_BINDING:" "LightRAG must receive the official EMBEDDING_BINDING env var"
Assert-Contains $compose "EMBEDDING_BINDING_HOST:" "LightRAG must receive the official EMBEDDING_BINDING_HOST env var"
Assert-Contains $compose "EMBEDDING_DIM:" "LightRAG must receive embedding dimension"

foreach ($key in @(
    "LIQUIDATION_EMBEDDINGS_PORT",
    "LIQUIDATION_EMBEDDINGS_BASE_URL",
    "LIGHTRAG_EMBEDDING_BINDING",
    "LIGHTRAG_EMBEDDING_BINDING_HOST",
    "LIGHTRAG_EMBEDDING_MODEL",
    "LIGHTRAG_EMBEDDING_DIM"
)) {
    Assert-True ($envExample.ContainsKey($key) -and -not [string]::IsNullOrWhiteSpace($envExample[$key])) ".env.example must define $key"
}

Assert-True ($envExample["LIGHTRAG_EMBEDDING_BINDING"] -eq "openai") "LightRAG embedding binding should be openai"
Assert-True ($envExample["LIGHTRAG_EMBEDDING_MODEL"] -eq "liquidation-hash-embedding-1024") "LightRAG embedding model should be project-local"
Assert-True ($envExample["LIGHTRAG_EMBEDDING_DIM"] -eq "1024") "embedding dimension should be 1024"
Assert-True ($envExample["FREE_DEEPSEEK_REF"] -match "^[0-9a-f]{40}$") "FREE_DEEPSEEK_REF must be pinned to a commit SHA"

Assert-True (Test-Path "infra/lightrag/embedding-server/embedding_server.py") "embedding server implementation should exist"
Assert-Contains (Get-Content -Raw -LiteralPath "infra/lightrag/embedding-server/embedding_server.py") "/v1/embeddings" "embedding server should expose OpenAI-compatible embeddings endpoint"
Assert-Contains $liqRag "/documents/scan" "liq-rag ingest must call real LightRAG document scan"
Assert-Contains $liqRag "/documents/pipeline_status" "liq-rag ingest must wait for the LightRAG pipeline"
Assert-True (-not $liqRag.Contains("metadata-only")) "liq-rag ingest must not be metadata-only"

Write-Output "lightrag dev memory tests passed"
