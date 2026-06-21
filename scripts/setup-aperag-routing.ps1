param(
    [string]$EnvFile = "infra/aperag/.env",
    [string]$AdminSecretsFile = "infra/aperag/data/secrets/aperag-admin.env",
    [switch]$SkipDefaultModels
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

function Read-DotEnv {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Env file not found: $Path"
    }

    $values = @{}
    foreach ($line in Get-Content -LiteralPath $Path) {
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

function New-RandomPassword {
    $bytes = New-Object byte[] 32
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $rng.GetBytes($bytes)
        return [Convert]::ToBase64String($bytes).TrimEnd("=")
    } finally {
        $rng.Dispose()
    }
}

function Read-OrCreate-AdminSecrets {
    param([Parameter(Mandatory = $true)][string]$Path)

    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    if (-not (Test-Path -LiteralPath $Path)) {
        $password = New-RandomPassword
        @(
            "APERAG_ADMIN_USERNAME=liquidation-admin"
            "APERAG_ADMIN_EMAIL=liquidation-admin@example.local"
            "APERAG_ADMIN_PASSWORD=$password"
        ) | Set-Content -LiteralPath $Path -Encoding UTF8
    }

    return Read-DotEnv $Path
}

function Invoke-Json {
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
        TimeoutSec = 60
        UseBasicParsing = $true
        ContentType = "application/json"
    }
    if ($Session) {
        $params.WebSession = $Session
    }
    if ($null -ne $Body) {
        $params.Body = ($Body | ConvertTo-Json -Depth 20 -Compress)
    }

    try {
        return Invoke-RestMethod @params
    } catch {
        if ($AllowFailure) {
            return $null
        }
        throw
    }
}

function Test-OpenAiChat {
    param(
        [Parameter(Mandatory = $true)][string]$BaseUrl,
        [Parameter(Mandatory = $true)][string]$Model
    )

    $body = @{
        model = $Model
        messages = @(@{ role = "user"; content = "Reply exactly OK" })
        max_tokens = 8
        temperature = 0
    }
    try {
        $response = Invoke-WebRequest -Method Post -Uri "$BaseUrl/chat/completions" -ContentType "application/json" -Body ($body | ConvertTo-Json -Depth 20 -Compress) -UseBasicParsing -TimeoutSec 60
        return ($response.StatusCode -ge 200 -and $response.StatusCode -lt 300)
    } catch {
        return $false
    }
}

function Test-OpenAiEmbeddings {
    param(
        [Parameter(Mandatory = $true)][string]$BaseUrl,
        [Parameter(Mandatory = $true)][string]$Model
    )

    $body = @{
        model = $Model
        input = @("test document")
    }
    try {
        $response = Invoke-WebRequest -Method Post -Uri "$BaseUrl/embeddings" -ContentType "application/json" -Body ($body | ConvertTo-Json -Depth 20 -Compress) -UseBasicParsing -TimeoutSec 60
        return ($response.StatusCode -ge 200 -and $response.StatusCode -lt 300)
    } catch {
        return $false
    }
}

function Ensure-Provider {
    param(
        [Parameter(Mandatory = $true)][string]$ApiUrl,
        [Parameter(Mandatory = $true)][Microsoft.PowerShell.Commands.WebRequestSession]$Session,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][string]$BaseUrl
    )

    $payload = @{
        name = $Name
        label = $Label
        completion_dialect = "openai"
        embedding_dialect = "openai"
        allow_custom_base_url = $true
        base_url = $BaseUrl
        api_key = "liquidation-local-no-secret"
        status = "enable"
    }

    $existing = Invoke-Json -Method Get -Uri "$ApiUrl/api/v1/llm_providers/$Name" -Session $Session -AllowFailure
    if ($existing) {
        Invoke-Json -Method Put -Uri "$ApiUrl/api/v1/llm_providers/$Name" -Body $payload -Session $Session | Out-Null
    } else {
        Invoke-Json -Method Post -Uri "$ApiUrl/api/v1/llm_providers" -Body $payload -Session $Session | Out-Null
    }

    $current = Invoke-Json -Method Get -Uri "$ApiUrl/api/v1/llm_providers/$Name" -Session $Session
    if ($current.user_id -ne "public") {
        Invoke-Json -Method Post -Uri "$ApiUrl/api/v1/llm_providers/$Name/publish" -Session $Session | Out-Null
    }
}

