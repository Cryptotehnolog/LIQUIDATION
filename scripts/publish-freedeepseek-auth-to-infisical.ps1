param(
    [string]$EnvFile = "infra/lightrag/.env",
    [string]$AuthPath = "",
    [string]$SecretName = "FREE_DEEPSEEK_AUTH_JSON",
    [string]$InfisicalEnvironment = "dev",
    [string]$InfisicalPath = "/",
    [string]$InfisicalProjectId = "",
    [string]$InfisicalToken = "",
    [string]$InfisicalDomain = "",
    [switch]$DryRun
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

    $root = [System.IO.Path]::GetFullPath((Join-Path (Get-Location) "infra/lightrag/data"))
    $candidate = Resolve-ProjectPath $Path

    if (-not $candidate.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing path outside LIQUIDATION infra/lightrag/data: $Path"
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

    return $raw
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

function Invoke-Infisical {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    $cmd = (Get-Command infisical.cmd -ErrorAction SilentlyContinue).Source
    if (-not $cmd) {
        $cmd = (Get-Command infisical -ErrorAction Stop).Source
    }

    $processInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $processInfo.FileName = $cmd
    $processInfo.Arguments = Join-NativeArgs $Arguments
    $processInfo.RedirectStandardOutput = $true
    $processInfo.RedirectStandardError = $true
    $processInfo.UseShellExecute = $false

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $processInfo
    $process.Start() | Out-Null
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()

    $output = (($stdout, $stderr) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join [Environment]::NewLine
    if ($process.ExitCode -ne 0) {
        throw "Infisical command failed. CLI output: $($output | Out-String)"
    }

    return $output
}

if ([string]::IsNullOrWhiteSpace($InfisicalProjectId)) {
    throw "InfisicalProjectId is required. Refusing to publish FreeDeepseek auth without explicit LIQUIDATION project id."
}

$config = Read-DotEnv $EnvFile

if ([string]::IsNullOrWhiteSpace($AuthPath)) {
    $configuredAuth = Get-ConfigValue $config "FREE_DEEPSEEK_AUTH_FILE" "./data/secrets/deepseek-auth.json"
    if ([System.IO.Path]::IsPathRooted($configuredAuth)) {
        $AuthPath = $configuredAuth
    } else {
        $AuthPath = Join-Path "infra/lightrag" $configuredAuth
    }
}

Assert-DataPath $AuthPath
$authFullPath = Resolve-ProjectPath $AuthPath
Assert-AuthJson $authFullPath | Out-Null

if ($DryRun) {
    Write-Output "dry-run: Infisical secret publish skipped"
    Write-Output "project id: $InfisicalProjectId"
    Write-Output "environment: $InfisicalEnvironment"
    Write-Output "path: $InfisicalPath"
    Write-Output "secret: $SecretName"
    exit 0
}

$secretAssignment = "$SecretName=@$authFullPath"
$args = @(
    "secrets", "set", $secretAssignment,
    "--env=$InfisicalEnvironment",
    "--path=$InfisicalPath",
    "--projectId=$InfisicalProjectId",
    "--silent"
)

if (-not [string]::IsNullOrWhiteSpace($InfisicalToken)) {
    $args += "--token=$InfisicalToken"
}
if (-not [string]::IsNullOrWhiteSpace($InfisicalDomain)) {
    $args += "--domain=$InfisicalDomain"
}

Invoke-Infisical $args | Out-Null
Write-Output "FreeDeepseek auth published to LIQUIDATION Infisical secret: $SecretName"
