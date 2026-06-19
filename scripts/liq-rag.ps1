param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet("ingest", "eval", "health", "status")]
    [string]$Command,

    [Parameter(Position = 1)]
    [string]$Path = "docs/",

    [Alias("check-commit")]
    [switch]$CheckCommit
)

$ErrorActionPreference = "Stop"

$ReportDir = "docs/reports/rag"
$MetadataPath = Join-Path $ReportDir "index-metadata.json"
$EvalQuestionsPath = Join-Path $ReportDir "eval-questions.json"
$EvalReportPath = Join-Path $ReportDir "eval-report.json"

function Get-CurrentCommit {
    (git rev-parse HEAD).Trim()
}

function Get-Sha256Hex {
    param([Parameter(Mandatory = $true)][string]$Text)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
        $hash = $sha.ComputeHash($bytes)
        return (($hash | ForEach-Object { $_.ToString("x2") }) -join "")
    } finally {
        $sha.Dispose()
    }
}

function Get-DocsTreeHash {
    param([Parameter(Mandatory = $true)][string]$DocsPath)

    $files = git ls-files -- $DocsPath | Sort-Object
    if (-not $files) {
        throw "No tracked files found for path '$DocsPath'"
    }

    $entries = foreach ($file in $files) {
        $blobHash = (git hash-object -- $file).Trim()
        "$blobHash  $file"
    }

    Get-Sha256Hex (($entries -join "`n") + "`n")
}

function Test-TermInDocs {
    param(
        [Parameter(Mandatory = $true)][string]$Term,
        [Parameter(Mandatory = $true)][string]$DocsPath
    )

    $result = rg --fixed-strings --ignore-case --quiet -- $Term $DocsPath
    return ($LASTEXITCODE -eq 0)
}

New-Item -ItemType Directory -Force -Path $ReportDir | Out-Null

switch ($Command) {
    "ingest" {
        $commit = Get-CurrentCommit
        $treeHash = Get-DocsTreeHash $Path
        $report = [ordered]@{
            indexed_commit = $commit
            indexed_path = $Path
            docs_tree_hash = $treeHash
            generated_at = (Get-Date).ToUniversalTime().ToString("o")
            status = "metadata-only"
            note = "Temporary shim. Real LightRAG ingest is not implemented yet."
        }

        $report | ConvertTo-Json -Depth 5 | Set-Content -Encoding UTF8 $MetadataPath
        Write-Output "ingest metadata written: $MetadataPath"
    }
    "eval" {
        if (-not (Test-Path $EvalQuestionsPath)) {
            throw "Missing eval questions: $EvalQuestionsPath"
        }

        $questions = Get-Content -Raw $EvalQuestionsPath | ConvertFrom-Json
        $results = foreach ($question in $questions) {
            $missing = @()
            foreach ($term in $question.expected_answer_contains) {
                if (-not (Test-TermInDocs -Term $term -DocsPath "docs/")) {
                    $missing += $term
                }
            }

            [ordered]@{
                id = $question.id
                status = $(if ($missing.Count -eq 0) { "passed" } else { "failed" })
                missing_terms = $missing
            }
        }

        $failed = @($results | Where-Object { $_.status -ne "passed" })
        $report = [ordered]@{
            generated_at = (Get-Date).ToUniversalTime().ToString("o")
            status = $(if ($failed.Count -eq 0) { "passed" } else { "failed" })
            results = $results
        }
        $report | ConvertTo-Json -Depth 10 | Set-Content -Encoding UTF8 $EvalReportPath

        if ($failed.Count -gt 0) {
            Write-Output "eval failed: $EvalReportPath"
            exit 1
        }

        Write-Output "eval passed: $EvalReportPath"
    }
    "health" {
        if (-not (Test-Path $MetadataPath)) {
            Write-Output "failed: missing $MetadataPath"
            exit 1
        }

        Write-Output "degraded-but-usable: metadata exists; real LightRAG service health is not implemented yet"
    }
    "status" {
        if (-not (Test-Path $MetadataPath)) {
            Write-Output "failed: missing $MetadataPath"
            exit 1
        }

        $metadata = Get-Content -Raw $MetadataPath | ConvertFrom-Json
        $current = Get-CurrentCommit

        if ($metadata.indexed_commit -eq $current) {
            Write-Output "fresh: indexed commit matches current commit"
            exit 0
        }

        $message = "stale: indexed commit $($metadata.indexed_commit) != current commit $current"
        if ($CheckCommit) {
            Write-Output $message
            exit 1
        }

        Write-Output $message
    }
}
