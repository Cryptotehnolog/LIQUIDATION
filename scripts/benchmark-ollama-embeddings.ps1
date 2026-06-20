param(
    [string]$Model = "nomic-embed-text",
    [string]$OllamaBaseUrl = "http://127.0.0.1:11434",
    [string]$OutputPath = "docs/reports/rag/ollama-embedding-benchmark.json",
    [int]$Runs = 5,
    [int]$ExpectedDimension = 768
)

$ErrorActionPreference = "Stop"

if ($Runs -lt 1) {
    throw "Runs must be >= 1"
}

function Invoke-OllamaEmbed {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$ModelName
    )

    $body = @{
        model = $ModelName
        input = $Text
    } | ConvertTo-Json

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $response = Invoke-RestMethod "$OllamaBaseUrl/api/embed" -Method Post -ContentType "application/json" -Body $body -TimeoutSec 60
    $sw.Stop()
    $dimensions = @($response.embeddings[0]).Count
    if ($dimensions -ne $ExpectedDimension) {
        throw "Ollama embedding dimension mismatch for $ModelName`: observed=$dimensions expected=$ExpectedDimension"
    }

    return [ordered]@{
        elapsed_ms = $sw.ElapsedMilliseconds
        dimensions = $dimensions
    }
}

$version = Invoke-RestMethod "$OllamaBaseUrl/api/version" -TimeoutSec 10
$tags = Invoke-RestMethod "$OllamaBaseUrl/api/tags" -TimeoutSec 10
$modelPresent = @($tags.models | Where-Object { $_.name -eq $Model -or $_.name -eq "$Model`:latest" }).Count -gt 0

if (-not $modelPresent) {
    throw "Ollama model is not installed: $Model"
}

$samples = @(
    "Liquidation cascades meet prediction markets",
    "Каскады ликвидаций и предсказательные рынки: стратегия статистического арбитража",
    ("risk model fees slippage hedge fill replay " * 80)
)

$results = foreach ($sample in $samples) {
    $measurements = @()
    $dimensions = $null
    for ($i = 0; $i -lt $Runs; $i++) {
        $result = Invoke-OllamaEmbed -Text $sample -ModelName $Model
        $measurements += $result.elapsed_ms
        $dimensions = $result.dimensions
    }

    [ordered]@{
        chars = $sample.Length
        dimensions = $dimensions
        min_ms = ($measurements | Measure-Object -Minimum).Minimum
        avg_ms = [math]::Round(($measurements | Measure-Object -Average).Average, 1)
        max_ms = ($measurements | Measure-Object -Maximum).Maximum
    }
}

$report = [ordered]@{
    generated_at = (Get-Date).ToUniversalTime().ToString("o")
    ollama_base_url = $OllamaBaseUrl
    ollama_version = $version.version
    model = $Model
    expected_dimension = $ExpectedDimension
    runs = $Runs
    results = $results
}

New-Item -ItemType Directory -Force -Path (Split-Path -Parent $OutputPath) | Out-Null
$report | ConvertTo-Json -Depth 10 | Set-Content -Encoding UTF8 $OutputPath
Write-Output "benchmark written: $OutputPath"
