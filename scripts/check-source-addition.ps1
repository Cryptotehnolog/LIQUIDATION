param(
    [string[]]$Source = @("bybit", "binance", "okx")
)

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

function Assert-Contains {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Needle,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Missing file: $Path"
    }

    $content = Get-Content -Raw -LiteralPath $Path
    if (-not $content.Contains($Needle)) {
        throw $Message
    }
}

function Assert-File {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw $Message
    }
}

$sourceMatrix = @{
    bybit = @{
        "enum" = "Bybit"
        module = "bybit"
        fixture = "crates/liq-connectors/tests/fixtures/bybit_all_liquidation.json"
        quality = "all_events"
        role = "strategy_primary"
        signal = "participates_in_signals: true"
        docs = "bybit"
    }
    binance = @{
        "enum" = "Binance"
        module = "binance"
        fixture = "crates/liq-connectors/tests/fixtures/binance_force_order.json"
        quality = "snapshot_only"
        role = "diagnostic_only"
        signal = "participates_in_signals: false"
        docs = "binance"
    }
    okx = @{
        "enum" = "Okx"
        module = "okx"
        fixture = "crates/liq-connectors/tests/fixtures/okx_liquidation_orders.json"
        quality = "websocket_only"
        role = "diagnostic_only"
        signal = "participates_in_signals: false"
        docs = "okx"
    }
}

foreach ($name in $Source) {
    if (-not $sourceMatrix.ContainsKey($name)) {
        throw "Unknown source '$name'. Add it to sourceMatrix before expecting the guard to pass."
    }

    $spec = $sourceMatrix[$name]
    $enum = [string]$spec.enum
    $module = [string]$spec.module

    Assert-Contains "crates/liq-domain/src/source.rs" $enum "Source enum is missing $enum"
    Assert-Contains "crates/liq-domain/src/source.rs" "`"$name`"" "Source::as_str is missing '$name'"
    Assert-Contains "crates/liq-config/src/lib.rs" "pub $name`: SourceConfig" "Config is missing sources.$name"
    Assert-Contains "config/default.toml" "[sources.$name]" "default.toml is missing [sources.$name]"
    Assert-Contains "crates/liq-connectors/src/lib.rs" "pub mod $module;" "liq-connectors is missing module $module"
    Assert-File ([string]$spec.fixture) "Connector fixture is missing for $name"
    Assert-Contains "crates/liq-connectors/tests/normalization.rs" $module "normalization tests do not reference $module"
    Assert-Contains "crates/liq-collector/src/source.rs" $enum "collector source routing is missing $enum"
    Assert-Contains "crates/liq-recorder/src/repository.rs" "`"$name`"" "dashboard source policy is missing $name"
    Assert-Contains "crates/liq-recorder/src/repository.rs" ([string]$spec.quality) "dashboard source policy has wrong/missing quality for $name"
    Assert-Contains "crates/liq-recorder/src/repository.rs" ([string]$spec.role) "dashboard source policy has wrong/missing role for $name"
    Assert-Contains "crates/liq-recorder/src/repository.rs" ([string]$spec.signal) "dashboard source policy has wrong/missing signal flag for $name"
    Assert-Contains "docs/runbooks/source-addition.md" ([string]$spec.docs) "source-addition runbook is missing $name"
}

Write-Host "source addition guard ok: $($Source -join ', ')"
