param(
    [string]$EnvFile = "infra/aperag/.env",
    [string]$SecretName = "FREE_DEEPSEEK_AUTH_JSON",
    [string]$InfisicalEnvironment = "dev",
    [string]$InfisicalPath = "/",
    [string]$InfisicalProjectId = "",
    [string]$InfisicalDomain = "",
    [switch]$StartFallback,
    [switch]$ValidateOnly
)

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $PSCommandPath
$RepoRoot = Split-Path -Parent $ScriptDir

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

function Resolve-AuthPath {
    param([Parameter(Mandatory = $true)]$Config)

    if (-not $Config.ContainsKey("FREE_DEEPSEEK_AUTH_FILE") -or [string]::IsNullOrWhiteSpace($Config["FREE_DEEPSEEK_AUTH_FILE"])) {
        throw "FREE_DEEPSEEK_AUTH_FILE is missing in $EnvFile"
    }

    $configured = $Config["FREE_DEEPSEEK_AUTH_FILE"]
    if ([System.IO.Path]::IsPathRooted($configured)) {
        return $configured
    }

    return (Join-Path (Join-Path $RepoRoot "infra/aperag") $configured)
}

function Assert-AuthPathScope {
    param([Parameter(Mandatory = $true)][string]$Path)

    $root = [System.IO.Path]::GetFullPath((Join-Path $RepoRoot "infra/aperag/data"))
    if (-not $root.EndsWith([System.IO.Path]::DirectorySeparatorChar)) {
        $root += [System.IO.Path]::DirectorySeparatorChar
    }
    if ([System.IO.Path]::IsPathRooted($Path)) {
        $candidate = [System.IO.Path]::GetFullPath($Path)
    } else {
        $candidate = [System.IO.Path]::GetFullPath((Join-Path $RepoRoot $Path))
    }

    if (-not $candidate.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to use FreeDeepseek auth path outside LIQUIDATION infra/aperag/data: $Path"
    }
}

function Assert-Ignored {
    param([Parameter(Mandatory = $true)][string]$Path)

    $candidate = [System.IO.Path]::GetFullPath($Path)
    $rootFull = [System.IO.Path]::GetFullPath($RepoRoot)
    if (-not $rootFull.EndsWith([System.IO.Path]::DirectorySeparatorChar)) {
        $rootFull += [System.IO.Path]::DirectorySeparatorChar
    }
    if (-not $candidate.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to check ignored status outside repository: $candidate"
    }
    $relative = $candidate.Substring($rootFull.Length).Replace([System.IO.Path]::DirectorySeparatorChar, "/")
    git -C $RepoRoot check-ignore -q -- $relative
    if ($LASTEXITCODE -ne 0) {
        throw "Refusing to write auth file because it is not ignored by Git: $relative"
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

function Join-NativeArgs {
    param([Parameter(Mandatory = $true)][string[]]$Items)

    return (($Items | ForEach-Object {
        if ($_ -match '[\s"]') {
            '"' + $_.Replace('\', '\\').Replace('"', '\"') + '"'
        } else {
            $_
        }
    }) -join " ")
}

function Join-CmdArgs {
    param([Parameter(Mandatory = $true)][string[]]$Items)

    return (($Items | ForEach-Object {
        if ($_ -match '[\s&()^|<>"]') {
            '"' + $_.Replace('"', '""') + '"'
        } else {
            $_
        }
    }) -join " ")
}

function Set-NativeCommand {
    param(
        [Parameter(Mandatory = $true)][System.Diagnostics.ProcessStartInfo]$ProcessInfo,
        [Parameter(Mandatory = $true)][string]$Command,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    if ($Command -match '\.(cmd|bat)$') {
        $ProcessInfo.FileName = $env:ComSpec
        $ProcessInfo.Arguments = "/d /c " + (Join-CmdArgs (@($Command) + $Arguments))
    } else {
        $ProcessInfo.FileName = $Command
        $ProcessInfo.Arguments = Join-NativeArgs $Arguments
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
    if (-not [string]::IsNullOrWhiteSpace($InfisicalDomain)) {
        $args += "--domain=$InfisicalDomain"
    }

    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $output = & $cmd @args 2>&1
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    $outputText = ($output | Out-String).Trim()
    if ($exitCode -ne 0) {
        throw "Infisical secret fetch failed. Provide LIQUIDATION project binding, --projectId, or INFISICAL_TOKEN environment variable. CLI output: $outputText"
    }

    return $outputText
}

if (-not [System.IO.Path]::IsPathRooted($EnvFile)) {
    $EnvFile = [System.IO.Path]::GetFullPath((Join-Path $RepoRoot $EnvFile))
}
$config = Read-DotEnv $EnvFile
$authPath = Resolve-AuthPath $config

Assert-AuthPathScope $authPath
Assert-Ignored $authPath

if ($ValidateOnly) {
    Write-Output "auth target is ignored: $authPath"
    exit 0
}

if ([string]::IsNullOrWhiteSpace($InfisicalProjectId)) {
    throw "InfisicalProjectId is required. Refusing to bootstrap FreeDeepseek auth without explicit LIQUIDATION project id."
}

$authJson = (Get-InfisicalSecret).TrimStart([char]0xFEFF)

Assert-Json $authJson

$authDir = Split-Path $authPath -Parent
New-Item -ItemType Directory -Force -Path $authDir | Out-Null
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[System.IO.File]::WriteAllText((Join-Path (Resolve-Path -LiteralPath $authDir).Path (Split-Path $authPath -Leaf)), $authJson, $utf8NoBom)

Assert-Ignored $authPath
Write-Output "FreeDeepseek auth written to ignored path: $authPath"

if ($StartFallback) {
    & (Join-Path $ScriptDir "check-images.ps1") -EnvFile $EnvFile
    & (Join-Path $ScriptDir "guard-compose.ps1") -EnvFile $EnvFile
    docker compose --env-file $EnvFile -f (Join-Path $RepoRoot "infra/aperag/compose.yml") -p liquidation --profile fallback up -d liquidation-free-deepseek

    Start-Sleep -Seconds 3
    Invoke-WebRequest "http://127.0.0.1:19655/health" -UseBasicParsing | Select-Object StatusCode,Content
}
