param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet("health", "status", "ingest", "eval")]
    [string]$Command,

    [Parameter(Position = 1)]
    [string]$Path = "docs/",

    [string]$EnvFile = "infra/aperag/.env",

    [string]$AdminSecretsFile = "infra/aperag/data/secrets/aperag-admin.env",

    [string]$EvalFile = "docs/reports/aperag/eval-questions.json",

    [string]$CollectionTitle = "",

    [int]$WaitTimeoutSec = 900,

    [int]$PollSeconds = 10,

    [switch]$CheckCommit,

    [switch]$CheckDrift
)

$ErrorActionPreference = "Stop"

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
        $response = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 15
        return [ordered]@{
            name = $Name
            ok = ($response.StatusCode -ge 200 -and $response.StatusCode -lt 500)
            url = $Url
            status_code = $response.StatusCode
            error = $null
        }
    } catch {
        return [ordered]@{
            name = $Name
            ok = $false
            url = $Url
            status_code = $null
            error = $_.Exception.Message
        }
    }
}

function Invoke-HealthPostJson {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)]$Body
    )

    try {
        $json = $Body | ConvertTo-Json -Depth 20 -Compress
        $response = Invoke-WebRequest -Method Post -Uri $Url -ContentType "application/json" -Body $json -UseBasicParsing -TimeoutSec 60
        return [ordered]@{
            name = $Name
            ok = ($response.StatusCode -ge 200 -and $response.StatusCode -lt 300)
            url = $Url
            status_code = $response.StatusCode
            error = $null
        }
    } catch {
        $statusCode = $null
        if ($_.Exception.Response) {
            $statusCode = [int]$_.Exception.Response.StatusCode
        }
        return [ordered]@{
            name = $Name
            ok = $false
            url = $Url
            status_code = $statusCode
            error = $_.Exception.Message
        }
    }
}

function Invoke-ApeRagJson {
    param(
        [Parameter(Mandatory = $true)][ValidateSet("Delete", "Get", "Post", "Put")][string]$Method,
        [Parameter(Mandatory = $true)][string]$Uri,
        $Body = $null,
        [Microsoft.PowerShell.Commands.WebRequestSession]$Session = $null,
        [switch]$AllowFailure
    )

    $params = @{
        Method = $Method
        Uri = $Uri
        TimeoutSec = 120
        UseBasicParsing = $true
        ContentType = "application/json"
    }
    if ($Session) {
        $params.WebSession = $Session
    }
    if ($null -ne $Body) {
        $params.Body = ConvertTo-ApeRagJsonBody -Body $Body
    }

    try {
        $response = Invoke-WebRequest @params
        if ($null -eq $response.RawContentStream) {
            return $null
        }

        $response.RawContentStream.Position = 0
        $memory = New-Object System.IO.MemoryStream
        try {
            $response.RawContentStream.CopyTo($memory)
            $text = [System.Text.Encoding]::UTF8.GetString($memory.ToArray())
        } finally {
            $memory.Dispose()
        }

        if ([string]::IsNullOrWhiteSpace($text)) {
            return $null
        }

        return $text | ConvertFrom-Json
    } catch {
        if ($AllowFailure) {
            return $null
        }
        throw
    }
}

function ConvertTo-ApeRagJsonBody {
    param($Body)

    if ($Body -is [System.Array]) {
        $items = foreach ($item in $Body) {
            $item | ConvertTo-Json -Depth 30 -Compress
        }
        return "[" + ($items -join ",") + "]"
    }

    return ($Body | ConvertTo-Json -Depth 30 -Compress)
}

function New-ApeRagSession {
    param(
        [Parameter(Mandatory = $true)][string]$ApiUrl,
        [Parameter(Mandatory = $true)][string]$AdminSecretsFile
    )

    if (-not (Test-Path -LiteralPath $AdminSecretsFile)) {
        throw "ApeRAG admin secrets file not found: $AdminSecretsFile. Run scripts/setup-aperag-routing.ps1 first."
    }

    $admin = Read-DotEnv $AdminSecretsFile
    foreach ($required in @("APERAG_ADMIN_USERNAME", "APERAG_ADMIN_PASSWORD")) {
        if (-not $admin.ContainsKey($required) -or [string]::IsNullOrWhiteSpace($admin[$required])) {
            throw "ApeRAG admin secrets file misses $required"
        }
    }

    $session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
    Invoke-ApeRagJson -Method Post -Uri "$ApiUrl/api/v1/login" -Body @{
        username = $admin["APERAG_ADMIN_USERNAME"]
        password = $admin["APERAG_ADMIN_PASSWORD"]
    } -Session $session | Out-Null

    return $session
}

