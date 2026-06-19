param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet("ingest", "eval", "health", "status")]
    [string]$Command,

    [Parameter(Position = 1)]
    [string]$Path = "docs/",

    [string]$EnvFile = "infra/lightrag/.env",

    [Alias("check-commit")]
    [switch]$CheckCommit,

    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$RemainingArgs
)

$ErrorActionPreference = "Stop"

if ($Path -eq "--check-commit") {
    $Path = "docs/"
    $CheckCommit = $true
}

if ($RemainingArgs -contains "--check-commit") {
    $CheckCommit = $true
}

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

    $binding = Get-ConfigValue $Config "LIGHTRAG_EMBEDDING_BINDING"
    $hostUrl = Get-ConfigValue $Config "LIGHTRAG_EMBEDDING_BINDING_HOST"
    $model = Get-ConfigValue $Config "LIGHTRAG_EMBEDDING_MODEL"
    $dimension = Get-ConfigValue $Config "LIGHTRAG_EMBEDDING_DIM"

    if ([string]::IsNullOrWhiteSpace($binding) -or [string]::IsNullOrWhiteSpace($hostUrl) -or [string]::IsNullOrWhiteSpace($model) -or [string]::IsNullOrWhiteSpace($dimension)) {
        Write-Output "failed: LightRAG embedding binding/host/model/dim are empty in $EnvFile"
        Write-Output "Set LIGHTRAG_EMBEDDING_BINDING, LIGHTRAG_EMBEDDING_BINDING_HOST, LIGHTRAG_EMBEDDING_MODEL, and LIGHTRAG_EMBEDDING_DIM before liq-rag ingest."
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
        embeddings_url = "http://${hostName}:$(Get-ConfigValue $config "LIQUIDATION_EMBEDDINGS_PORT" "21435")"
        llm_model = Get-ConfigValue $config "LIGHTRAG_LLM_MODEL"
        embedding_model = Get-ConfigValue $config "LIGHTRAG_EMBEDDING_MODEL"
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

function Resolve-EnvRelativePath {
    param(
        [Parameter(Mandatory = $true)][string]$Value,
        [Parameter(Mandatory = $true)][string]$BaseFile
    )

    if ([System.IO.Path]::IsPathRooted($Value)) {
        return [System.IO.Path]::GetFullPath($Value)
    }

    $baseDir = Split-Path -Parent (Resolve-Path $BaseFile)
    return [System.IO.Path]::GetFullPath((Join-Path $baseDir $Value))
}

function Assert-PathInside {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Label
    )

    $candidate = [System.IO.Path]::GetFullPath($Path)
    $rootFull = [System.IO.Path]::GetFullPath($Root)
    if (-not $rootFull.EndsWith([System.IO.Path]::DirectorySeparatorChar)) {
        $rootFull += [System.IO.Path]::DirectorySeparatorChar
    }

    if (-not $candidate.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "$Label path is outside expected root: $candidate"
    }
}

function Sync-DocsToLightRagInput {
    param(
        [Parameter(Mandatory = $true)][string]$DocsPath,
        [Parameter(Mandatory = $true)]$Config
    )

    $dataPath = Resolve-EnvRelativePath (Get-ConfigValue $Config "LIGHTRAG_DATA_PATH" "./data") $EnvFile
    $inputRoot = Join-Path $dataPath "inputs"
    $targetRoot = Join-Path $inputRoot "repo-docs"

    Assert-PathInside $targetRoot $inputRoot "LightRAG input mirror"
    New-Item -ItemType Directory -Force -Path $targetRoot | Out-Null

    Get-ChildItem -LiteralPath $targetRoot -Force | Remove-Item -Recurse -Force

    $files = git ls-files -- $DocsPath | Sort-Object
    if (-not $files) {
        throw "No tracked files found for path '$DocsPath'"
    }

    $copied = 0
    foreach ($file in $files) {
        if (-not (Test-Path $file)) {
            continue
        }

        $extension = [System.IO.Path]::GetExtension($file).ToLowerInvariant()
        if ($extension -notin @(".md", ".txt", ".json", ".yaml", ".yml")) {
            continue
        }

        $destination = Join-Path $targetRoot $file
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null
        Copy-Item -LiteralPath $file -Destination $destination -Force
        $copied += 1
    }

    if ($copied -eq 0) {
        throw "No supported docs files copied for '$DocsPath'"
    }

    return [ordered]@{
        input_root = $inputRoot
        mirror_root = $targetRoot
        copied_files = $copied
    }
}

