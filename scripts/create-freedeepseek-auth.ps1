param(
    [string]$EnvFile = "infra/aperag/.env",
    [string]$AuthPath = "",
    [string]$WorkDir = "infra/aperag/data/freedeepseek-auth-work",
    [string]$ChromeProfile = "infra/aperag/data/chrome-profiles/freedeepseek-liq",
    [string]$FreeDeepseekRepo = "",
    [string]$FreeDeepseekRef = "",
    [switch]$ValidateOnly,
    [switch]$SkipInteractive,
    [switch]$SmokeTest
)

$ErrorActionPreference = "Stop"

function Read-DotEnv {
    param([Parameter(Mandatory = $true)][string]$Path)

    $values = @{}
    if (-not (Test-Path $Path)) {
        return $values
    }

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

function Resolve-ProjectPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }

    return [System.IO.Path]::GetFullPath((Join-Path (Get-Location) $Path))
}

function Assert-DataPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $root = [System.IO.Path]::GetFullPath((Join-Path (Get-Location) "infra/aperag/data"))
    if (-not $root.EndsWith([System.IO.Path]::DirectorySeparatorChar)) {
        $root += [System.IO.Path]::DirectorySeparatorChar
    }
    $candidate = Resolve-ProjectPath $Path

    if (-not $candidate.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing path outside LIQUIDATION infra/aperag/data: $Path"
    }
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

function Assert-Ignored {
    param([Parameter(Mandatory = $true)][string]$Path)

    $relative = Get-RelativePath $Path
    git check-ignore -q $relative
    if ($LASTEXITCODE -ne 0) {
        throw "Refusing to use path because it is not ignored by Git: $relative"
    }
}

function Assert-AuthJson {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path $Path)) {
        throw "FreeDeepseek auth file not found: $Path"
    }

    $raw = (Get-Content -Raw -LiteralPath $Path).TrimStart([char]0xFEFF)
    $json = $raw | ConvertFrom-Json
    foreach ($required in @("token", "cookie", "wasmUrl")) {
        if (-not $json.PSObject.Properties[$required] -or [string]::IsNullOrWhiteSpace($json.$required)) {
            throw "FreeDeepseek auth file is missing required field: $required"
        }
    }

    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($Path, $raw, $utf8NoBom)
}

function Invoke-Checked {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [string]$WorkingDirectory = (Get-Location)
    )

    & $FilePath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed: $FilePath $($Arguments -join ' ')"
    }
}

$config = Read-DotEnv $EnvFile

if ([string]::IsNullOrWhiteSpace($AuthPath)) {
    $configuredAuth = Get-ConfigValue $config "FREE_DEEPSEEK_AUTH_FILE" "./data/secrets/deepseek-auth.json"
    if ([System.IO.Path]::IsPathRooted($configuredAuth)) {
        $AuthPath = $configuredAuth
    } else {
        $AuthPath = Join-Path "infra/aperag" $configuredAuth
    }
}

if ([string]::IsNullOrWhiteSpace($FreeDeepseekRepo)) {
    $FreeDeepseekRepo = Get-ConfigValue $config "FREE_DEEPSEEK_REPO" "https://github.com/ForgetMeAI/FreeDeepseekAPI.git"
}
if ([string]::IsNullOrWhiteSpace($FreeDeepseekRef)) {
    $FreeDeepseekRef = Get-ConfigValue $config "FREE_DEEPSEEK_REF" "e54d324e1d6be1f4d074f5c7f078ae5d94deade8"
}

Assert-DataPath $AuthPath
Assert-DataPath $WorkDir
Assert-DataPath $ChromeProfile
Assert-Ignored $AuthPath
Assert-Ignored $WorkDir
Assert-Ignored $ChromeProfile

if ($ValidateOnly) {
    Write-Output "create-freedeepseek-auth validation passed"
    Write-Output "auth path: $(Resolve-ProjectPath $AuthPath)"
    Write-Output "work dir: $(Resolve-ProjectPath $WorkDir)"
    Write-Output "chrome profile: $(Resolve-ProjectPath $ChromeProfile)"
    exit 0
}

$authFullPath = Resolve-ProjectPath $AuthPath
$workFullPath = Resolve-ProjectPath $WorkDir
$profileFullPath = Resolve-ProjectPath $ChromeProfile

New-Item -ItemType Directory -Force -Path (Split-Path $authFullPath -Parent) | Out-Null
New-Item -ItemType Directory -Force -Path $profileFullPath | Out-Null

if (-not (Test-Path $workFullPath)) {
    Invoke-Checked "git" @("-c", "http.sslBackend=openssl", "clone", "--filter=blob:none", $FreeDeepseekRepo, $workFullPath)
    Invoke-Checked "git" @("-C", $workFullPath, "checkout", $FreeDeepseekRef)
}

if (-not (Test-Path (Join-Path $workFullPath "package.json"))) {
    throw "FreeDeepseek work directory is missing package.json: $workFullPath"
}

if (-not (Test-Path (Join-Path $workFullPath "node_modules"))) {
    Push-Location $workFullPath
    try {
        if (Test-Path "package-lock.json") {
            Invoke-Checked "npm" @("ci")
        } else {
            Invoke-Checked "npm" @("install")
        }
    } finally {
        Pop-Location
    }
}

if (-not $SkipInteractive) {
    $env:DEEPSEEK_AUTH_PATH = $authFullPath
    $env:DEEPSEEK_CHROME_PROFILE = $profileFullPath
    $env:DEEPSEEK_KEEP_CHROME_PROFILE = "1"
    Push-Location $workFullPath
    try {
        Invoke-Checked "npm" @("run", "auth", "--", "--login")
    } finally {
        Pop-Location
    }
}

Assert-AuthJson $authFullPath

$env:DEEPSEEK_AUTH_PATH = $authFullPath
Push-Location $workFullPath
try {
    Invoke-Checked "npm" @("run", "doctor", "--", "--offline")
} finally {
    Pop-Location
}

if ($SmokeTest) {
    $body = @{
        model = "deepseek-chat"
        messages = @(@{ role = "user"; content = "Reply with exactly one word: ok" })
        stream = $false
        user = "liquidation-refresh-smoke-test"
    } | ConvertTo-Json -Depth 8
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
    $response = Invoke-RestMethod -Uri "http://127.0.0.1:19655/v1/chat/completions" -Method Post -ContentType "application/json; charset=utf-8" -Body $bytes -TimeoutSec 120
    $content = [string]$response.choices[0].message.content
    if ($content.Trim().ToLowerInvariant() -ne "ok") {
        throw "FreeDeepseek smoke test returned unexpected content"
    }
}

Write-Output "FreeDeepseek auth is ready: $authFullPath"
