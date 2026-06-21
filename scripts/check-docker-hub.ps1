param(
    [string]$Image = "timescale/timescaledb:2.17.2-pg16",
    [switch]$Pull
)

$ErrorActionPreference = "Stop"

function Assert-DockerEngine {
    docker version --format "{{.Server.Version}}" *> $null
    if ($LASTEXITCODE -ne 0) {
        throw "Docker engine is not available. Start Docker Desktop and retry."
    }
}

function Get-DockerHubAuthState {
    $configPath = Join-Path $env:USERPROFILE ".docker\config.json"
    if (-not (Test-Path -LiteralPath $configPath)) {
        return [pscustomobject]@{
            ConfigPath = $configPath
            HasConfig = $false
            CredsStore = ""
            HasDockerHubAuth = $false
        }
    }

    $config = Get-Content -Raw -LiteralPath $configPath | ConvertFrom-Json
    $authHosts = @()
    if ($config.auths) {
        $authHosts = @($config.auths.PSObject.Properties.Name)
    }

    $dockerHubHosts = @(
        "https://index.docker.io/v1/",
        "docker.io",
        "registry-1.docker.io",
        "index.docker.io"
    )

    return [pscustomobject]@{
        ConfigPath = $configPath
        HasConfig = $true
        CredsStore = [string]$config.credsStore
        HasDockerHubAuth = [bool]($authHosts | Where-Object { $dockerHubHosts -contains $_ })
    }
}

Assert-DockerEngine
$authState = Get-DockerHubAuthState

if (-not $authState.HasDockerHubAuth) {
    Write-Output ($authState | ConvertTo-Json -Compress)
    throw "Docker Hub is not authenticated for this Windows user. Run 'docker login' or sign in through Docker Desktop, then retry."
}

if ($Pull) {
    docker pull $Image
    if ($LASTEXITCODE -ne 0) {
        throw "Docker Hub pull failed for image: $Image"
    }
}

Write-Output (@{
    status = "ok"
    image = $Image
    pull_checked = [bool]$Pull
    creds_store = $authState.CredsStore
} | ConvertTo-Json -Compress)