function Ensure-ApeRagCollection {
    param(
        [Parameter(Mandatory = $true)][string]$ApiUrl,
        [Parameter(Mandatory = $true)][Microsoft.PowerShell.Commands.WebRequestSession]$Session,
        [Parameter(Mandatory = $true)][string]$Title,
        [Parameter(Mandatory = $true)][string]$EmbeddingModel,
        [Parameter(Mandatory = $true)][string]$CompletionModel
    )

    $collectionBody = @{
        title = $Title
        description = "LIQUIDATION automated development memory. Source of truth: repository docs."
        config = @{
            source = "system"
            enable_vector = $true
            enable_fulltext = $true
            enable_knowledge_graph = $false
            enable_summary = $false
            enable_vision = $false
            language = "en-US"
            embedding = @{
                model = $EmbeddingModel
                model_service_provider = "liquidation-embedding"
                custom_llm_provider = "openai"
            }
            completion = @{
                model = $CompletionModel
                model_service_provider = "liquidation-free-deepseek"
                custom_llm_provider = "openai"
                temperature = 0.1
            }
        }
    }

    $collections = Invoke-ApeRagJson -Method Get -Uri "$ApiUrl/api/v1/collections?page=1&page_size=100&include_subscribed=false" -Session $Session
    $existing = @($collections.items | Where-Object { $_.title -eq $Title -and $_.type -eq "document" -and $_.status -eq "ACTIVE" } | Select-Object -First 1)
    if ($existing.Count -gt 0) {
        $current = Invoke-ApeRagJson -Method Get -Uri "$ApiUrl/api/v1/collections/$($existing[0].id)" -Session $Session
        $needsUpdate = (
            $null -eq $current.config.embedding -or
            $current.config.embedding.model_service_provider -ne "liquidation-embedding" -or
            $current.config.embedding.model -ne $EmbeddingModel -or
            $null -eq $current.config.completion -or
            $current.config.completion.model_service_provider -ne "liquidation-free-deepseek" -or
            $current.config.completion.model -ne $CompletionModel
        )
        if ($needsUpdate) {
            return Invoke-ApeRagJson -Method Put -Uri "$ApiUrl/api/v1/collections/$($existing[0].id)" -Body $collectionBody -Session $Session
        }
        return $current
    }

    # Backend validates upload collections through config.source = system.
    # source.category = upload from OpenAPI is not accepted by create_collection.
    $collectionBody["type"] = "document"
    return Invoke-ApeRagJson -Method Post -Uri "$ApiUrl/api/v1/collections" -Body $collectionBody -Session $Session
}

function Clear-ApeRagCollectionDocuments {
    param(
        [Parameter(Mandatory = $true)][string]$ApiUrl,
        [Parameter(Mandatory = $true)][Microsoft.PowerShell.Commands.WebRequestSession]$Session,
        [Parameter(Mandatory = $true)][string]$CollectionId
    )

    $documents = @(Get-ApeRagDocuments -ApiUrl $ApiUrl -Session $Session -CollectionId $CollectionId)
    if ($documents.Count -eq 0) {
        return 0
    }

    $ids = @($documents | ForEach-Object { [string]$_.id })
    Invoke-ApeRagJson -Method Delete -Uri "$ApiUrl/api/v1/collections/$CollectionId/documents" -Body $ids -Session $Session | Out-Null
    return $ids.Count
}

function Get-DocsTreeHash {
    param([Parameter(Mandatory = $true)][string]$DocsPath)

    $files = Get-IngestFiles $DocsPath

    if (-not $files) {
        throw "No tracked docs found for path '$DocsPath'"
    }

    $entries = foreach ($file in $files) {
        $blobHash = (git hash-object -- $file).Trim()
        "$blobHash  $file"
    }

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes((($entries -join "`n") + "`n"))
        (($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString("x2") }) -join "")
    } finally {
        $sha.Dispose()
    }
}

