param(
    [string]$EnvFile = "infra/timescaledb/.env.example",
    [string]$ComposeFile = "infra/timescaledb/compose.yml",
    [string]$ProjectName = "liquidation-timescaledb",
    [switch]$ConfigOnly,
    [switch]$Start
)

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $PSCommandPath
$RepoRoot = Split-Path -Parent $ScriptDir

function Resolve-RepoPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }

    return [System.IO.Path]::GetFullPath((Join-Path $RepoRoot $Path))
}

function Read-DotEnv {
    param([Parameter(Mandatory = $true)][string]$Path)

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

function Assert-LiquidationOnlyCompose {
    param([Parameter(Mandatory = $true)]$Config)

    foreach ($service in $Config.services.PSObject.Properties) {
        if (-not $service.Name.StartsWith("liquidation-")) {
            throw "Compose service must use liquidation-* name: $($service.Name)"
        }
        if ($service.Value.container_name -and -not ([string]$service.Value.container_name).StartsWith("liquidation-")) {
            throw "Compose container_name must use liquidation-* name: $($service.Value.container_name)"
        }
    }

    if ($Config.networks) {
        foreach ($network in $Config.networks.PSObject.Properties) {
            if (-not $network.Name.StartsWith("liquidation-")) {
                throw "Compose network must use liquidation-* name: $($network.Name)"
            }
            if ($network.Value.name -and -not ([string]$network.Value.name).StartsWith("liquidation-")) {
                throw "Compose network.name must use liquidation-* name: $($network.Value.name)"
            }
        }
    }
}

function Wait-Healthy {
    param(
        [Parameter(Mandatory = $true)][string]$ContainerName,
        [int]$TimeoutSeconds = 90
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $status = docker inspect --format "{{.State.Health.Status}}" $ContainerName 2>$null
        if ($LASTEXITCODE -eq 0 -and $status -eq "healthy") {
            return
        }
        Start-Sleep -Seconds 2
    }

    throw "Container did not become healthy: $ContainerName"
}

$EnvFile = Resolve-RepoPath $EnvFile
$ComposeFile = Resolve-RepoPath $ComposeFile
$envValues = Read-DotEnv $EnvFile

$configJson = docker compose --env-file $EnvFile -f $ComposeFile -p $ProjectName config --format json
$config = $configJson | ConvertFrom-Json
Assert-LiquidationOnlyCompose $config

if ($ConfigOnly) {
    Write-Output "recorder persistence compose config passed"
    return
}

if ($Start) {
    docker compose --env-file $EnvFile -f $ComposeFile -p $ProjectName up -d
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to start liquidation-timescaledb compose stack"
    }
    Wait-Healthy "liquidation-timescaledb"
}

$hostName = $envValues["LIQUIDATION_TIMESCALE_HOST"]
$port = $envValues["LIQUIDATION_TIMESCALE_PORT"]
$db = $envValues["POSTGRES_DB"]
$user = $envValues["POSTGRES_USER"]
$password = $envValues["POSTGRES_PASSWORD"]
$databaseUrl = "postgres://${user}:${password}@${hostName}:${port}/${db}"

cargo run -p liq-cli -- db migrate --database-url $databaseUrl
cargo run -p liq-cli -- db migrate --database-url $databaseUrl
cargo run -p liq-cli -- db check-schema --database-url $databaseUrl

Write-Output "recorder persistence checks passed"
