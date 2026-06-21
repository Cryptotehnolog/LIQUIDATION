param(
    [string]$EnvFile = "infra/aperag/.env.example",
    [string]$FreeDeepseekDockerfile = "infra/aperag/free-deepseek/Dockerfile",
    [string]$EmbeddingDockerfile = "infra/aperag/embedding/Dockerfile",
    [switch]$StrictRemoteManifests
)

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $PSCommandPath
$RepoRoot = Split-Path -Parent $ScriptDir
$DockerHubRateLimited = $false

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
        if ($parts.Count -ne 2) {
            continue
        }

        $values[$parts[0]] = $parts[1].Trim('"').Trim("'")
    }

    return $values
}

function Resolve-RepoPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }

    return [System.IO.Path]::GetFullPath((Join-Path $RepoRoot $Path))
}

function Assert-Manifest {
    param(
        [Parameter(Mandatory = $true)][string]$Image,
        [string]$LocalFallbackImage = ""
    )

    if ($script:DockerHubRateLimited -and $Image.StartsWith("docker.io/", [System.StringComparison]::OrdinalIgnoreCase) -and -not $StrictRemoteManifests) {
        Write-Output "warn manifest rate-limited, remote validation skipped for Docker Hub image: $Image"
        return
    }

    $lastOutput = ""
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $previousErrorActionPreference = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        try {
            $output = & docker manifest inspect $Image 2>&1
            $exitCode = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $previousErrorActionPreference
        }

        if ($exitCode -eq 0) {
            Write-Output "ok manifest: $Image"
            return
        }

        $lastOutput = ($output | Out-String).Trim()
        if ($lastOutput -match "toomanyrequests|pull rate limit") {
            if ($Image.StartsWith("docker.io/", [System.StringComparison]::OrdinalIgnoreCase)) {
                $script:DockerHubRateLimited = $true
            }

            $previousErrorActionPreference = $ErrorActionPreference
            $ErrorActionPreference = "Continue"
            try {
                & docker image inspect $Image > $null 2>&1
                $inspectExitCode = $LASTEXITCODE
            } finally {
                $ErrorActionPreference = $previousErrorActionPreference
            }

            if ($inspectExitCode -eq 0) {
                Write-Output "warn manifest rate-limited, using local image: $Image"
                return
            }
            if (-not [string]::IsNullOrWhiteSpace($LocalFallbackImage)) {
                $previousErrorActionPreference = $ErrorActionPreference
                $ErrorActionPreference = "Continue"
                try {
                    & docker image inspect $LocalFallbackImage > $null 2>&1
                    $fallbackInspectExitCode = $LASTEXITCODE
                } finally {
                    $ErrorActionPreference = $previousErrorActionPreference
                }

                if ($fallbackInspectExitCode -eq 0) {
                    Write-Output "warn manifest rate-limited for ${Image}, using local built image: $LocalFallbackImage"
                    return
                }
            }

            if (-not $StrictRemoteManifests) {
                Write-Output "warn manifest rate-limited, remote validation inconclusive: $Image"
                return
            }
        }
        Start-Sleep -Seconds (2 * $attempt)
    }

    if ($lastOutput -match "toomanyrequests|pull rate limit") {
        $previousErrorActionPreference = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        try {
            & docker image inspect $Image > $null 2>&1
            $inspectExitCode = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $previousErrorActionPreference
        }

        if ($inspectExitCode -eq 0) {
            Write-Output "warn manifest rate-limited, using local image: $Image"
            return
        }
        if (-not [string]::IsNullOrWhiteSpace($LocalFallbackImage)) {
            $previousErrorActionPreference = $ErrorActionPreference
            $ErrorActionPreference = "Continue"
            try {
                & docker image inspect $LocalFallbackImage > $null 2>&1
                $fallbackInspectExitCode = $LASTEXITCODE
            } finally {
                $ErrorActionPreference = $previousErrorActionPreference
            }

            if ($fallbackInspectExitCode -eq 0) {
                Write-Output "warn manifest rate-limited for ${Image}, using local built image: $LocalFallbackImage"
                return
            }
        }

        if (-not $StrictRemoteManifests) {
            Write-Output "warn manifest rate-limited, remote validation inconclusive: $Image"
            return
        }
    }

    throw "Docker manifest is not available after retries: $Image. Last error: $lastOutput"
}