function Invoke-LightRagScan {
    param([Parameter(Mandatory = $true)][string]$BaseUrl)

    Invoke-RestMethod -Uri "$BaseUrl/documents/scan" -Method Post -TimeoutSec 30
}

function Wait-LightRagPipeline {
    param(
        [Parameter(Mandatory = $true)][string]$BaseUrl,
        [int]$TimeoutSeconds = 900
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $lastStatus = $null
    while ((Get-Date) -lt $deadline) {
        $lastStatus = Invoke-RestMethod -Uri "$BaseUrl/documents/pipeline_status" -Method Get -TimeoutSec 30
        $counts = Invoke-RestMethod -Uri "$BaseUrl/documents/status_counts" -Method Get -TimeoutSec 30
        $statusCounts = $counts.status_counts

        $pending = 0
        $processing = 0
        if ($statusCounts) {
            if ($statusCounts.PENDING) { $pending = [int]$statusCounts.PENDING }
            if ($statusCounts.PROCESSING) { $processing = [int]$statusCounts.PROCESSING }
        }

        if (-not $lastStatus.busy -and -not $lastStatus.scanning -and -not $lastStatus.request_pending -and $pending -eq 0 -and $processing -eq 0) {
            return [ordered]@{
                pipeline = $lastStatus
                status_counts = $statusCounts
            }
        }

        Start-Sleep -Seconds 5
    }

    throw "LightRAG indexing pipeline did not finish within ${TimeoutSeconds}s. Last status: $($lastStatus | ConvertTo-Json -Depth 5)"
}

New-Item -ItemType Directory -Force -Path $ReportDir | Out-Null

switch ($Command) {
    "ingest" {
        $config = Read-DotEnv $EnvFile
        Assert-EmbeddingConfigured $config
        $serviceConfig = Get-ServiceConfig

        $commit = Get-CurrentCommit
        $treeHash = Get-DocsTreeHash $Path
        $mirror = Sync-DocsToLightRagInput -DocsPath $Path -Config $config
        $scan = Invoke-LightRagScan -BaseUrl $serviceConfig.lightrag_url
        $pipeline = Wait-LightRagPipeline -BaseUrl $serviceConfig.lightrag_url
        $report = [ordered]@{
            indexed_commit = $commit
            indexed_path = $Path
            docs_tree_hash = $treeHash
            generated_at = (Get-Date).ToUniversalTime().ToString("o")
            status = "indexed"
            lightrag_url = $serviceConfig.lightrag_url
            embedding_model = Get-ConfigValue $config "LIGHTRAG_EMBEDDING_MODEL"
            mirror = $mirror
            scan = $scan
            pipeline = $pipeline
        }

        $report | ConvertTo-Json -Depth 12 | Set-Content -Encoding UTF8 $MetadataPath
        Write-Output "ingest completed: $MetadataPath"
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
        $embeddings = Invoke-HealthRequest "embeddings_health" "$($serviceConfig.embeddings_url)/health"
        $embeddingModels = Invoke-HealthRequest "embeddings_models" "$($serviceConfig.embeddings_url)/v1/models"

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
        $embeddingRouteOk = $false
        $embeddingModelPresent = $false
        if ($embeddings.ok -and $embeddingModels.ok -and -not [string]::IsNullOrWhiteSpace($serviceConfig.embedding_model)) {
            try {
                $models = ($embeddingModels.content | ConvertFrom-Json).data
                $embeddingModelPresent = @($models | Where-Object { $_.id -eq $serviceConfig.embedding_model }).Count -gt 0
                $embeddingRouteOk = $embeddingModelPresent
            } catch {
                $embeddingRouteOk = $false
            }
        }

        if ($lightrag.ok -and $primaryRouteOk -and $embeddingRouteOk) {
            $status = "ok"
            $exitCode = 0
        } elseif ($lightrag.ok -and $embeddingRouteOk -and (-not $primaryRouteOk) -and $fallbackRouteOk) {
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
            embeddings = [ordered]@{
                ok = $embeddings.ok
                url = $embeddings.url
                status_code = $embeddings.status_code
                embedding_model = $serviceConfig.embedding_model
                embedding_model_present = $embeddingModelPresent
                models_url = $embeddingModels.url
                models_status_code = $embeddingModels.status_code
                models_error = $embeddingModels.error
                error = $embeddings.error
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