function Get-IngestFiles {
    param([Parameter(Mandatory = $true)][string]$DocsPath)

    $allowedExtensions = @(".md", ".txt")
    git ls-files --cached --others --exclude-standard -- $DocsPath |
        Where-Object { Test-Path -LiteralPath $_ } |
        Where-Object { $allowedExtensions -contains ([System.IO.Path]::GetExtension($_).ToLowerInvariant()) } |
        Where-Object { $_ -notmatch '(^|/)(secrets?|credentials?|cookies?|private|keys?|auth)(/|$)' } |
        Where-Object { ([System.IO.Path]::GetFileName($_)) -notmatch '(?i)(secret|credential|token|password|api[-_]?key|private[-_]?key|cookie)' } |
        Where-Object { $_ -notmatch '(^|/)\.env(\.|$)' } |
        Where-Object { $_ -notmatch '(^|/)(node_modules|target|\.git|infra/aperag/data)(/|$)' } |
        Where-Object { $_ -notmatch '^docs/research/raw/' } |
        Sort-Object
}

function ConvertTo-ApeRagFileName {
    param([Parameter(Mandatory = $true)][string]$RelativePath)

    $name = $RelativePath -replace '^[.][\\/]', ''
    $name = $name -replace '[\\/]+', '__'
    $name = $name -replace '[^A-Za-z0-9А-Яа-яЁё._-]+', '_'
    return $name
}

function New-ApeRagIngestCopy {
    param(
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [Parameter(Mandatory = $true)][string]$DestinationDir
    )

    $relative = $SourcePath -replace '\\', '/'
    $fileName = ConvertTo-ApeRagFileName $relative
    $extension = [System.IO.Path]::GetExtension($SourcePath).ToLowerInvariant()
    if ($extension -eq ".json") {
        $fileName = $fileName + ".md"
    }
    $destination = Join-Path $DestinationDir $fileName
    $blobHash = (git hash-object -- $SourcePath).Trim()
    $content = [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $SourcePath), [System.Text.Encoding]::UTF8)
    $header = @(
        "---"
        "source_path: $relative"
        "git_blob_hash: $blobHash"
        "---"
        ""
    ) -join "`n"
    if ($extension -eq ".json") {
        $content = "JSON source follows:`n`n" + $content
    }
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($destination, ($header + $content), $utf8NoBom)

    return [ordered]@{
        source_path = $relative
        upload_path = $destination
        upload_name = $fileName
        git_blob_hash = $blobHash
    }
}

function Invoke-ApeRagMultipartUpload {
    param(
        [Parameter(Mandatory = $true)][string]$ApiUrl,
        [Parameter(Mandatory = $true)][Microsoft.PowerShell.Commands.WebRequestSession]$Session,
        [Parameter(Mandatory = $true)][string]$CollectionId,
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string]$FileName
    )

    Add-Type -AssemblyName System.Net.Http
    $handler = New-Object System.Net.Http.HttpClientHandler
    $handler.CookieContainer = $Session.Cookies
    $client = New-Object System.Net.Http.HttpClient($handler)
    $multipart = New-Object System.Net.Http.MultipartFormDataContent
    $stream = [System.IO.File]::OpenRead((Resolve-Path -LiteralPath $FilePath))
    try {
        $fileContent = New-Object System.Net.Http.StreamContent($stream)
        $fileContent.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::Parse("text/plain")
        $multipart.Add($fileContent, "file", $FileName)
        $response = $client.PostAsync("$ApiUrl/api/v1/collections/$CollectionId/documents/upload", $multipart).GetAwaiter().GetResult()
        $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        if (-not $response.IsSuccessStatusCode) {
            throw "ApeRAG upload failed for ${FileName}: HTTP $([int]$response.StatusCode) $body"
        }
        return $body | ConvertFrom-Json
    } finally {
        $stream.Dispose()
        $multipart.Dispose()
        $client.Dispose()
        $handler.Dispose()
    }
}

function Get-ApeRagDocuments {
    param(
        [Parameter(Mandatory = $true)][string]$ApiUrl,
        [Parameter(Mandatory = $true)][Microsoft.PowerShell.Commands.WebRequestSession]$Session,
        [Parameter(Mandatory = $true)][string]$CollectionId
    )

    $documents = @()
    $page = 1
    $pageSize = 100
    do {
        $result = Invoke-ApeRagJson -Method Get -Uri "$ApiUrl/api/v1/collections/$CollectionId/documents?page=$page&page_size=$pageSize&sort_by=created&sort_order=desc" -Session $Session
        $items = @()
        if ($result.items) {
            $items = @($result.items)
            $documents += $items
        }
        $page += 1
    } while ($items.Count -eq $pageSize)

    if ($documents.Count -gt 0) {
        return $documents
    }
    return @()
}

