param(
    [string]$EnvFile = "infra/lightrag/.env.example",
    [string]$FreeDeepseekDockerfile = "infra/lightrag/free-deepseek/Dockerfile"
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
        if ($parts.Count -ne 2) {
            continue
        }

        $values[$parts[0]] = $parts[1].Trim('"').Trim("'")
    }

    return $values
}

function Assert-Manifest {
    param([Parameter(Mandatory = $true)][string]$Image)

    $lastOutput = ""
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $output = docker manifest inspect $Image 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Output "ok manifest: $Image"
            return
        }

        $lastOutput = ($output | Out-String).Trim()
        Start-Sleep -Seconds (2 * $attempt)
    }

    throw "Docker manifest is not available after retries: $Image. Last error: $lastOutput"
}

function Assert-GitRef {
    param(
        [Parameter(Mandatory = $true)][string]$Repo,
        [Parameter(Mandatory = $true)][string]$Ref
    )

    git ls-remote --exit-code $Repo $Ref > $null
    if ($LASTEXITCODE -ne 0) {
        throw "Git ref is not available: $Repo $Ref"
    }

    Write-Output "ok git ref: $Repo $Ref"
}

function Get-DockerfileBaseImage {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path $Path)) {
        throw "Dockerfile not found: $Path"
    }

    $fromLine = Get-Content $Path | Where-Object { $_ -match "^\s*FROM\s+" } | Select-Object -First 1
    if (-not $fromLine) {
        throw "Dockerfile has no FROM line: $Path"
    }

    return (($fromLine -replace "^\s*FROM\s+", "") -split "\s+")[0]
}

$envValues = Read-DotEnv $EnvFile

foreach ($required in @("OMNIROUTE_IMAGE", "LIGHTRAG_IMAGE", "FREE_DEEPSEEK_REPO", "FREE_DEEPSEEK_REF")) {
    if (-not $envValues.ContainsKey($required) -or [string]::IsNullOrWhiteSpace($envValues[$required])) {
        throw "Missing required value in ${EnvFile}: $required"
    }
}

Assert-Manifest $envValues["OMNIROUTE_IMAGE"]
Assert-Manifest $envValues["LIGHTRAG_IMAGE"]

$baseImage = Get-DockerfileBaseImage $FreeDeepseekDockerfile
Assert-Manifest $baseImage

Assert-GitRef $envValues["FREE_DEEPSEEK_REPO"] $envValues["FREE_DEEPSEEK_REF"]

Write-Output "image and source validation passed"
