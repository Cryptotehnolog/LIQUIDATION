param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet("ingest", "eval", "health", "status")]
    [string]$Command,

    [Parameter(Position = 1)]
    [string]$Path = "docs/",

    [string]$EnvFile = "infra/lightrag/.env",

    [Alias("check-commit")]
    [switch]$CheckCommit
)

$ErrorActionPreference = "Stop"

$ReportDir = "docs/reports/rag"
$MetadataPath = Join-Path $ReportDir "index-metadata.json"
$EvalQuestionsPath = Join-Path $ReportDir "eval-questions.json"
$EvalReportPath = Join-Path $ReportDir "eval-report.json"
$HealthReportPath = Join-Path $ReportDir "health-report.json"

function Read-DotEnv {
    param([Parameter(Mandatory = $true)][string]$FilePath)

    $values = @{}
    if (-not (Test-Path $FilePath)) {
        return $values
    }

    foreach ($line in Get-Content $FilePath) {
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

function Get-ConfigValue {
    param(
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$Default = ""
    )

    if ($Config.ContainsKey($Name) -and -not [string]::IsNullOrWhiteSpace($Config[$Name])) {
        return $Config[$Name]
    }

    return $Default
}

function Invoke-HealthRequest {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Url
    )

    try {
        $response = Invoke-WebRequest $Url -UseBasicParsing -TimeoutSec 10
        return [ordered]@{
            name = $Name
            url = $Url
            ok = $true
            status_code = [int]$response.StatusCode
            error = $null
            content = $response.Content
        }
    } catch {
        $statusCode = $null
        if ($_.Exception.Response) {
            $statusCode = [int]$_.Exception.Response.StatusCode
        }

        return [ordered]@{
            name = $Name
            url = $Url
            ok = $false
            status_code = $statusCode
            error = $_.Exception.Message
            content = $null
        }
    }
}

function Assert-EmbeddingConfigured {
    param([Parameter(Mandatory = $true)]$Config)

    $provider = Get-ConfigValue $Config "EMBEDDING_PROVIDER_NAME"
    $model = Get-ConfigValue $Config "EMBEDDING_MODEL"

    if ([string]::IsNullOrWhiteSpace($provider) -or [string]::IsNullOrWhiteSpace($model)) {
        Write-Output "failed: LightRAG embedding provider/model are empty in $EnvFile"
        Write-Output "Set EMBEDDING_PROVIDER_NAME and EMBEDDING_MODEL before liq-rag ingest."
        exit 1
    }
}

function Get-ServiceConfig {
    $config = Read-DotEnv $EnvFile
    $hostName = Get-ConfigValue $config "LIGHTRAG_HOST" "127.0.0.1"

    return [ordered]@{
        raw = $config
        host = $hostName
        omniroute_url = "http://${hostName}:$(Get-ConfigValue $config "LIQUIDATION_OMNIROUTE_PORT" "21128")"
        lightrag_url = "http://${hostName}:$(Get-ConfigValue $config "LIGHTRAG_API_PORT" "19621")"
        freedeepseek_url = "http://${hostName}:$(Get-ConfigValue $config "LIQUIDATION_FREE_DEEPSEEK_PORT" "19655")"
        llm_model = Get-ConfigValue $config "LIGHTRAG_LLM_MODEL"
    }
}

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
        $config = Read-DotEnv $EnvFile
        Assert-EmbeddingConfigured $config

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
        $serviceConfig = Get-ServiceConfig
        $omniroute = Invoke-HealthRequest "omniroute_models" "$($serviceConfig.omniroute_url)/v1/models"
        $lightrag = Invoke-HealthRequest "lightrag_health" "$($serviceConfig.lightrag_url)/health"
        $freedeepseek = Invoke-HealthRequest "freedeepseek_health" "$($serviceConfig.freedeepseek_url)/health"

        $configuredModelPresent = $false
        $modelCheckError = $null
        if ($omniroute.ok -and -not [string]::IsNullOrWhiteSpace($serviceConfig.llm_model)) {
            try {
                $models = ($omniroute.content | ConvertFrom-Json).data
                $configuredModelPresent = @($models | Where-Object { $_.id -eq $serviceConfig.llm_model }).Count -gt 0
            } catch {
                $modelCheckError = $_.Exception.Message
            }
        }

        $primaryRouteOk = $omniroute.ok -and $configuredModelPresent
        $fallbackRouteOk = $freedeepseek.ok

        if ($lightrag.ok -and $primaryRouteOk) {
            $status = "ok"
            $exitCode = 0
        } elseif ($lightrag.ok -and (-not $primaryRouteOk) -and $fallbackRouteOk) {
            $status = "degraded-but-usable"
            $exitCode = 0
        } else {
            $status = "failed"
            $exitCode = 1
        }

        $report = [ordered]@{
            generated_at = (Get-Date).ToUniversalTime().ToString("o")
            status = $status
            env_file = $EnvFile
            lightrag = [ordered]@{
                ok = $lightrag.ok
                url = $lightrag.url
                status_code = $lightrag.status_code
                error = $lightrag.error
            }
            omniroute = [ordered]@{
                ok = $omniroute.ok
                url = $omniroute.url
                status_code = $omniroute.status_code
                configured_model = $serviceConfig.llm_model
                configured_model_present = $configuredModelPresent
                model_check_error = $modelCheckError
                error = $omniroute.error
            }
            freedeepseek = [ordered]@{
                ok = $freedeepseek.ok
                url = $freedeepseek.url
                status_code = $freedeepseek.status_code
                error = $freedeepseek.error
            }
        }

        $report | ConvertTo-Json -Depth 10 | Set-Content -Encoding UTF8 $HealthReportPath
        Write-Output "$status`: health report written: $HealthReportPath"
        exit $exitCode
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