function Get-ApeRagDocumentStatusDrift {
    param(
        [Parameter(Mandatory = $true)][object[]]$Documents,
        [string[]]$ExpectedNames = @()
    )

    $readyNonComplete = @()
    $blocking = @()
    $expectedSet = @{}
    foreach ($name in @($ExpectedNames)) {
        if (-not [string]::IsNullOrWhiteSpace($name)) {
            $expectedSet[$name] = $true
        }
    }
    $remoteSet = @{}
    foreach ($doc in @($Documents)) {
        $remoteSet[[string]$doc.name] = $true
        $status = [string]$doc.status
        $vector = [string]$doc.vector_index_status
        $fulltext = [string]$doc.fulltext_index_status
        $vectorOk = ($doc.vector_index_status -in @("ACTIVE", "SKIPPED"))
        $fulltextOk = ($doc.fulltext_index_status -in @("ACTIVE", "SKIPPED"))
        $terminalBad = ($status -in @("FAILED", "DELETED", "EXPIRED"))

        if (-not $terminalBad -and $status -ne "COMPLETE" -and $vectorOk -and $fulltextOk) {
            $readyNonComplete += [ordered]@{
                id = [string]$doc.id
                name = [string]$doc.name
                status = $status
                vector_index_status = if ($vector) { $vector } else { $null }
                fulltext_index_status = if ($fulltext) { $fulltext } else { $null }
            }
            continue
        }

        if ($terminalBad -or -not $vectorOk -or -not $fulltextOk) {
            $blocking += [ordered]@{
                id = [string]$doc.id
                name = [string]$doc.name
                status = $status
                vector_index_status = if ($vector) { $vector } else { $null }
                fulltext_index_status = if ($fulltext) { $fulltext } else { $null }
            }
        }
    }

    $missing = @()
    foreach ($name in $expectedSet.Keys) {
        if (-not $remoteSet.ContainsKey($name)) {
            $missing += $name
        }
    }
    $extra = @()
    if ($expectedSet.Count -gt 0) {
        foreach ($name in $remoteSet.Keys) {
            if (-not $expectedSet.ContainsKey($name)) {
                $extra += $name
            }
        }
    }

    return [ordered]@{
        status = if ($blocking.Count -gt 0 -or $missing.Count -gt 0 -or $extra.Count -gt 0) { "failed" } elseif ($readyNonComplete.Count -gt 0) { "warning" } else { "ok" }
        ready_non_complete_count = $readyNonComplete.Count
        blocking_count = $blocking.Count
        missing_count = $missing.Count
        extra_count = $extra.Count
        ready_non_complete = $readyNonComplete
        blocking = $blocking
        missing = @($missing | Sort-Object)
        extra = @($extra | Sort-Object)
    }
}

