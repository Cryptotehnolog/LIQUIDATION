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

function Get-EnvValue {
    param(
        [Parameter(Mandatory = $true)]$Values,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if (-not $Values.ContainsKey($Name) -or [string]::IsNullOrWhiteSpace($Values[$Name])) {
        throw "Missing required env value: $Name"
    }

    return $Values[$Name]
}

function Invoke-Checked {
    param([Parameter(Mandatory = $true)][scriptblock]$Command)

    & $Command
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed with exit code ${LASTEXITCODE}: $Command"
    }
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
        [int]$TimeoutSeconds = 120,
        [int]$StableSeconds = 20
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $healthySince = $null
    while ((Get-Date) -lt $deadline) {
        $status = docker inspect --format "{{.State.Health.Status}}" $ContainerName 2>$null
        if ($LASTEXITCODE -eq 0 -and $status -eq "healthy") {
            if ($null -eq $healthySince) {
                $healthySince = Get-Date
            }
            if (((Get-Date) - $healthySince).TotalSeconds -ge $StableSeconds) {
                return
            }
        }
        else {
            $healthySince = $null
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
    & (Join-Path $ScriptDir "check-docker-hub.ps1") -Image "timescale/timescaledb:2.17.2-pg16" -Pull
    docker compose --env-file $EnvFile -f $ComposeFile -p $ProjectName up -d
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to start liquidation-timescaledb compose stack"
    }
    Wait-Healthy "liquidation-timescaledb"
}

$hostName = Get-EnvValue $envValues "LIQUIDATION_TIMESCALE_HOST"
$port = Get-EnvValue $envValues "LIQUIDATION_TIMESCALE_PORT"
$db = Get-EnvValue $envValues "LIQUIDATION_POSTGRES_DB"
$user = Get-EnvValue $envValues "LIQUIDATION_POSTGRES_USER"
$password = Get-EnvValue $envValues "LIQUIDATION_POSTGRES_PASSWORD"
$databaseUrl = "postgres://${user}:${password}@${hostName}:${port}/${db}"

Invoke-Checked { cargo run -p liq-cli -- db migrate --database-url $databaseUrl }
Invoke-Checked { cargo run -p liq-cli -- db migrate --database-url $databaseUrl }
Invoke-Checked { cargo run -p liq-cli -- db check-schema --database-url $databaseUrl }

Write-Output "recorder persistence checks passed"
