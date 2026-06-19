param(
    [string]$EnvFile = "infra/lightrag/.env",
    [string]$SecretName = "FREE_DEEPSEEK_AUTH_JSON",
    [string]$InfisicalEnvironment = "dev",
    [string]$InfisicalPath = "/",
    [string]$InfisicalProjectId = "",
    [string]$InfisicalToken = "",
    [string]$InfisicalDomain = "",
    [string]$SourceAuthFile = "",
    [switch]$AllowCrossProjectCopy,
    [switch]$StartFallback,
    [switch]$ValidateOnly
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

function Resolve-AuthPath {
    param([Parameter(Mandatory = $true)]$Config)

    if (-not $Config.ContainsKey("FREE_DEEPSEEK_AUTH_FILE") -or [string]::IsNullOrWhiteSpace($Config["FREE_DEEPSEEK_AUTH_FILE"])) {
        throw "FREE_DEEPSEEK_AUTH_FILE is missing in $EnvFile"
    }

    $configured = $Config["FREE_DEEPSEEK_AUTH_FILE"]
    if ([System.IO.Path]::IsPathRooted($configured)) {
        return $configured
    }

    return (Join-Path "infra/lightrag" $configured)
}

function Assert-Ignored {
    param([Parameter(Mandatory = $true)][string]$Path)

    git check-ignore -q $Path
    if ($LASTEXITCODE -ne 0) {
        throw "Refusing to write auth file because it is not ignored by Git: $Path"
    }
}

function Assert-Json {
    param([Parameter(Mandatory = $true)][string]$Text)

    try {
        $Text | ConvertFrom-Json | Out-Null
    } catch {
        throw "Auth content is not valid JSON: $($_.Exception.Message)"
    }
}

function Get-InfisicalSecret {
    $cmd = (Get-Command infisical.cmd -ErrorAction SilentlyContinue).Source
    if (-not $cmd) {
        $cmd = (Get-Command infisical -ErrorAction Stop).Source
    }

    $args = @(
        "secrets", "get", $SecretName,
        "--env=$InfisicalEnvironment",
        "--path=$InfisicalPath",
        "--plain",
        "--silent"
    )

    if (-not [string]::IsNullOrWhiteSpace($InfisicalProjectId)) {
        $args += "--projectId=$InfisicalProjectId"
    }
    if (-not [string]::IsNullOrWhiteSpace($InfisicalToken)) {
        $args += "--token=$InfisicalToken"
    }
    if (-not [string]::IsNullOrWhiteSpace($InfisicalDomain)) {
        $args += "--domain=$InfisicalDomain"
    }

    $output = & $cmd @args 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Infisical secret fetch failed. Provide LIQUIDATION project binding, --projectId, or --token. CLI output: $($output | Out-String)"
    }

    return (($output | Out-String).Trim())
}

$config = Read-DotEnv $EnvFile
$authPath = Resolve-AuthPath $config

Assert-Ignored $authPath

if ($ValidateOnly) {
    Write-Output "auth target is ignored: $authPath"
    exit 0
}

if (-not [string]::IsNullOrWhiteSpace($SourceAuthFile)) {
    if (-not $AllowCrossProjectCopy) {
        throw "Refusing to copy SourceAuthFile without -AllowCrossProjectCopy. This prevents accidental reuse of another project's DeepSeek session."
    }
    if (-not (Test-Path $SourceAuthFile)) {
        throw "SourceAuthFile not found: $SourceAuthFile"
    }

    $authJson = (Get-Content -Raw $SourceAuthFile).TrimStart([char]0xFEFF)
} else {
    $authJson = (Get-InfisicalSecret).TrimStart([char]0xFEFF)
}

Assert-Json $authJson

New-Item -ItemType Directory -Force -Path (Split-Path $authPath -Parent) | Out-Null
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[System.IO.File]::WriteAllText((Resolve-Path (Split-Path $authPath -Parent)).Path + [System.IO.Path]::DirectorySeparatorChar + (Split-Path $authPath -Leaf), $authJson, $utf8NoBom)

Assert-Ignored $authPath
Write-Output "FreeDeepseek auth written to ignored path: $authPath"

if ($StartFallback) {
    .\scripts\check-images.ps1 -EnvFile $EnvFile
    .\scripts\guard-compose.ps1 -EnvFile $EnvFile
    docker compose --env-file $EnvFile -f infra/lightrag/compose.yml -p liquidation --profile fallback up -d liquidation-free-deepseek

    Start-Sleep -Seconds 3
    Invoke-WebRequest "http://127.0.0.1:19655/health" -UseBasicParsing | Select-Object StatusCode,Content
}
