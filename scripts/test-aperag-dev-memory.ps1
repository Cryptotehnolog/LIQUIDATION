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

$compose = Get-Content -Raw -LiteralPath "infra/aperag/compose.yml"
$envExample = Get-Content -Raw -LiteralPath "infra/aperag/.env.example"
$liqAperag = Get-Content -Raw -LiteralPath "scripts/liq-aperag.ps1"
$auditAperag = Get-Content -Raw -LiteralPath "scripts/audit-aperag.ps1"
$setupRouting = Get-Content -Raw -LiteralPath "scripts/setup-aperag-routing.ps1"

Assert-True ($compose.Contains("liquidation-aperag-api")) "compose must define liquidation-aperag-api"
Assert-True ($compose.Contains("context: ./aperag")) "compose must build project-owned patched ApeRAG image"
Assert-True ($compose.Contains("liquidation-free-deepseek")) "compose must keep project-owned FreeDeepseek"
Assert-True ($compose.Contains("liquidation-embedding")) "compose must define project-owned embedding service"
Assert-True ($envExample.Contains("APERAG_BASE_IMAGE=")) ".env.example must define upstream ApeRAG base image"
Assert-True ($envExample.Contains("APERAG_IMAGE=")) ".env.example must define APERAG_IMAGE"
Assert-True ($envExample.Contains("APERAG_FRONTEND_IMAGE=")) ".env.example must define APERAG_FRONTEND_IMAGE"
Assert-True ($envExample.Contains("APERAG_PRIMARY_MODEL=deepseek-chat")) ".env.example must use FreeDeepseek as primary completion"
Assert-True ($envExample.Contains("APERAG_FALLBACK_MODEL=deepseek-chat")) ".env.example must define FreeDeepseek fallback model"
Assert-True ($envExample.Contains("APERAG_EMBEDDING_MODEL=sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2")) ".env.example must define multilingual embedding model"
Assert-True ($liqAperag.Contains("aperag_api_docs")) "liq-aperag health must check ApeRAG API docs"
Assert-True ($liqAperag.Contains("freedeepseek_chat")) "liq-aperag health must check FreeDeepseek completion route"
Assert-True ($liqAperag.Contains("embedding_vectors")) "liq-aperag health must expose embedding readiness"
Assert-True (-not $liqAperag.Contains("ApeRAG ingest automation is not implemented yet")) "liq-aperag ingest must be implemented"
Assert-True (-not $liqAperag.Contains("ApeRAG eval automation is not implemented yet")) "liq-aperag eval must be implemented"
Assert-True ($liqAperag.Contains("Ensure-ApeRagCollection")) "liq-aperag ingest must create or reuse the project collection"
Assert-True ($liqAperag.Contains("Wait-ApeRagDocumentsReady")) "liq-aperag ingest must wait for document indexes"
Assert-True ($liqAperag.Contains('$doc.status -eq "COMPLETE"')) "liq-aperag ingest must require real COMPLETE document status"
Assert-True ($liqAperag.Contains("Invoke-ApeRagEval")) "liq-aperag eval must execute retrieval checks"
Assert-True ($liqAperag.Contains("expected_all")) "liq-aperag eval must support mandatory retrieval terms"
Assert-True ($liqAperag.Contains("missing_all_terms")) "liq-aperag eval must report missing mandatory retrieval terms"
Assert-True ($liqAperag.Contains('$passedCount -eq $totalCount')) "liq-aperag eval must fail if any retrieval case fails"
Assert-True ($liqAperag.Contains('$evalTopK = 5')) "liq-aperag eval must use top-5 retrieval checks"
Assert-True ($liqAperag.Contains("expected_source")) "liq-aperag eval must support expected source checks"
Assert-True (-not $liqAperag.Contains("fulltext_search = @{ topk = `$evalTopK; keywords = `$keywords }")) "liq-aperag eval must not inject expected terms as fulltext keywords"
Assert-True (-not $liqAperag.Contains("rebuild_failed_indexes")) "liq-aperag ingest must not repair failed indexes as part of normal ingest"
Assert-True ($liqAperag.Contains("RawContentStream")) "liq-aperag must decode ApeRAG JSON responses from raw bytes"
Assert-True ($liqAperag.Contains("UTF8.GetString")) "liq-aperag must force UTF-8 response decoding for Russian text"
Assert-True ($liqAperag.Contains("git ls-files -- `$DocsPath")) "liq-aperag must index tracked docs only"
Assert-True (-not $liqAperag.Contains("git ls-files --cached --others --exclude-standard")) "liq-aperag must not index untracked local docs"
Assert-True ($liqAperag.Contains('$allowedExtensions = @(".md", ".txt")')) "liq-aperag must not index JSON planning/status files by default"
Assert-True ($liqAperag.Contains("^docs/research/raw/")) "liq-aperag must exclude raw research from default Dev Memory collection"
Assert-True ($liqAperag.Contains("index_docs_tree_hash_matches_current")) "liq-aperag status must compare indexed docs tree hash"
Assert-True ($liqAperag.Contains("ready_with_non_complete_status")) "liq-aperag ingest must report ready documents that remain non-COMPLETE"
Assert-True ($liqAperag.Contains('[switch]$CheckDrift')) "liq-aperag status must expose automatic drift checking"
Assert-True ($liqAperag.Contains("Get-ApeRagDocumentStatusDrift")) "liq-aperag must calculate ApeRAG document status drift"
Assert-True ($liqAperag.Contains("document_status_drift")) "liq-aperag status output must include drift diagnostics"
Assert-True ($liqAperag.Contains("drift_checked")) "liq-aperag status output must say whether drift was checked"
Assert-True (-not $liqAperag.Contains("repair-drift")) "liq-aperag must not use post-ingest drift repair command"
Assert-True (-not $liqAperag.Contains("RepairDrift")) "liq-aperag must not use post-ingest drift repair switch"
Assert-True (-not $liqAperag.Contains("Invoke-ApeRagDocumentStatusDriftRepair")) "liq-aperag must not patch document statuses after ingest"
Assert-True ($auditAperag.Contains("-CheckDrift")) "audit-aperag must run runtime drift checking when possible"
Assert-True ($envExample.Contains("APERAG_INDEXED_PATHS=docs/")) ".env.example must declare indexed docs path"
Assert-True ($setupRouting.Contains("liquidation-free-deepseek")) "setup routing must configure project-owned FreeDeepseek provider"
Assert-True ($setupRouting.Contains("liquidation-embedding")) "setup routing must configure project-owned embedding provider"
Assert-True ($setupRouting.Contains("default_for_embedding")) "setup routing must configure ApeRAG embedding default"

Write-Output "ApeRAG dev memory tests passed"
