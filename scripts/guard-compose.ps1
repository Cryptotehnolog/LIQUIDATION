param(
    [string]$ComposeFile = "infra/lightrag/compose.yml",
    [string]$EnvFile = "infra/lightrag/.env.example",
    [string]$ProjectName = "liquidation"
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
        throw "$Label path is outside LIQUIDATION infra/lightrag/data: $candidate"
    }
}

$envValues = Read-DotEnv $EnvFile
$lightRagHost = $envValues["LIGHTRAG_HOST"]
if ([string]::IsNullOrWhiteSpace($lightRagHost)) {
    throw "LIGHTRAG_HOST is required in $EnvFile"
}
if ($lightRagHost -notin @("127.0.0.1", "localhost")) {
    throw "LIGHTRAG_HOST must stay loopback-only for local safety. Refusing: $lightRagHost"
}

$configText = docker compose --env-file $EnvFile -f $ComposeFile -p $ProjectName config --format json
$config = $configText | ConvertFrom-Json
$allowedDataRoot = [System.IO.Path]::GetFullPath((Join-Path (Get-Location) "infra/lightrag/data"))

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
