param(
    [string]$ComposeFile = "infra/lightrag/compose.yml",
    [string]$EnvFile = "infra/lightrag/.env.example",
    [string]$ProjectName = "liquidation"
)

$ErrorActionPreference = "Stop"

function Assert-LiquidationName {
    param(
        [Parameter(Mandatory = $true)][string]$Kind,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if (-not $Name.StartsWith("liquidation-")) {
        throw "$Kind '$Name' must start with liquidation-"
    }
}

$configText = docker compose --env-file $EnvFile -f $ComposeFile -p $ProjectName config --format json
$config = $configText | ConvertFrom-Json

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