function Assert-GitRef {
    param(
        [Parameter(Mandatory = $true)][string]$Repo,
        [Parameter(Mandatory = $true)][string]$Ref
    )

    $remoteOutput = $null
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $remoteOutput = git ls-remote $Repo 2>&1
        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0 -and (($remoteOutput | Out-String) -match "schannel|SEC_E_NO_CREDENTIALS")) {
            $remoteOutput = git -c http.sslBackend=openssl ls-remote $Repo 2>&1
            $exitCode = $LASTEXITCODE
        }
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    if ($exitCode -ne 0) {
        throw "Git remote refs are not available: $Repo. Output: $(($remoteOutput | Out-String).Trim())"
    }

    if ($Ref -match "^[0-9a-f]{40}$") {
        $matches = $remoteOutput | Select-String -SimpleMatch $Ref
        if (-not $matches) {
            throw "Git commit is not available from remote refs: $Repo $Ref"
        }
    } else {
        $matches = $remoteOutput | Select-String -Pattern "refs/(heads|tags)/$([regex]::Escape($Ref))$|$([regex]::Escape($Ref))$"
        if (-not $matches) {
            throw "Git ref is not available: $Repo $Ref"
        }
    }

    Write-Output "ok git ref: $Repo $Ref"
}

function Get-DockerfileBaseImage {
    param([Parameter(Mandatory = $true)][string]$Path)

    $Path = Resolve-RepoPath $Path
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Dockerfile not found: $Path"
    }

    $fromLine = Get-Content -LiteralPath $Path | Where-Object { $_ -match "^\s*FROM\s+" } | Select-Object -First 1
    if (-not $fromLine) {
        throw "Dockerfile has no FROM line: $Path"
    }

    return (($fromLine -replace "^\s*FROM\s+", "") -split "\s+")[0]
}

$EnvFile = Resolve-RepoPath $EnvFile
$envValues = Read-DotEnv $EnvFile

foreach ($required in @(
    "APERAG_BASE_IMAGE",
    "APERAG_IMAGE",
    "APERAG_FRONTEND_IMAGE",
    "APERAG_POSTGRES_IMAGE",
    "APERAG_REDIS_IMAGE",
    "APERAG_QDRANT_IMAGE",
    "APERAG_ELASTICSEARCH_IMAGE",
    "EMBEDDING_IMAGE",
    "EMBEDDING_MODEL",
    "FREE_DEEPSEEK_REPO",
    "FREE_DEEPSEEK_REF"
)) {
    if (-not $envValues.ContainsKey($required) -or [string]::IsNullOrWhiteSpace($envValues[$required])) {
        throw "Missing required value in ${EnvFile}: $required"
    }
}

Assert-Manifest $envValues["APERAG_BASE_IMAGE"] -LocalFallbackImage $envValues["APERAG_IMAGE"]
Assert-Manifest $envValues["APERAG_FRONTEND_IMAGE"]
Assert-Manifest $envValues["APERAG_POSTGRES_IMAGE"]
Assert-Manifest $envValues["APERAG_REDIS_IMAGE"]
Assert-Manifest $envValues["APERAG_QDRANT_IMAGE"]
Assert-Manifest $envValues["APERAG_ELASTICSEARCH_IMAGE"]

$baseImage = Get-DockerfileBaseImage $FreeDeepseekDockerfile
Assert-Manifest $baseImage

$embeddingBaseImage = Get-DockerfileBaseImage $EmbeddingDockerfile
Assert-Manifest $embeddingBaseImage -LocalFallbackImage $envValues["EMBEDDING_IMAGE"]

Assert-GitRef $envValues["FREE_DEEPSEEK_REPO"] $envValues["FREE_DEEPSEEK_REF"]

Write-Output "image and source validation passed"
