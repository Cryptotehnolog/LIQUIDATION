param(
    [string]$ComposeFile = "infra/aperag/compose.yml",
    [string]$EnvFile = "infra/aperag/.env.example",
    [string]$ProjectName = "liquidation"
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

function Resolve-RepoPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }

    return [System.IO.Path]::GetFullPath((Join-Path $RepoRoot $Path))
}

function ConvertTo-RepoRelativePath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $candidate = [System.IO.Path]::GetFullPath($Path)
    $rootFull = [System.IO.Path]::GetFullPath($RepoRoot)
    if (-not $rootFull.EndsWith([System.IO.Path]::DirectorySeparatorChar)) {
        $rootFull += [System.IO.Path]::DirectorySeparatorChar
    }
    if (-not $candidate.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Path is outside repository: $candidate"
    }

    return $candidate.Substring($rootFull.Length).Replace([System.IO.Path]::DirectorySeparatorChar, "/")
}

function Assert-IgnoredByGit {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Label
    )

    $relative = ConvertTo-RepoRelativePath $Path
    git -C $RepoRoot check-ignore --quiet -- $relative
    if ($LASTEXITCODE -ne 0) {
        throw "$Label path must be ignored by Git: $relative"
    }
}

function Assert-LiquidationName {
    param(
        [Parameter(Mandatory = $true)][string]$Kind,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if (-not $Name.StartsWith("liquidation-")) {
        throw "$Kind '$Name' must start with liquidation-"
    }
}

function Assert-PathInside {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Label
    )

    $candidate = [System.IO.Path]::GetFullPath($Path)
    $rootFull = [System.IO.Path]::GetFullPath($Root)
    if (-not $rootFull.EndsWith([System.IO.Path]::DirectorySeparatorChar)) {
        $rootFull += [System.IO.Path]::DirectorySeparatorChar
    }

    if (-not $candidate.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "$Label path is outside LIQUIDATION infra/aperag/data: $candidate"
    }
}

$ComposeFile = Resolve-RepoPath $ComposeFile
$EnvFile = Resolve-RepoPath $EnvFile
$envValues = Read-DotEnv $EnvFile
$aperagHost = $envValues["APERAG_HOST"]
if ([string]::IsNullOrWhiteSpace($aperagHost)) {
    throw "APERAG_HOST is required in $EnvFile"
}
if ($aperagHost -notin @("127.0.0.1", "localhost")) {
    throw "APERAG_HOST must stay loopback-only for local safety. Refusing: $aperagHost"
}

$configText = docker compose --env-file $EnvFile -f $ComposeFile -p $ProjectName config --format json
$config = $configText | ConvertFrom-Json
$allowedDataRoot = [System.IO.Path]::GetFullPath((Join-Path $RepoRoot "infra/aperag/data"))

foreach ($service in $config.services.PSObject.Properties) {
    Assert-LiquidationName "service" $service.Name

    $containerName = [string]$service.Value.container_name
    if ($containerName) {
        Assert-LiquidationName "container_name" $containerName
    }

    if ($service.Value.networks) {
        foreach ($networkName in $service.Value.networks.PSObject.Properties.Name) {
            Assert-LiquidationName "service network" $networkName
        }
    }

    if ($service.Value.volumes) {
        foreach ($volume in $service.Value.volumes) {
            if ($volume.type -eq "bind" -and $volume.source) {
                Assert-PathInside ([string]$volume.source) $allowedDataRoot "bind mount"
            }
        }
    }
}

if ($config.networks) {
    foreach ($network in $config.networks.PSObject.Properties) {
        Assert-LiquidationName "network" $network.Name
        if ($network.Value.name) {
            Assert-LiquidationName "network.name" ([string]$network.Value.name)
        }
    }
}

if ($config.volumes) {
    foreach ($volume in $config.volumes.PSObject.Properties) {
        Assert-LiquidationName "volume" $volume.Name
        if ($volume.Value.name) {
            Assert-LiquidationName "volume.name" ([string]$volume.Value.name)
        }
    }
}

if ($config.secrets) {
    foreach ($secret in $config.secrets.PSObject.Properties) {
        Assert-LiquidationName "secret" $secret.Name
        if ($secret.Value.name) {
            Assert-LiquidationName "secret.name" ([string]$secret.Value.name)
        }
        if ($secret.Value.file) {
            $secretFile = [string]$secret.Value.file
            Assert-PathInside $secretFile $allowedDataRoot "secret file"
            Assert-IgnoredByGit $secretFile "secret file"
        }
    }
}

$forbiddenExactNames = @(
    "omniroute",
    "stat-arb-free-qwen",
    "stat-arb-free-deepseek",
    "aperag-frontend",
    "aperag-api",
    "aperag-es",
    "aperag-redis",
    "aperag-postgres",
    "aperag-qdrant",
    "stat-arb-infisical-backend",
    "stat-arb-infisical-redis",
    "stat-arb-infisical-db",
    "omniroute-data",
    "aperag_default",
    "free_deepseek_default",
    "free_qwen_default",
    "stat-arb-infisical_infisical"
)

foreach ($forbidden in $forbiddenExactNames) {
    if ($configText -match "(?m)""$([regex]::Escape($forbidden))""") {
        throw "compose config references forbidden second-project name: $forbidden"
    }
}

Write-Output "compose guard passed: only liquidation-* services, containers, networks, and volumes"
