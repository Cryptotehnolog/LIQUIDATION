param(
    [string]$SecretName = "FREE_DEEPSEEK_AUTH_JSON",
    [string]$InfisicalEnvironment = "dev",
    [string]$InfisicalPath = "/",
    [string]$InfisicalProjectId = "",
    [string]$InfisicalToken = "",
    [string]$InfisicalDomain = "http://127.0.0.1:8080",
    [string]$RoundtripAuthPath = "infra/lightrag/data/secrets/roundtrip-check/deepseek-auth.json",
    [string]$FreeDeepseekWorkDir = "infra/lightrag/data/freedeepseek-auth-work",
    [switch]$KeepTemp,
    [switch]$ValidateOnly
)

$ErrorActionPreference = "Stop"

function Resolve-ProjectPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }

    return [System.IO.Path]::GetFullPath((Join-Path (Get-Location) $Path))
}

function Get-RelativePath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $basePath = [System.IO.Path]::GetFullPath((Get-Location).Path)
    if (-not $basePath.EndsWith([System.IO.Path]::DirectorySeparatorChar)) {
        $basePath += [System.IO.Path]::DirectorySeparatorChar
    }

    $baseUri = [System.Uri]::new($basePath)
    $targetUri = [System.Uri]::new((Resolve-ProjectPath $Path))
    [System.Uri]::UnescapeDataString($baseUri.MakeRelativeUri($targetUri).ToString()).Replace("/", [System.IO.Path]::DirectorySeparatorChar)
}

function Assert-DataPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $root = [System.IO.Path]::GetFullPath((Join-Path (Get-Location) "infra/lightrag/data"))
    if (-not $root.EndsWith([System.IO.Path]::DirectorySeparatorChar)) {
        $root += [System.IO.Path]::DirectorySeparatorChar
    }
    $candidate = Resolve-ProjectPath $Path

    if (-not $candidate.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing path outside LIQUIDATION infra/lightrag/data: $Path"
    }
}

function Assert-Ignored {
    param([Parameter(Mandatory = $true)][string]$Path)

    $relative = Get-RelativePath $Path
    git check-ignore -q $relative
    if ($LASTEXITCODE -ne 0) {
        throw "Refusing to use path because it is not ignored by Git: $relative"
    }
}

if ([string]::IsNullOrWhiteSpace($InfisicalProjectId)) {
    throw "InfisicalProjectId is required. Refusing roundtrip without explicit LIQUIDATION project id."
}

Assert-DataPath $RoundtripAuthPath
Assert-DataPath $FreeDeepseekWorkDir
Assert-Ignored $RoundtripAuthPath

$roundtripFullPath = Resolve-ProjectPath $RoundtripAuthPath
$workFullPath = Resolve-ProjectPath $FreeDeepseekWorkDir

if (-not (Test-Path $workFullPath)) {
    throw "FreeDeepseek work dir not found: $workFullPath"
}

if ($ValidateOnly) {
    Write-Output "verify-infisical-roundtrip validation passed"
    Write-Output "roundtrip auth path: $roundtripFullPath"
    Write-Output "work dir: $workFullPath"
    exit 0
}

$roundtripDir = Split-Path $roundtripFullPath -Parent
$roundtripEnv = Join-Path $roundtripDir "roundtrip.env"
New-Item -ItemType Directory -Force -Path $roundtripDir | Out-Null

if (Test-Path $roundtripFullPath) {
    Remove-Item -LiteralPath $roundtripFullPath -Force
}

try {
    "FREE_DEEPSEEK_AUTH_FILE=./data/secrets/roundtrip-check/deepseek-auth.json" | Set-Content -LiteralPath $roundtripEnv -Encoding ASCII

    $bootstrapArgs = @{
        EnvFile = $roundtripEnv
        SecretName = $SecretName
        InfisicalEnvironment = $InfisicalEnvironment
        InfisicalPath = $InfisicalPath
        InfisicalProjectId = $InfisicalProjectId
    }
    if (-not [string]::IsNullOrWhiteSpace($InfisicalToken)) {
        $bootstrapArgs["InfisicalToken"] = $InfisicalToken
    }
    if (-not [string]::IsNullOrWhiteSpace($InfisicalDomain)) {
        $bootstrapArgs["InfisicalDomain"] = $InfisicalDomain
    }

    & .\scripts\bootstrap-freedeepseek-auth.ps1 @bootstrapArgs
    if ($LASTEXITCODE -ne 0) {
        throw "bootstrap-freedeepseek-auth failed"
    }

    $env:DEEPSEEK_AUTH_PATH = $roundtripFullPath
    Push-Location $workFullPath
    try {
        npm run doctor -- --offline
        if ($LASTEXITCODE -ne 0) {
            throw "FreeDeepseek doctor failed"
        }
    } finally {
        Pop-Location
    }

    Write-Output "Infisical roundtrip verification passed"
} finally {
    if (-not $KeepTemp) {
        if (Test-Path $roundtripFullPath) {
            Remove-Item -LiteralPath $roundtripFullPath -Force
        }
        if (Test-Path $roundtripEnv) {
            Remove-Item -LiteralPath $roundtripEnv -Force
        }
        if ((Test-Path $roundtripDir) -and -not (Get-ChildItem -Force -LiteralPath $roundtripDir)) {
            Remove-Item -LiteralPath $roundtripDir -Force
        }
    }
}