function Wait-ApeRagDocumentsReady {
    param(
        [Parameter(Mandatory = $true)][string]$ApiUrl,
        [Parameter(Mandatory = $true)][Microsoft.PowerShell.Commands.WebRequestSession]$Session,
        [Parameter(Mandatory = $true)][string]$CollectionId,
        [Parameter(Mandatory = $true)][string[]]$ExpectedNames,
        [Parameter(Mandatory = $true)][int]$TimeoutSec,
        [Parameter(Mandatory = $true)][int]$PollSeconds
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    do {
        $documents = Get-ApeRagDocuments -ApiUrl $ApiUrl -Session $Session -CollectionId $CollectionId
        $byName = @{}
        foreach ($doc in $documents) {
            $byName[[string]$doc.name] = $doc
        }

        $notReady = @()
        foreach ($name in $ExpectedNames) {
            if (-not $byName.ContainsKey($name)) {
                $notReady += "$name missing"
                continue
            }
            $doc = $byName[$name]
            $statusOk = ($doc.status -eq "COMPLETE")
            $vectorOk = ($doc.vector_index_status -in @("ACTIVE", "SKIPPED"))
            $fulltextOk = ($doc.fulltext_index_status -in @("ACTIVE", "SKIPPED"))
            if (-not $statusOk -or -not $vectorOk -or -not $fulltextOk) {
                $notReady += "$name status=$($doc.status) vector=$($doc.vector_index_status) fulltext=$($doc.fulltext_index_status)"
            }
        }

        if ($notReady.Count -eq 0) {
            return $documents
        }

        Start-Sleep -Seconds $PollSeconds
    } while ((Get-Date) -lt $deadline)

    throw "ApeRAG indexing timeout after ${TimeoutSec}s. Not ready: $($notReady -join '; ')"
}

function Invoke-ApeRagEval {
    param(
        [Parameter(Mandatory = $true)][string]$ApiUrl,
        [Parameter(Mandatory = $true)][Microsoft.PowerShell.Commands.WebRequestSession]$Session,
        [Parameter(Mandatory = $true)][string]$CollectionId,
        [Parameter(Mandatory = $true)][string]$EvalFile
    )

    if (-not (Test-Path -LiteralPath $EvalFile)) {
        throw "Eval file not found: $EvalFile"
    }

    $evalSet = [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $EvalFile), [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    $evalTopK = 5
    $results = @()
    foreach ($case in $evalSet.questions) {
        $expectedAny = @()
        if ($null -ne $case.expected_any) {
            $expectedAny = @($case.expected_any | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
        }
        $expectedAll = @()
        if ($null -ne $case.expected_all) {
            $expectedAll = @($case.expected_all | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
        }
        $search = Invoke-ApeRagJson -Method Post -Uri "$ApiUrl/api/v1/collections/$CollectionId/searches" -Body @{
            query = $case.query
            vector_search = @{ topk = $evalTopK; similarity = 0 }
            save_to_history = $false
            rerank = $false
        } -Session $Session

        $expectedSource = [string]$case.expected_source
        $bestMatchedAny = @()
        $bestMissingAny = @($expectedAny)
        $bestMatchedAll = @()
        $bestMissingAll = @($expectedAll)
        $matchedSource = $null
        foreach ($item in @($search.items)) {
            $source = [string]$item.source
            if (-not [string]::IsNullOrWhiteSpace($expectedSource) -and $source -ne $expectedSource) {
                continue
            }
            $itemText = "$($item.source)`n$($item.content)".ToLowerInvariant()
            $matchedAny = @()
            $missingAny = @()
            foreach ($term in $expectedAny) {
                if ($itemText.Contains(([string]$term).ToLowerInvariant())) {
                    $matchedAny += $term
                } else {
                    $missingAny += $term
                }
            }
            $matchedAll = @()
            $missingAll = @()
            foreach ($term in $expectedAll) {
                if ($itemText.Contains(([string]$term).ToLowerInvariant())) {
                    $matchedAll += $term
                } else {
                    $missingAll += $term
                }
            }
            if ($missingAll.Count -lt $bestMissingAll.Count -or ($missingAll.Count -eq $bestMissingAll.Count -and $matchedAny.Count -gt $bestMatchedAny.Count)) {
                $bestMatchedAny = $matchedAny
                $bestMissingAny = $missingAny
                $bestMatchedAll = $matchedAll
                $bestMissingAll = $missingAll
                $matchedSource = $source
            }
        }

        $anyPassed = ($expectedAny.Count -eq 0 -or $bestMatchedAny.Count -gt 0)
        $allPassed = ($bestMissingAll.Count -eq 0)
        $passed = ($anyPassed -and $allPassed)
        $results += [ordered]@{
            id = $case.id
            query = $case.query
            passed = $passed
            expected_source = if ([string]::IsNullOrWhiteSpace($expectedSource)) { $null } else { $expectedSource }
            matched_source = $matchedSource
            matched_any_terms = $bestMatchedAny
            missing_any_terms = $bestMissingAny
            matched_all_terms = $bestMatchedAll
            missing_all_terms = $bestMissingAll
            result_count = if ($search.items) { @($search.items).Count } else { 0 }
        }
    }

    $passedCount = @($results | Where-Object { $_.passed }).Count
    $totalCount = @($results).Count
    $score = if ($totalCount -gt 0) { [math]::Round($passedCount / $totalCount, 4) } else { 0 }
    return [ordered]@{
        generated_at = (Get-Date).ToUniversalTime().ToString("o")
        status = if ($passedCount -eq $totalCount -and $totalCount -gt 0) { "ok" } else { "failed" }
        score = $score
        passed = $passedCount
        total = $totalCount
        results = $results
    }
}

$config = Read-DotEnv $EnvFile
$hostName = Get-ConfigValue $config "APERAG_HOST" "127.0.0.1"
$apiUrl = "http://${hostName}:$(Get-ConfigValue $config "APERAG_API_PORT" "28000")"
$webUrl = "http://${hostName}:$(Get-ConfigValue $config "APERAG_WEB_PORT" "23000")"
$completionUrl = "http://${hostName}:$(Get-ConfigValue $config "LIQUIDATION_FREE_DEEPSEEK_PORT" "19655")"
$embeddingUrl = "http://${hostName}:$(Get-ConfigValue $config "LIQUIDATION_EMBEDDING_PORT" "28001")"
$primaryModel = Get-ConfigValue $config "APERAG_PRIMARY_MODEL" "deepseek-chat"
$embeddingModel = Get-ConfigValue $config "APERAG_EMBEDDING_MODEL" "sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2"
if ([string]::IsNullOrWhiteSpace($CollectionTitle)) {
    $CollectionTitle = Get-ConfigValue $config "APERAG_COLLECTION_TITLE" "LIQUIDATION Dev Memory"
}

switch ($Command) {
    "health" {
        $checks = @()
        $checks += Invoke-HealthRequest -Name "aperag_api_docs" -Url ($apiUrl + "/docs")
        $checks += Invoke-HealthRequest -Name "aperag_web" -Url ($webUrl + "/")
        $checks += Invoke-HealthRequest -Name "freedeepseek_models" -Url ($completionUrl + "/v1/models")
        $checks += Invoke-HealthRequest -Name "embedding_models" -Url ($embeddingUrl + "/v1/models")
        $checks += Invoke-HealthPostJson -Name "freedeepseek_chat" -Url ($completionUrl + "/v1/chat/completions") -Body @{
            model = $primaryModel
            messages = @(@{ role = "user"; content = "Reply exactly OK" })
            max_tokens = 8
            temperature = 0
        }
        $checks += Invoke-HealthPostJson -Name "embedding_vectors" -Url ($embeddingUrl + "/v1/embeddings") -Body @{
            model = $embeddingModel
            input = @("test document")
        }

        $aperagOk = ($checks | Where-Object { $_.name -in @("aperag_api_docs", "aperag_web") -and -not $_.ok }).Count -eq 0
        $completionOk = (($checks | Where-Object { $_.name -eq "freedeepseek_chat" }).ok -eq $true)
        $embeddingOk = (($checks | Where-Object { $_.name -eq "embedding_vectors" }).ok -eq $true)

        $routingStatus = if ($completionOk -and $embeddingOk) {
            "ok"
        } elseif ($completionOk) {
            "degraded-but-usable"
        } else {
            "failed"
        }

        $status = if ($aperagOk -and $routingStatus -ne "failed") { $routingStatus } else { "failed" }

        [ordered]@{
            generated_at = (Get-Date).ToUniversalTime().ToString("o")
            status = $status
            routing_status = $routingStatus
            memory_status = if ($embeddingOk) { "ready-for-ingest" } else { "completion-only-no-embedding" }
            checks = $checks
        } | ConvertTo-Json -Depth 8

        if ($status -eq "failed") {
            exit 1
        }
    }
    "status" {
        $currentCommit = (git rev-parse HEAD).Trim()
        $metadataPath = Get-ConfigValue $config "APERAG_INDEX_METADATA" "docs/reports/aperag/index-metadata.json"
        $metadataExists = Test-Path $metadataPath
        $metadataCommit = $null
        $commitMatches = $null
        $currentDocsTreeHash = Get-DocsTreeHash $Path
        $metadataDocsTreeHash = $null
        $docsTreeHashMatches = $null

        if ($metadataExists) {
            $metadata = [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $metadataPath), [System.Text.Encoding]::UTF8) | ConvertFrom-Json
            $metadataCommit = [string]$metadata.git_commit
            $commitMatches = ($metadataCommit -eq $currentCommit)
            $metadataDocsTreeHash = [string]$metadata.docs_tree_hash
            $docsTreeHashMatches = ($metadataDocsTreeHash -eq $currentDocsTreeHash)
        }

        $drift = $null
        if ($CheckDrift) {
            if (-not $metadataExists -or [string]::IsNullOrWhiteSpace([string]$metadata.collection_id)) {
                throw "Cannot check ApeRAG drift without index metadata. Run ingest first."
            }
            $session = New-ApeRagSession -ApiUrl $apiUrl -AdminSecretsFile $AdminSecretsFile
            $documents = @(Get-ApeRagDocuments -ApiUrl $apiUrl -Session $session -CollectionId ([string]$metadata.collection_id))
            $expectedNames = @()
            if ($metadata.uploaded) {
                $expectedNames = @($metadata.uploaded | ForEach-Object { [string]$_.upload_name })
            }
            $drift = Get-ApeRagDocumentStatusDrift -Documents $documents -ExpectedNames $expectedNames
        }

        [ordered]@{
            generated_at = (Get-Date).ToUniversalTime().ToString("o")
            current_commit = $currentCommit
            indexed_path = $Path
            docs_tree_hash = $currentDocsTreeHash
            check_commit = [bool]$CheckCommit
            index_metadata_path = $metadataPath
            index_metadata_exists = $metadataExists
            index_git_commit = $metadataCommit
            index_commit_matches_current = $commitMatches
            index_docs_tree_hash = $metadataDocsTreeHash
            index_docs_tree_hash_matches_current = $docsTreeHashMatches
            collection_id = if ($metadataExists) { [string]$metadata.collection_id } else { $null }
            collection_title = if ($metadataExists) { [string]$metadata.collection_title } else { $CollectionTitle }
            drift_checked = [bool]$CheckDrift
            document_status_drift = $drift
        } | ConvertTo-Json -Depth 6

        if ($CheckCommit -and (-not $metadataExists -or -not $commitMatches -or -not $docsTreeHashMatches)) {
            exit 1
        }
        if ($CheckDrift -and $drift.status -ne "ok") {
            exit 1
        }
    }
    "ingest" {
        $healthJson = & $PSCommandPath health -EnvFile $EnvFile | ConvertFrom-Json
        if ($healthJson.memory_status -ne "ready-for-ingest") {
            throw "ApeRAG memory is not ready for ingest: $($healthJson.memory_status)"
        }

        $session = New-ApeRagSession -ApiUrl $apiUrl -AdminSecretsFile $AdminSecretsFile
        $collection = Ensure-ApeRagCollection -ApiUrl $apiUrl -Session $session -Title $CollectionTitle -EmbeddingModel $embeddingModel -CompletionModel $primaryModel
        $files = @(Get-IngestFiles $Path)
        if ($files.Count -eq 0) {
            throw "No ingestable docs found for path '$Path'"
        }
        $deletedCount = Clear-ApeRagCollectionDocuments -ApiUrl $apiUrl -Session $session -CollectionId $collection.id

        $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ("liquidation-aperag-ingest-" + [System.Guid]::NewGuid().ToString("N"))
        New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
        $prepared = @()
        $uploaded = @()
        $confirmIds = @()
        try {
            foreach ($file in $files) {
                $copy = New-ApeRagIngestCopy -SourcePath $file -DestinationDir $tmpDir
                $prepared += $copy
                $upload = Invoke-ApeRagMultipartUpload -ApiUrl $apiUrl -Session $session -CollectionId $collection.id -FilePath $copy.upload_path -FileName $copy.upload_name
                $uploaded += [ordered]@{
                    source_path = $copy.source_path
                    upload_name = $copy.upload_name
                    document_id = $upload.document_id
                    status = $upload.status
                }
                if ($upload.status -eq "UPLOADED") {
                    $confirmIds += [string]$upload.document_id
                }
            }

            $confirm = $null
            if ($confirmIds.Count -gt 0) {
                $confirm = Invoke-ApeRagJson -Method Post -Uri "$apiUrl/api/v1/collections/$($collection.id)/documents/confirm" -Body @{
                    document_ids = $confirmIds
                } -Session $session
                if ($confirm.failed_count -gt 0) {
                    throw "ApeRAG confirm failed for $($confirm.failed_count) documents: $($confirm.failed_documents | ConvertTo-Json -Compress)"
                }
            }

            $documents = Wait-ApeRagDocumentsReady -ApiUrl $apiUrl -Session $session -CollectionId $collection.id -ExpectedNames @($prepared | ForEach-Object { $_.upload_name }) -TimeoutSec $WaitTimeoutSec -PollSeconds $PollSeconds
            $metadataPath = Get-ConfigValue $config "APERAG_INDEX_METADATA" "docs/reports/aperag/index-metadata.json"
            $metadataDir = Split-Path -Parent $metadataPath
            if (-not (Test-Path -LiteralPath $metadataDir)) {
                New-Item -ItemType Directory -Path $metadataDir -Force | Out-Null
            }

            $documentStatusByName = @{}
            foreach ($document in @($documents)) {
                $documentStatusByName[[string]$document.name] = [ordered]@{
                    status = $document.status
                    vector_index_status = $document.vector_index_status
                    fulltext_index_status = $document.fulltext_index_status
                }
            }

            $finalUploaded = foreach ($item in $uploaded) {
                $finalStatus = if ($documentStatusByName.ContainsKey($item.upload_name)) { $documentStatusByName[$item.upload_name] } else { $null }
                [ordered]@{
                    source_path = $item.source_path
                    upload_name = $item.upload_name
                    document_id = $item.document_id
                    upload_status = $item.status
                    final_status = $finalStatus
                }
            }

            $metadata = [ordered]@{
                generated_at = (Get-Date).ToUniversalTime().ToString("o")
                git_commit = (git rev-parse HEAD).Trim()
                docs_tree_hash = Get-DocsTreeHash $Path
                indexed_path = $Path
                collection_id = $collection.id
                collection_title = $CollectionTitle
                file_count = $files.Count
                document_count = @($documents).Count
                deleted_before_ingest = $deletedCount
                embedding_model = $embeddingModel
                completion_model = $primaryModel
                ready_with_non_complete_status = @(
                    $documents |
                        Where-Object { $_.name -in @($prepared | ForEach-Object { $_.upload_name }) -and $_.status -ne "COMPLETE" } |
                        ForEach-Object {
                            [ordered]@{
                                name = $_.name
                                status = $_.status
                                vector_index_status = $_.vector_index_status
                                fulltext_index_status = $_.fulltext_index_status
                            }
                        }
                )
                uploaded = $finalUploaded
            }
            $metadata | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $metadataPath -Encoding UTF8
            $metadata | ConvertTo-Json -Depth 10
        } finally {
            if (Test-Path -LiteralPath $tmpDir) {
                Remove-Item -LiteralPath $tmpDir -Recurse -Force
            }
        }
    }
    "eval" {
        $metadataPath = Get-ConfigValue $config "APERAG_INDEX_METADATA" "docs/reports/aperag/index-metadata.json"
        if (-not (Test-Path -LiteralPath $metadataPath)) {
            throw "ApeRAG index metadata not found: $metadataPath. Run ingest first."
        }
        $metadata = Get-Content -Raw -LiteralPath $metadataPath | ConvertFrom-Json
        $currentCommit = (git rev-parse HEAD).Trim()
        $currentDocsTreeHash = Get-DocsTreeHash $metadata.indexed_path
        if ([string]$metadata.git_commit -ne $currentCommit) {
            throw "ApeRAG index is stale: metadata commit $($metadata.git_commit) != current commit $currentCommit"
        }
        if ([string]$metadata.docs_tree_hash -ne $currentDocsTreeHash) {
            throw "ApeRAG index is stale: metadata docs_tree_hash $($metadata.docs_tree_hash) != current docs_tree_hash $currentDocsTreeHash"
        }
        $session = New-ApeRagSession -ApiUrl $apiUrl -AdminSecretsFile $AdminSecretsFile
        $documents = @(Get-ApeRagDocuments -ApiUrl $apiUrl -Session $session -CollectionId $metadata.collection_id)
        $expectedNames = @()
        if ($metadata.uploaded) {
            $expectedNames = @($metadata.uploaded | ForEach-Object { [string]$_.upload_name })
        }
        $drift = Get-ApeRagDocumentStatusDrift -Documents $documents -ExpectedNames $expectedNames
        if ($drift.status -ne "ok") {
            throw "ApeRAG index drift blocks eval: $($drift | ConvertTo-Json -Depth 6 -Compress)"
        }
        $result = Invoke-ApeRagEval -ApiUrl $apiUrl -Session $session -CollectionId $metadata.collection_id -EvalFile $EvalFile
        $reportDir = Get-ConfigValue $config "APERAG_REPORT_PATH" "docs/reports/aperag"
        if (-not (Test-Path -LiteralPath $reportDir)) {
            New-Item -ItemType Directory -Path $reportDir -Force | Out-Null
        }
        $result | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $reportDir "eval-latest.json") -Encoding UTF8
        $result | ConvertTo-Json -Depth 10
        if ($result.status -ne "ok") {
            exit 1
        }
    }
}
