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
    $Path = ""
    $CheckCommit = $true
}

if ($RemainingArgs -contains "--check-commit") {
    $CheckCommit = $true
}

if ($env:LIQ_RAG_DEBUG_ARGS -eq "1") {
    Write-Output "debug args: Command=[$Command] Path=[$Path] EnvFile=[$EnvFile] CheckCommit=[$CheckCommit] Remaining=[$($RemainingArgs -join ',')]"
}

$DefaultReportDir = "docs/reports/rag"
$IngestionConfigVersion = "lightrag-dev-memory-v2"
$DefaultChunkTokenSize = 256
$DefaultChunkOverlapTokenSize = 32

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

function Get-ReportPaths {
    param([Parameter(Mandatory = $true)]$Config)

    $reportDir = Get-ConfigValue $Config "LIGHTRAG_REPORT_PATH" $DefaultReportDir
    New-Item -ItemType Directory -Force -Path $reportDir | Out-Null

    return [ordered]@{
        dir = $reportDir
        metadata = Join-Path $reportDir "index-metadata.json"
        eval_questions = Join-Path $reportDir "eval-questions.json"
        eval_report = Join-Path $reportDir "eval-report.json"
        health_report = Join-Path $reportDir "health-report.json"
    }
}

function Write-JsonAtomic {
    param(
        [Parameter(Mandatory = $true)]$Value,
        [Parameter(Mandatory = $true)][string]$Path,
        [int]$Depth = 12
    )

    $directory = Split-Path -Parent $Path
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
    $tempPath = Join-Path $directory (".tmp-" + [Guid]::NewGuid().ToString("N") + "-" + (Split-Path -Leaf $Path))
    $Value | ConvertTo-Json -Depth $Depth | Set-Content -Encoding UTF8 $tempPath
    Move-Item -LiteralPath $tempPath -Destination $Path -Force
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

function Invoke-JsonPostRequest {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)]$Body,
        [int]$TimeoutSeconds = 60
    )

    try {
        $jsonBody = $Body | ConvertTo-Json -Depth 12
        $response = Invoke-WebRequest $Url -UseBasicParsing -Method Post -ContentType "application/json" -Body $jsonBody -TimeoutSec $TimeoutSeconds
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

function Convert-StringToJsonLiteral {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value)

    $builder = [System.Text.StringBuilder]::new()
    [void]$builder.Append('"')
    foreach ($ch in $Value.ToCharArray()) {
        switch ($ch) {
            '"' { [void]$builder.Append('\"') }
            '\' { [void]$builder.Append('\\') }
            "`b" { [void]$builder.Append('\b') }
            "`f" { [void]$builder.Append('\f') }
            "`n" { [void]$builder.Append('\n') }
            "`r" { [void]$builder.Append('\r') }
            "`t" { [void]$builder.Append('\t') }
            default {
                if ([int][char]$ch -lt 32) {
                    [void]$builder.Append('\u')
                    [void]$builder.Append(([int][char]$ch).ToString('x4'))
                } else {
                    [void]$builder.Append($ch)
                }
            }
        }
    }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Invoke-LightRagTextPost {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$FileSource,
        [Parameter(Mandatory = $true)][int]$ChunkTokenSize,
        [Parameter(Mandatory = $true)][int]$ChunkOverlapTokenSize
    )

    $jsonBody = "{""text"":$(Convert-StringToJsonLiteral $Text),""file_source"":$(Convert-StringToJsonLiteral $FileSource),""chunking"":{""strategy"":""fixed_token"",""params"":{""chunk_token_size"":$ChunkTokenSize,""chunk_overlap_token_size"":$ChunkOverlapTokenSize}}}"
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($jsonBody)

    try {
        $response = Invoke-WebRequest $Url -UseBasicParsing -Method Post -ContentType "application/json; charset=utf-8" -Body $bytes -TimeoutSec 60
        return [ordered]@{
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

function Test-RagDenylistedPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $normalized = $Path.Replace("\", "/").ToLowerInvariant()
    $fileName = [System.IO.Path]::GetFileName($normalized)
    $extension = [System.IO.Path]::GetExtension($normalized)

    if ($fileName -eq ".env" -or $fileName.StartsWith(".env.")) {
        return $true
    }

    if ($normalized -match "(^|/)(secrets?|credentials?|cookies?|private|keys?)(/|$)") {
        return $true
    }

    if ($normalized.StartsWith("docs/research/raw/")) {
        return $true
    }

    if ($normalized.StartsWith("docs/superpowers/")) {
        return $true
    }

    if ($extension -in @(".pem", ".key", ".p12", ".pfx", ".db", ".sqlite", ".sqlite3", ".parquet")) {
        return $true
    }

    return $false
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
        embeddings_url = Get-ConfigValue $config "LIQUIDATION_EMBEDDINGS_BASE_URL" "http://${hostName}:11434"
        llm_model = Get-ConfigValue $config "LIGHTRAG_LLM_MODEL"
        embedding_binding = Get-ConfigValue $config "LIGHTRAG_EMBEDDING_BINDING"
        embedding_host = Get-ConfigValue $config "LIGHTRAG_EMBEDDING_BINDING_HOST"
        embedding_model = Get-ConfigValue $config "LIGHTRAG_EMBEDDING_MODEL"
        embedding_dim = Get-ConfigValue $config "LIGHTRAG_EMBEDDING_DIM"
        chunk_token_size = [int](Get-ConfigValue $config "LIGHTRAG_CHUNK_TOKEN_SIZE" $DefaultChunkTokenSize)
        chunk_overlap_token_size = [int](Get-ConfigValue $config "LIGHTRAG_CHUNK_OVERLAP_TOKEN_SIZE" $DefaultChunkOverlapTokenSize)
    }
}

function Get-CurrentCommit {
    (git rev-parse HEAD).Trim()
}

function Get-CurrentBranch {
    (git rev-parse --abbrev-ref HEAD).Trim()
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

function Normalize-RepoPath {
    param([Parameter(Mandatory = $true)][string]$Value)

    $normalized = $Value.Replace("\", "/").Trim()
    if ($normalized.StartsWith("./")) {
        $normalized = $normalized.Substring(2)
    }
    $normalized = $normalized.TrimStart("/")
    $normalized = $normalized.TrimEnd("/") + "/"
    return $normalized
}

function Get-AllowedIndexedPaths {
    param([Parameter(Mandatory = $true)]$Config)

    $raw = Get-ConfigValue $Config "LIGHTRAG_INDEXED_PATHS" "docs/"
    $parts = $raw -split "[,;]"
    $allowed = @()
    foreach ($part in $parts) {
        if (-not [string]::IsNullOrWhiteSpace($part)) {
            $allowed += (Normalize-RepoPath $part)
        }
    }

    if ($allowed.Count -eq 0) {
        throw "LIGHTRAG_INDEXED_PATHS is empty"
    }

    return $allowed
}

function Get-ConfiguredIndexedPath {
    param(
        [Parameter(Mandatory = $true)]$Config,
        [string]$RequestedPath
    )

    if (-not [string]::IsNullOrWhiteSpace($RequestedPath)) {
        return (Normalize-RepoPath $RequestedPath)
    }

    $allowed = @(Get-AllowedIndexedPaths $Config)
    return $allowed[0]
}

function Assert-AllowedIndexedPath {
    param(
        [Parameter(Mandatory = $true)][string]$IndexedPath,
        [Parameter(Mandatory = $true)]$Config
    )

    $allowed = Get-AllowedIndexedPaths $Config
    if ($IndexedPath -notin $allowed) {
        throw "Refusing to index '$IndexedPath'. Allowed LIGHTRAG_INDEXED_PATHS: $($allowed -join ', ')"
    }
}

function Get-IndexableTrackedFiles {
    param([Parameter(Mandatory = $true)][string]$DocsPath)

    $files = git ls-files -- $DocsPath |
        Where-Object { -not (Test-RagDenylistedPath $_) } |
        Sort-Object

    if (-not $files) {
        throw "No indexable tracked files found for path '$DocsPath'"
    }

    return @($files)
}

function Get-IndexableUntrackedFiles {
    param([Parameter(Mandatory = $true)][string]$DocsPath)

    $files = git ls-files --others --exclude-standard -- $DocsPath |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Where-Object { -not (Test-RagDenylistedPath $_) } |
        Where-Object {
            $extension = [System.IO.Path]::GetExtension($_).ToLowerInvariant()
            $extension -in @(".md", ".txt", ".json", ".yaml", ".yml")
        } |
        Sort-Object

    return @($files)
}

function Assert-NoIndexableUntrackedFiles {
    param([Parameter(Mandatory = $true)][string]$DocsPath)

    $untracked = Get-IndexableUntrackedFiles $DocsPath
    if (@($untracked).Count -gt 0) {
        throw "Refusing to ingest with untracked indexable docs under '$DocsPath'. Add or remove these files first: $($untracked -join ', ')"
    }
}

function Get-DocsTreeHash {
    param([Parameter(Mandatory = $true)][string]$DocsPath)

    $files = Get-IndexableTrackedFiles $DocsPath
    $entries = foreach ($file in $files) {
        $blobHash = (git hash-object -- $file).Trim()
        "$blobHash  $file"
    }

    Get-Sha256Hex (($entries -join "`n") + "`n")
}

function Test-DocsPathDirty {
    param([Parameter(Mandatory = $true)][string]$DocsPath)

    $changed = @()
    $changed += git diff --name-only -- $DocsPath
    $changed += git diff --name-only --cached -- $DocsPath
    $changed += git ls-files --others --exclude-standard -- $DocsPath

    $indexableChanged = $changed |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Where-Object { -not (Test-RagDenylistedPath $_) } |
        Select-Object -Unique

    return (@($indexableChanged).Count -gt 0)
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

    if (-not ($candidate + [System.IO.Path]::DirectorySeparatorChar).StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase) -and
        -not $candidate.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "$Label path is outside expected root: $candidate"
    }
}

function Assert-DataPathScope {
    param([Parameter(Mandatory = $true)][string]$DataPath)

    $allowedRoot = [System.IO.Path]::GetFullPath((Join-Path (Get-Location) "infra/lightrag/data"))
    Assert-PathInside $DataPath $allowedRoot "LIGHTRAG_DATA_PATH"
}

function Get-ContainerMetadata {
    param([Parameter(Mandatory = $true)][string]$ContainerName)

    try {
        $inspect = docker inspect $ContainerName | ConvertFrom-Json
        if ($inspect.Count -eq 0) {
            return $null
        }

        return [ordered]@{
            name = $ContainerName
            image = $inspect[0].Config.Image
            image_id = $inspect[0].Image
            state = $inspect[0].State.Status
        }
    } catch {
        return [ordered]@{
            name = $ContainerName
            image = $null
            image_id = $null
            state = $null
            error = $_.Exception.Message
        }
    }
}

function Get-ComposeConfigHash {
    param([Parameter(Mandatory = $true)][string]$EnvFilePath)

    try {
        $configText = docker compose --env-file $EnvFilePath -f infra/lightrag/compose.yml -p liquidation config --format json
        return (Get-Sha256Hex $configText)
    } catch {
        return $null
    }
}

function Get-SafeMirrorName {
    param([Parameter(Mandatory = $true)][string]$SourcePath)

    $safe = $SourcePath.Replace("\", "__").Replace("/", "__")
    $safe = $safe -replace '[^A-Za-z0-9._-]', "_"
    return "liq-rag__$safe"
}

function Sync-DocsToLightRagInput {
    param(
        [Parameter(Mandatory = $true)][string]$DocsPath,
        [Parameter(Mandatory = $true)]$Config
    )

    $dataPath = Resolve-EnvRelativePath (Get-ConfigValue $Config "LIGHTRAG_DATA_PATH" "./data") $EnvFile
    Assert-DataPathScope $dataPath

    $inputRoot = Join-Path $dataPath "inputs"
    $legacyTargetRoot = Join-Path $inputRoot "repo-docs"

    Assert-PathInside $inputRoot $dataPath "LightRAG input root"
    New-Item -ItemType Directory -Force -Path $inputRoot | Out-Null

    Get-ChildItem -LiteralPath $inputRoot -Force -Filter "liq-rag__*" | Remove-Item -Recurse -Force
    if (Test-Path $legacyTargetRoot) {
        Remove-Item -LiteralPath $legacyTargetRoot -Recurse -Force
    }

    $files = git ls-files -- $DocsPath | Sort-Object
    if (-not $files) {
        throw "No tracked files found for path '$DocsPath'"
    }

    $copied = 0
    $skippedDenylisted = @()
    $copiedFiles = @()
    foreach ($file in $files) {
        if (-not (Test-Path $file)) {
            continue
        }

        if (Test-RagDenylistedPath $file) {
            $skippedDenylisted += $file
            continue
        }

        $extension = [System.IO.Path]::GetExtension($file).ToLowerInvariant()
        if ($extension -notin @(".md", ".txt", ".json", ".yaml", ".yml")) {
            continue
        }

        $destination = Join-Path $inputRoot (Get-SafeMirrorName $file)
        Copy-Item -LiteralPath $file -Destination $destination -Force
        $copied += 1
        $copiedFiles += [ordered]@{
            source = $file
            mirrored_as = (Split-Path -Leaf $destination)
        }
    }

    if ($copied -eq 0) {
        throw "No supported docs files copied for '$DocsPath'"
    }

    return [ordered]@{
        input_root = $inputRoot
        mirror_root = $inputRoot
        copied_files = $copied
        copied = $copiedFiles
        skipped_denylisted = $skippedDenylisted
    }
}

function Assert-LightRagRuntimeConfig {
    param(
        [Parameter(Mandatory = $true)][string]$BaseUrl,
        [Parameter(Mandatory = $true)]$Config
    )

    $health = Invoke-RestMethod -Uri "$BaseUrl/health" -Method Get -TimeoutSec 30
    $runtime = $health.configuration
    if (-not $runtime) {
        throw "LightRAG health response has no configuration block"
    }

    $expectedLlmModel = Get-ConfigValue $Config "LIGHTRAG_LLM_MODEL"
    $expectedEmbeddingBinding = Get-ConfigValue $Config "LIGHTRAG_EMBEDDING_BINDING"
    $expectedEmbeddingHost = Get-ConfigValue $Config "LIGHTRAG_EMBEDDING_BINDING_HOST"
    $expectedEmbeddingModel = Get-ConfigValue $Config "LIGHTRAG_EMBEDDING_MODEL"
    $expectedEmbeddingDim = Get-ConfigValue $Config "LIGHTRAG_EMBEDDING_DIM"

    $problems = @()
    if ($runtime.llm_model -ne $expectedLlmModel) {
        $problems += "llm_model runtime=$($runtime.llm_model) expected=$expectedLlmModel"
    }
    if ($runtime.embedding_binding -ne $expectedEmbeddingBinding) {
        $problems += "embedding_binding runtime=$($runtime.embedding_binding) expected=$expectedEmbeddingBinding"
    }
    if ($runtime.embedding_binding_host -ne $expectedEmbeddingHost) {
        $problems += "embedding_binding_host runtime=$($runtime.embedding_binding_host) expected=$expectedEmbeddingHost"
    }
    if ($runtime.embedding_model -ne $expectedEmbeddingModel) {
        $problems += "embedding_model runtime=$($runtime.embedding_model) expected=$expectedEmbeddingModel"
    }
    if ($runtime.embedding_dim -and ([string]$runtime.embedding_dim) -ne $expectedEmbeddingDim) {
        $problems += "embedding_dim runtime=$($runtime.embedding_dim) expected=$expectedEmbeddingDim"
    }

    if ($problems.Count -gt 0) {
        throw "LightRAG runtime config mismatch: $($problems -join '; ')"
    }

    return [ordered]@{
        llm_model = $runtime.llm_model
        embedding_binding = $runtime.embedding_binding
        embedding_binding_host = $runtime.embedding_binding_host
        embedding_model = $runtime.embedding_model
        embedding_dim = $runtime.embedding_dim
    }
}

function Wait-LightRagIdle {
    param(
        [Parameter(Mandatory = $true)][string]$BaseUrl,
        [int]$TimeoutSeconds = 300
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $status = Invoke-RestMethod -Uri "$BaseUrl/documents/pipeline_status" -Method Get -TimeoutSec 30
        if (-not $status.busy -and -not $status.scanning -and -not $status.request_pending -and -not $status.destructive_busy) {
            return $status
        }
        Start-Sleep -Seconds 2
    }

    throw "LightRAG did not become idle within ${TimeoutSeconds}s"
}

function Clear-LightRagDocsByPrefix {
    param(
        [Parameter(Mandatory = $true)][string]$BaseUrl,
        [string]$Prefix = "liq-rag__"
    )

    Wait-LightRagIdle -BaseUrl $BaseUrl | Out-Null
    $documents = Invoke-RestMethod -Uri "$BaseUrl/documents" -Method Get -TimeoutSec 30
    $docIds = @()

    foreach ($group in $documents.statuses.PSObject.Properties) {
        foreach ($doc in @($group.Value)) {
            if ([string]$doc.file_path -like "$Prefix*") {
                $docIds += [string]$doc.id
            }
        }
    }

    if ($docIds.Count -eq 0) {
        return [ordered]@{
            deleted = 0
            doc_ids = @()
        }
    }

    try {
        $deleteBody = @{
            doc_ids = $docIds
            delete_file = $true
            delete_llm_cache = $true
        } | ConvertTo-Json -Depth 6
        $deleteWebResponse = Invoke-WebRequest "$BaseUrl/documents/delete_document" -UseBasicParsing -Method Delete -ContentType "application/json" -Body $deleteBody -TimeoutSec 60
        $deleteContent = $deleteWebResponse.Content
    } catch {
        throw "LightRAG delete prefixed docs failed: $($_.Exception.Message)"
    }
    Wait-LightRagIdle -BaseUrl $BaseUrl | Out-Null

    return [ordered]@{
        deleted = $docIds.Count
        doc_ids = $docIds
        response = $deleteContent
    }
}

function Invoke-LightRagTextIngest {
    param(
        [Parameter(Mandatory = $true)][string]$BaseUrl,
        [Parameter(Mandatory = $true)]$Mirror,
        [Parameter(Mandatory = $true)]$ServiceConfig
    )

    $responses = @()
    $copiedItems = @($Mirror["copied"])
    $total = $copiedItems.Count
    $index = 0
    foreach ($item in $copiedItems) {
        $index += 1
        $sourcePath = [string]$item["source"]
        $fileSource = [string]$item["mirrored_as"]
        Write-Host "ingest insert ${index}/${total}: $sourcePath"
        $resolvedSourcePath = (Resolve-Path -LiteralPath $sourcePath).Path
        $text = [System.IO.File]::ReadAllText($resolvedSourcePath, [System.Text.Encoding]::UTF8)
        $response = Invoke-LightRagTextPost -Url "$BaseUrl/documents/text" -Text $text -FileSource $fileSource -ChunkTokenSize $ServiceConfig.chunk_token_size -ChunkOverlapTokenSize $ServiceConfig.chunk_overlap_token_size
        if (-not $response.ok) {
            throw "LightRAG text ingest failed for ${sourcePath}: $($response.error)"
        }
        Write-Host "ingest accepted ${index}/${total}: $sourcePath"
        $responses += [ordered]@{
            source = $sourcePath
            file_source = $fileSource
            status_code = $response.status_code
            content = $response.content
        }
    }

    return [ordered]@{
        endpoint = "$BaseUrl/documents/text"
        inserted = $responses.Count
        chunk_token_size = $ServiceConfig.chunk_token_size
        chunk_overlap_token_size = $ServiceConfig.chunk_overlap_token_size
        responses = $responses
    }
}

function Get-StatusCount {
    param(
        [Parameter(Mandatory = $true)]$StatusCounts,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($StatusCounts.PSObject.Properties[$Name]) {
        return [int]$StatusCounts.$Name
    }

    $upper = $Name.ToUpperInvariant()
    if ($StatusCounts.PSObject.Properties[$upper]) {
        return [int]$StatusCounts.$upper
    }

    return 0
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

        $active = 0
        foreach ($name in @("pending", "parsing", "analyzing", "processing", "preprocessed")) {
            $active += Get-StatusCount $statusCounts $name
        }

        $failed = Get-StatusCount $statusCounts "failed"

        if (-not $lastStatus.busy -and -not $lastStatus.scanning -and -not $lastStatus.request_pending -and $active -eq 0) {
            if ($failed -gt 0) {
                throw "LightRAG indexing finished with failed_documents=$failed"
            }

            return [ordered]@{
                pipeline = $lastStatus
                status_counts = $statusCounts
                failed_documents = $failed
            }
        }

        Start-Sleep -Seconds 5
    }

    throw "LightRAG indexing pipeline did not finish within ${TimeoutSeconds}s. Last status: $($lastStatus | ConvertTo-Json -Depth 5)"
}

function Assert-IndexedDocumentCounts {
    param(
        [Parameter(Mandatory = $true)]$Pipeline,
        [Parameter(Mandatory = $true)][int]$ExpectedCopiedFiles
    )

    $counts = $Pipeline.status_counts
    $processed = Get-StatusCount $counts "processed"
    $all = Get-StatusCount $counts "all"
    $failed = Get-StatusCount $counts "failed"

    if ($failed -gt 0) {
        throw "LightRAG indexing failed_documents=$failed"
    }
    if ($processed -lt 1 -or $all -lt 1) {
        throw "LightRAG indexed zero documents: processed=$processed all=$all copied_files=$ExpectedCopiedFiles"
    }
    if ($all -lt $ExpectedCopiedFiles) {
        throw "LightRAG indexed fewer documents than mirrored: all=$all copied_files=$ExpectedCopiedFiles"
    }

    return [ordered]@{
        processed = $processed
        all = $all
        failed = $failed
        copied_files = $ExpectedCopiedFiles
    }
}

function Invoke-LightRagQuery {
    param(
        [Parameter(Mandatory = $true)][string]$BaseUrl,
        [Parameter(Mandatory = $true)][string]$Question,
        [string[]]$ExpectedTerms = @()
    )

    $body = @{
        query = $Question
        mode = "naive"
        only_need_context = $true
        include_references = $true
        include_chunk_content = $true
        top_k = 5
        chunk_top_k = 5
        stream = $false
        hl_keywords = $ExpectedTerms
        ll_keywords = $ExpectedTerms
    }

    $response = Invoke-JsonPostRequest "lightrag_query" "$BaseUrl/query" $body 120
    if (-not $response.ok) {
        throw "LightRAG query failed: $($response.error)"
    }

    return [string]$response.content
}

function Test-LightRagSentinelRetrieval {
    param([Parameter(Mandatory = $true)][string]$BaseUrl)

    $content = Invoke-LightRagQuery -BaseUrl $BaseUrl -Question "What is the source of truth for LIQUIDATION LightRAG Dev Memory?" -ExpectedTerms @("Git", "docs", "source of truth")
    return ($content -match "(?i)Git" -and $content -match "(?i)docs")
}

function Get-EmbeddingVectorDimension {
    param([string]$JsonContent)

    if ([string]::IsNullOrWhiteSpace($JsonContent)) {
        return 0
    }

    $json = $JsonContent | ConvertFrom-Json
    if (-not $json.embeddings -or $json.embeddings.Count -eq 0) {
        return 0
    }

    return @($json.embeddings[0]).Count
}

function Invoke-ChatCompletionSmoke {
    param(
        [Parameter(Mandatory = $true)][string]$BaseUrl,
        [Parameter(Mandatory = $true)][string]$Model,
        [string]$Name = "chat_completion"
    )

    if ([string]::IsNullOrWhiteSpace($Model)) {
        return [ordered]@{
            name = $Name
            url = "$BaseUrl/v1/chat/completions"
            ok = $false
            status_code = $null
            error = "model is empty"
            content = $null
        }
    }

    Invoke-JsonPostRequest $Name "$BaseUrl/v1/chat/completions" @{
        model = $Model
        messages = @(@{ role = "user"; content = "Reply with exactly one word: ok" })
        stream = $false
        max_tokens = 8
    } 120
}

function Get-FirstOpenAiModelId {
    param($ModelsResponse)

    if (-not $ModelsResponse.ok) {
        return ""
    }

    try {
        $models = ($ModelsResponse.content | ConvertFrom-Json).data
        if (@($models).Count -gt 0) {
            return [string]$models[0].id
        }
    } catch {
        return ""
    }

    return ""
}

function Get-FreshnessReport {
    param(
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)]$Paths,
        [Parameter(Mandatory = $true)][string]$IndexedPath,
        [Parameter(Mandatory = $true)][string]$LightRagUrl
    )

    $metadataOk = Test-Path $Paths.metadata
    $evalOk = Test-Path $Paths.eval_report
    $metadata = $null
    $eval = $null
    $currentCommit = Get-CurrentCommit
    $currentTreeHash = Get-DocsTreeHash $IndexedPath
    $dirty = Test-DocsPathDirty $IndexedPath
    $docsTreeHashMatch = $false
    $evalPassed = $false
    $indexedCounts = $null

    if ($metadataOk) {
        $metadata = Get-Content -Raw $Paths.metadata | ConvertFrom-Json
        $docsTreeHashMatch = ($metadata.docs_tree_hash -eq $currentTreeHash -and $metadata.indexed_path -eq $IndexedPath)
    }

    if ($evalOk) {
        $eval = Get-Content -Raw $Paths.eval_report | ConvertFrom-Json
        $evalPassed = ($eval.status -eq "passed" -and $eval.docs_tree_hash -eq $currentTreeHash -and $eval.indexed_path -eq $IndexedPath)
    }

    try {
        $counts = Invoke-RestMethod -Uri "$LightRagUrl/documents/status_counts" -Method Get -TimeoutSec 30
        $indexedCounts = $counts.status_counts
    } catch {
        $indexedCounts = $null
    }

    $processed = 0
    $all = 0
    if ($indexedCounts) {
        $processed = Get-StatusCount $indexedCounts "processed"
        $all = Get-StatusCount $indexedCounts "all"
    }

    $ok = $metadataOk -and $evalOk -and $docsTreeHashMatch -and $evalPassed -and (-not $dirty) -and $processed -gt 0 -and $all -gt 0

    return [ordered]@{
        ok = $ok
        metadata_present = $metadataOk
        eval_present = $evalOk
        indexed_path = $(if ($metadata) { $metadata.indexed_path } else { $null })
        expected_indexed_path = $IndexedPath
        indexed_commit = $(if ($metadata) { $metadata.indexed_commit } else { $null })
        current_commit = $currentCommit
        indexed_docs_tree_hash = $(if ($metadata) { $metadata.docs_tree_hash } else { $null })
        current_docs_tree_hash = $currentTreeHash
        docs_tree_hash_match = $docsTreeHashMatch
        docs_path_dirty = $dirty
        eval_status = $(if ($eval) { $eval.status } else { $null })
        eval_passed = $evalPassed
        indexed_counts = $indexedCounts
        indexed_processed = $processed
        indexed_all = $all
    }
}

switch ($Command) {
    "ingest" {
        $config = Read-DotEnv $EnvFile
        $paths = Get-ReportPaths $config
        Assert-EmbeddingConfigured $config
        $indexedPath = Get-ConfiguredIndexedPath -Config $config -RequestedPath $Path
        Assert-AllowedIndexedPath -IndexedPath $indexedPath -Config $config
        Assert-NoIndexableUntrackedFiles $indexedPath
        $serviceConfig = Get-ServiceConfig

        $commit = Get-CurrentCommit
        $branch = Get-CurrentBranch
        $treeHash = Get-DocsTreeHash $indexedPath
        $runtimeConfig = Assert-LightRagRuntimeConfig -BaseUrl $serviceConfig.lightrag_url -Config $config
        Write-Output "ingest step: clearing previous liq-rag documents"
        $clear = Clear-LightRagDocsByPrefix -BaseUrl $serviceConfig.lightrag_url
        Write-Output "ingest step: syncing docs to LightRAG input mirror"
        $mirror = Sync-DocsToLightRagInput -DocsPath $indexedPath -Config $config
        Write-Output "ingest step: inserting $($mirror["copied_files"]) docs through LightRAG text API"
        $textIngest = Invoke-LightRagTextIngest -BaseUrl $serviceConfig.lightrag_url -Mirror $mirror -ServiceConfig $serviceConfig
        Write-Output "ingest step: waiting for LightRAG pipeline"
        $ingestTimeoutSeconds = [int](Get-ConfigValue $config "LIGHTRAG_INGEST_TIMEOUT_SECONDS" "3600")
        $pipeline = Wait-LightRagPipeline -BaseUrl $serviceConfig.lightrag_url -TimeoutSeconds $ingestTimeoutSeconds
        $indexedCounts = Assert-IndexedDocumentCounts -Pipeline $pipeline -ExpectedCopiedFiles ([int]$mirror["copied_files"])
        $sentinelOk = Test-LightRagSentinelRetrieval -BaseUrl $serviceConfig.lightrag_url
        if (-not $sentinelOk) {
            throw "LightRAG sentinel retrieval failed after ingest"
        }

        $report = [ordered]@{
            indexed_commit = $commit
            indexed_branch = $branch
            indexed_path = $indexedPath
            docs_tree_hash = $treeHash
            generated_at = (Get-Date).ToUniversalTime().ToString("o")
            status = "indexed"
            ingestion_config_version = $IngestionConfigVersion
            env_file = $EnvFile
            compose_config_hash = Get-ComposeConfigHash $EnvFile
            lightrag_url = $serviceConfig.lightrag_url
            embedding_model = Get-ConfigValue $config "LIGHTRAG_EMBEDDING_MODEL"
            embedding_dim = Get-ConfigValue $config "LIGHTRAG_EMBEDDING_DIM"
            runtime_config = $runtimeConfig
            lightrag_container = Get-ContainerMetadata "liquidation-lightrag"
            clear = $clear
            mirror = $mirror
            text_ingest = $textIngest
            pipeline = $pipeline
            indexed_counts = $indexedCounts
            sentinel_retrieval_ok = $sentinelOk
        }

        Write-JsonAtomic -Value $report -Path $paths.metadata -Depth 14
        Write-Output "ingest completed: $($paths.metadata)"
    }
    "eval" {
        $config = Read-DotEnv $EnvFile
        $paths = Get-ReportPaths $config
        $indexedPath = Get-ConfiguredIndexedPath -Config $config -RequestedPath $Path
        Assert-AllowedIndexedPath -IndexedPath $indexedPath -Config $config
        $serviceConfig = Get-ServiceConfig

        if (-not (Test-Path $paths.eval_questions)) {
            throw "Missing eval questions: $($paths.eval_questions)"
        }

        $treeHash = Get-DocsTreeHash $indexedPath
        $questions = Get-Content -Raw $paths.eval_questions | ConvertFrom-Json
        $results = foreach ($question in $questions) {
            $terms = @($question.expected_answer_contains)
            $rawResponse = Invoke-LightRagQuery -BaseUrl $serviceConfig.lightrag_url -Question $question.question -ExpectedTerms $terms
            $missing = @()
            foreach ($term in $terms) {
                if ($rawResponse -notmatch [regex]::Escape($term)) {
                    $missing += $term
                }
            }

            [ordered]@{
                id = $question.id
                question = $question.question
                status = $(if ($missing.Count -eq 0) { "passed" } else { "failed" })
                missing_terms = $missing
                response_excerpt = $(if ($rawResponse.Length -gt 1200) { $rawResponse.Substring(0, 1200) } else { $rawResponse })
            }
        }

        $failed = @($results | Where-Object { $_.status -ne "passed" })
        $report = [ordered]@{
            generated_at = (Get-Date).ToUniversalTime().ToString("o")
            status = $(if ($failed.Count -eq 0) { "passed" } else { "failed" })
            indexed_path = $indexedPath
            indexed_commit = Get-CurrentCommit
            docs_tree_hash = $treeHash
            query_endpoint = "$($serviceConfig.lightrag_url)/query"
            mode = "naive"
            real_lightrag_retrieval = $true
            results = $results
        }
        Write-JsonAtomic -Value $report -Path $paths.eval_report -Depth 12

        if ($failed.Count -gt 0) {
            Write-Output "eval failed: $($paths.eval_report)"
            exit 1
        }

        Write-Output "eval passed: $($paths.eval_report)"
    }
    "health" {
        $config = Read-DotEnv $EnvFile
        $paths = Get-ReportPaths $config
        $indexedPath = Get-ConfiguredIndexedPath -Config $config -RequestedPath $Path
        Assert-AllowedIndexedPath -IndexedPath $indexedPath -Config $config
        $serviceConfig = Get-ServiceConfig
        $omniroute = Invoke-HealthRequest "omniroute_models" "$($serviceConfig.omniroute_url)/v1/models"
        $lightrag = Invoke-HealthRequest "lightrag_health" "$($serviceConfig.lightrag_url)/health"
        $freedeepseek = Invoke-HealthRequest "freedeepseek_health" "$($serviceConfig.freedeepseek_url)/health"
        $freedeepseekModels = Invoke-HealthRequest "freedeepseek_models" "$($serviceConfig.freedeepseek_url)/v1/models"
        $embeddings = $null
        $embeddingModels = $null
        $embeddingProbe = $null

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

        $omnirouteChat = Invoke-ChatCompletionSmoke -BaseUrl $serviceConfig.omniroute_url -Model $serviceConfig.llm_model -Name "omniroute_chat_completion"
        $primaryRouteOk = $omniroute.ok -and $configuredModelPresent -and $omnirouteChat.ok

        $fallbackModel = Get-FirstOpenAiModelId $freedeepseekModels
        $freedeepseekChat = $null
        if ($freedeepseek.ok -and -not [string]::IsNullOrWhiteSpace($fallbackModel)) {
            $freedeepseekChat = Invoke-ChatCompletionSmoke -BaseUrl $serviceConfig.freedeepseek_url -Model $fallbackModel -Name "freedeepseek_chat_completion"
        }
        $fallbackRouteOk = $freedeepseek.ok -and $freedeepseekModels.ok -and $freedeepseekChat -and $freedeepseekChat.ok

        $embeddingRouteOk = $false
        $embeddingModelPresent = $false
        $embeddingVectorDimension = 0
        $embeddingDimensionMatch = $false
        $expectedEmbeddingDimension = [int]$serviceConfig.embedding_dim

        if ($serviceConfig.embedding_binding -eq "ollama") {
            $embeddings = Invoke-HealthRequest "ollama_tags" "$($serviceConfig.embeddings_url)/api/tags"
            if ($embeddings.ok -and -not [string]::IsNullOrWhiteSpace($serviceConfig.embedding_model)) {
                try {
                    $models = ($embeddings.content | ConvertFrom-Json).models
                    $embeddingModelPresent = @($models | Where-Object { $_.name -eq $serviceConfig.embedding_model -or $_.name -eq "$($serviceConfig.embedding_model):latest" }).Count -gt 0
                } catch {
                    $embeddingModelPresent = $false
                }
            }

            if ($embeddingModelPresent) {
                $embeddingProbe = Invoke-JsonPostRequest "ollama_embed" "$($serviceConfig.embeddings_url)/api/embed" @{
                    model = $serviceConfig.embedding_model
                    input = "LIQUIDATION LightRAG health check"
                }
                if ($embeddingProbe.ok) {
                    $embeddingVectorDimension = Get-EmbeddingVectorDimension $embeddingProbe.content
                    $embeddingDimensionMatch = ($embeddingVectorDimension -eq $expectedEmbeddingDimension)
                    $embeddingRouteOk = $embeddingDimensionMatch
                }
            }
        } else {
            $embeddings = Invoke-HealthRequest "embeddings_health" "$($serviceConfig.embeddings_url)/health"
            $embeddingModels = Invoke-HealthRequest "embeddings_models" "$($serviceConfig.embeddings_url)/v1/models"
            if ($embeddings.ok -and $embeddingModels.ok -and -not [string]::IsNullOrWhiteSpace($serviceConfig.embedding_model)) {
                try {
                    $models = ($embeddingModels.content | ConvertFrom-Json).data
                    $embeddingModelPresent = @($models | Where-Object { $_.id -eq $serviceConfig.embedding_model }).Count -gt 0
                    $embeddingRouteOk = $embeddingModelPresent
                } catch {
                    $embeddingRouteOk = $false
                }
            }
        }

        $freshness = Get-FreshnessReport -Config $config -Paths $paths -IndexedPath $indexedPath -LightRagUrl $serviceConfig.lightrag_url

        if ($lightrag.ok -and $primaryRouteOk -and $embeddingRouteOk -and $freshness.ok) {
            $status = "ok"
            $exitCode = 0
        } else {
            $status = "failed"
            $exitCode = 1
        }

        $report = [ordered]@{
            generated_at = (Get-Date).ToUniversalTime().ToString("o")
            status = $status
            env_file = $EnvFile
            indexed_path = $indexedPath
            lightrag = [ordered]@{
                ok = $lightrag.ok
                url = $lightrag.url
                status_code = $lightrag.status_code
                error = $lightrag.error
            }
            omniroute = [ordered]@{
                ok = $primaryRouteOk
                models_ok = $omniroute.ok
                url = $omniroute.url
                status_code = $omniroute.status_code
                configured_model = $serviceConfig.llm_model
                configured_model_present = $configuredModelPresent
                chat_completion_ok = $omnirouteChat.ok
                chat_completion_status_code = $omnirouteChat.status_code
                chat_completion_error = $omnirouteChat.error
                model_check_error = $modelCheckError
                error = $omniroute.error
            }
            freedeepseek = [ordered]@{
                ok = $freedeepseek.ok
                url = $freedeepseek.url
                status_code = $freedeepseek.status_code
                models_ok = $freedeepseekModels.ok
                selected_model = $fallbackModel
                chat_completion_ok = $(if ($freedeepseekChat) { $freedeepseekChat.ok } else { $false })
                fallback_available = $fallbackRouteOk
                fallback_note = "Diagnostic only. LightRAG is configured for Omniroute, so FreeDeepseek availability alone does not make RAG usable."
                error = $freedeepseek.error
            }
            embeddings = [ordered]@{
                ok = $embeddingRouteOk
                binding = $serviceConfig.embedding_binding
                url = $serviceConfig.embeddings_url
                status_code = $(if ($embeddings) { $embeddings.status_code } else { $null })
                embedding_model = $serviceConfig.embedding_model
                embedding_model_present = $embeddingModelPresent
                expected_dimension = $expectedEmbeddingDimension
                observed_dimension = $embeddingVectorDimension
                embedding_dimension_match = $embeddingDimensionMatch
                models_url = $(if ($embeddingModels) { $embeddingModels.url } else { $null })
                models_status_code = $(if ($embeddingModels) { $embeddingModels.status_code } else { $null })
                models_error = $(if ($embeddingModels) { $embeddingModels.error } else { $null })
                probe_url = $(if ($embeddingProbe) { $embeddingProbe.url } else { $null })
                probe_status_code = $(if ($embeddingProbe) { $embeddingProbe.status_code } else { $null })
                probe_error = $(if ($embeddingProbe) { $embeddingProbe.error } else { $null })
                error = $(if ($embeddings) { $embeddings.error } else { $null })
            }
            freshness = $freshness
        }

        Write-JsonAtomic -Value $report -Path $paths.health_report -Depth 14
        Write-Output "$status`: health report written: $($paths.health_report)"
        exit $exitCode
    }
    "status" {
        $config = Read-DotEnv $EnvFile
        $paths = Get-ReportPaths $config
        $indexedPath = Get-ConfiguredIndexedPath -Config $config -RequestedPath $Path
        Assert-AllowedIndexedPath -IndexedPath $indexedPath -Config $config

        if (-not (Test-Path $paths.metadata)) {
            Write-Output "failed: missing $($paths.metadata)"
            exit 1
        }

        $metadata = Get-Content -Raw $paths.metadata | ConvertFrom-Json
        $current = Get-CurrentCommit
        $currentTreeHash = Get-DocsTreeHash $indexedPath
        $dirty = Test-DocsPathDirty $indexedPath

        $docsTreeHashMatch = ($metadata.docs_tree_hash -eq $currentTreeHash -and $metadata.indexed_path -eq $indexedPath)
        $commitMatch = ($metadata.indexed_commit -eq $current)

        if ($docsTreeHashMatch -and (-not $dirty) -and ((-not $CheckCommit) -or $commitMatch)) {
            Write-Output "fresh: docs_tree_hash_match=$docsTreeHashMatch commit_match=$commitMatch indexed_path=$indexedPath"
            exit 0
        }

        Write-Output "stale: docs_tree_hash_match=$docsTreeHashMatch commit_match=$commitMatch docs_path_dirty=$dirty indexed_path=$indexedPath indexed_commit=$($metadata.indexed_commit) current_commit=$current"
        exit 1
    }
}