function Remove-ProviderIfExists {
    param(
        [Parameter(Mandatory = $true)][string]$ApiUrl,
        [Parameter(Mandatory = $true)][Microsoft.PowerShell.Commands.WebRequestSession]$Session,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $existing = Invoke-Json -Method Get -Uri "$ApiUrl/api/v1/llm_providers/$Name" -Session $Session -AllowFailure
    if ($existing) {
        Invoke-Json -Method Delete -Uri "$ApiUrl/api/v1/llm_providers/$Name" -Session $Session | Out-Null
    }
}

function Ensure-Model {
    param(
        [Parameter(Mandatory = $true)][string]$ApiUrl,
        [Parameter(Mandatory = $true)][Microsoft.PowerShell.Commands.WebRequestSession]$Session,
        [Parameter(Mandatory = $true)][string]$Provider,
        [Parameter(Mandatory = $true)][string]$Api,
        [Parameter(Mandatory = $true)][string]$Model,
        [Parameter(Mandatory = $true)][string]$CustomProvider,
        [string[]]$Tags = @()
    )

    $payload = @{
        api = $Api
        model = $Model
        custom_llm_provider = $CustomProvider
        context_window = 128000
        max_input_tokens = 120000
        max_output_tokens = 8192
        tags = $Tags
    }

    $models = Invoke-Json -Method Get -Uri "$ApiUrl/api/v1/llm_providers/$Provider/models" -Session $Session
    $exists = $false
    if ($models.items) {
        $exists = (@($models.items | Where-Object { $_.api -eq $Api -and $_.model -eq $Model }).Count -gt 0)
    }

    if ($exists) {
        $encodedModel = [uri]::EscapeDataString($Model).Replace("%2F", "/")
        Invoke-Json -Method Put -Uri "$ApiUrl/api/v1/llm_providers/$Provider/models/$Api/$encodedModel" -Body $payload -Session $Session | Out-Null
    } else {
        Invoke-Json -Method Post -Uri "$ApiUrl/api/v1/llm_providers/$Provider/models" -Body $payload -Session $Session | Out-Null
    }
}

$config = Read-DotEnv $EnvFile
$hostName = Get-ConfigValue $config "APERAG_HOST" "127.0.0.1"
$apiUrl = "http://${hostName}:$(Get-ConfigValue $config "APERAG_API_PORT" "28000")"
$completionHostBase = "http://${hostName}:$(Get-ConfigValue $config "LIQUIDATION_FREE_DEEPSEEK_PORT" "19655")/v1"
$embeddingHostBase = "http://${hostName}:$(Get-ConfigValue $config "LIQUIDATION_EMBEDDING_PORT" "28001")/v1"
$completionContainerBase = "$(Get-ConfigValue $config "LIQUIDATION_FREE_DEEPSEEK_BASE_URL" "http://liquidation-free-deepseek:9655")/v1"
$embeddingContainerBase = "http://liquidation-embedding:8080/v1"
$completionModel = Get-ConfigValue $config "APERAG_PRIMARY_MODEL" "deepseek-chat"
$embeddingModel = Get-ConfigValue $config "APERAG_EMBEDDING_MODEL" "sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2"

if (-not (Test-OpenAiChat -BaseUrl $completionHostBase -Model $completionModel)) {
    throw "Primary FreeDeepseek completion model is not usable: $completionModel at $completionHostBase"
}
if (-not (Test-OpenAiEmbeddings -BaseUrl $embeddingHostBase -Model $embeddingModel)) {
    throw "Embedding model is not usable: $embeddingModel at $embeddingHostBase"
}

$admin = Read-OrCreate-AdminSecrets $AdminSecretsFile
$session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
$registerBody = @{
    username = $admin["APERAG_ADMIN_USERNAME"]
    email = $admin["APERAG_ADMIN_EMAIL"]
    password = $admin["APERAG_ADMIN_PASSWORD"]
}
Invoke-Json -Method Post -Uri "$apiUrl/api/v1/register" -Body $registerBody -Session $session -AllowFailure | Out-Null

$loginBody = @{
    username = $admin["APERAG_ADMIN_USERNAME"]
    password = $admin["APERAG_ADMIN_PASSWORD"]
}
Invoke-Json -Method Post -Uri "$apiUrl/api/v1/login" -Body $loginBody -Session $session | Out-Null

Ensure-Provider -ApiUrl $apiUrl -Session $session -Name "liquidation-free-deepseek" -Label "LIQUIDATION FreeDeepseek Completion" -BaseUrl $completionContainerBase
Ensure-Provider -ApiUrl $apiUrl -Session $session -Name "liquidation-embedding" -Label "LIQUIDATION Local Embeddings" -BaseUrl $embeddingContainerBase
Remove-ProviderIfExists -ApiUrl $apiUrl -Session $session -Name "liquidation-omniroute"

Ensure-Model -ApiUrl $apiUrl -Session $session -Provider "liquidation-free-deepseek" -Api "completion" -Model $completionModel -CustomProvider "openai" -Tags @("default_for_collection_completion", "default_for_agent_completion", "default_for_background_task", "recommend")
Ensure-Model -ApiUrl $apiUrl -Session $session -Provider "liquidation-embedding" -Api "embedding" -Model $embeddingModel -CustomProvider "openai" -Tags @("default_for_embedding", "recommend")

if (-not $SkipDefaultModels) {
    $defaults = @(
        @{ scenario = "default_for_collection_completion"; provider_name = "liquidation-free-deepseek"; model = $completionModel; custom_llm_provider = "openai" },
        @{ scenario = "default_for_agent_completion"; provider_name = "liquidation-free-deepseek"; model = $completionModel; custom_llm_provider = "openai" },
        @{ scenario = "default_for_background_task"; provider_name = "liquidation-free-deepseek"; model = $completionModel; custom_llm_provider = "openai" },
        @{ scenario = "default_for_embedding"; provider_name = "liquidation-embedding"; model = $embeddingModel; custom_llm_provider = "openai" }
    )
    Invoke-Json -Method Put -Uri "$apiUrl/api/v1/default_models" -Body @{ defaults = $defaults } -Session $session | Out-Null
}

$llmConfiguration = Invoke-Json -Method Get -Uri "$apiUrl/api/v1/llm_configuration" -Session $session
$defaultModels = Invoke-Json -Method Get -Uri "$apiUrl/api/v1/default_models" -Session $session
$projectProviders = @($llmConfiguration.providers | Where-Object { $_.name -like "liquidation-*" })
$projectModels = @($llmConfiguration.models | Where-Object { $_.provider_name -like "liquidation-*" })

[ordered]@{
    generated_at = (Get-Date).ToUniversalTime().ToString("o")
    status = "ok"
    api_url = $apiUrl
    primary = @{
        provider = "liquidation-free-deepseek"
        model = $completionModel
        chat_ok = $true
    }
    embedding = @{
        provider = "liquidation-embedding"
        model = $embeddingModel
        embeddings_ok = $true
    }
    providers = $projectProviders | Select-Object name, user_id, base_url
    models = $projectModels | Select-Object provider_name, api, model, tags
    default_models = $defaultModels.items
    note = "ApeRAG completion and embedding defaults are configured without OmniRoute dependency."
} | ConvertTo-Json -Depth 12
