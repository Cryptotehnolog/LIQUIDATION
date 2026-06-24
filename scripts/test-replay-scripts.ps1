$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$scripts = @(
    "scripts/run-latest-polymarket-replay.ps1",
    "scripts/collect-paper-replay-window.ps1",
    "scripts/wait-for-liquidation-replay.ps1",
    "scripts/controlled-replay.ps1"
)

function Assert-True {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

foreach ($relative in $scripts) {
    $path = Join-Path $repoRoot $relative
    $tokens = $null
    $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$parseErrors) | Out-Null
    Assert-True ($parseErrors.Count -eq 0) "$relative has PowerShell parse errors: $($parseErrors | ConvertTo-Json -Compress)"
}

$runLatest = Get-Content -Raw -LiteralPath (Join-Path $repoRoot "scripts/run-latest-polymarket-replay.ps1")
$collectWindow = Get-Content -Raw -LiteralPath (Join-Path $repoRoot "scripts/collect-paper-replay-window.ps1")
$waitForLiquidation = Get-Content -Raw -LiteralPath (Join-Path $repoRoot "scripts/wait-for-liquidation-replay.ps1")
$controlledReplay = Get-Content -Raw -LiteralPath (Join-Path $repoRoot "scripts/controlled-replay.ps1")

Assert-True ($runLatest.Contains("[switch]`$SkipFetch")) "run-latest-polymarket-replay.ps1 must expose -SkipFetch for wrapper scripts"
Assert-True ($runLatest.Contains("Remove-Item -LiteralPath `$ArtifactPath -Force")) "run-latest-polymarket-replay.ps1 must remove stale replay artifact before running"
Assert-True ($collectWindow.Contains('"--market-id", [string]$market.market_id')) "collect-paper-replay-window.ps1 must pin market_id for preflight/replay"
Assert-True ($collectWindow.Contains('"--up-token-id", [string]$market.up_token_id')) "collect-paper-replay-window.ps1 must pin up_token_id for preflight/replay"
Assert-True ($collectWindow.Contains('"--down-token-id", [string]$market.down_token_id')) "collect-paper-replay-window.ps1 must pin down_token_id for preflight/replay"
Assert-True (-not $collectWindow.Contains("run-latest-polymarket-replay.ps1")) "collect-paper-replay-window.ps1 should run replay directly with pinned args, not delegate to latest-market wrapper"
Assert-True ($collectWindow.Contains("cargo build -p liq-cli")) "collect-paper-replay-window.ps1 must build liq-cli once before parallel collector jobs"
Assert-True ($collectWindow.Contains("& `$BinaryPath @CollectorArgs")) "collect-paper-replay-window.ps1 must run the prebuilt liq.exe inside collector jobs"
Assert-True (-not $collectWindow.Contains('"run", "-p", "liq-cli", "--"')) "collect-paper-replay-window.ps1 must not start parallel cargo run jobs"
Assert-True ($collectWindow.Contains("-InputPath `$OkxInstrumentsFullPath")) "collect-paper-replay-window.ps1 must validate existing OKX instrument cache"
Assert-True ($collectWindow.Contains("[string]`$ArtifactPath")) "collect-paper-replay-window.ps1 must allow wrapper scripts to choose replay artifact path"
Assert-True ($collectWindow.Contains("--artifact-path `$ArtifactFullPath")) "collect-paper-replay-window.ps1 must write replay output to the resolved artifact path"
Assert-True ($collectWindow.Contains("collectorJobFailures")) "collect-paper-replay-window.ps1 must record collector job failures before data-level preflight"
Assert-True ($collectWindow.Contains("replay preflight")) "collect-paper-replay-window.ps1 must let replay preflight decide data completeness"
Assert-True (-not $collectWindow.Contains('throw "collector job $($job.Name) ended with state')) "collect-paper-replay-window.ps1 must not fail before preflight solely because a collector job ended failed"
Assert-True ($waitForLiquidation.Contains("[int]`$MaxWindows")) "wait-for-liquidation-replay.ps1 must bound the number of replay windows"
Assert-True ($waitForLiquidation.Contains("liquidations=0")) "wait-for-liquidation-replay.ps1 must only continue automatically on empty liquidation windows"
Assert-True ($waitForLiquidation.Contains("-RunReplay")) "wait-for-liquidation-replay.ps1 must delegate to collect-paper-replay-window.ps1 with -RunReplay"
Assert-True ($waitForLiquidation.Contains("[string]`$ReplayArtifactPath")) "wait-for-liquidation-replay.ps1 must expose replay artifact path for controlled replay"
Assert-True ($waitForLiquidation.Contains("`$ErrorActionPreference = `"Continue`"")) "wait-for-liquidation-replay.ps1 must not treat nested cargo stderr as a terminating PowerShell error"
Assert-True ($waitForLiquidation.Contains("Write-Output ([string]`$_)")) "wait-for-liquidation-replay.ps1 must print nested stderr as text, not ErrorRecord objects"
Assert-True ($controlledReplay.Contains("wait-for-liquidation-replay.ps1")) "controlled-replay.ps1 must reuse the bounded liquidation-window wrapper"
Assert-True ($controlledReplay.Contains("start-dashboard.ps1")) "controlled-replay.ps1 must open the read-only dashboard through the dashboard launcher"
Assert-True ($controlledReplay.Contains("-ReplayArtifactPath")) "controlled-replay.ps1 must pass replay artifact path through the chain"
Assert-True ($controlledReplay.Contains("[switch]`$PrintCommandsOnly")) "controlled-replay.ps1 must support a dry command preview mode"
Assert-True ($controlledReplay.Contains("Expected replay artifact was not written")) "controlled-replay.ps1 must fail if replay did not write the latest artifact"
Assert-True (-not $controlledReplay.Contains("replay run")) "controlled-replay.ps1 must orchestrate existing scripts, not duplicate replay CLI logic"
Assert-True ($controlledReplay.Contains("[switch]`$UntilEntryFilled")) "controlled-replay.ps1 must support running real windows until a Polymarket entry fill is observed"
Assert-True ($controlledReplay.Contains("[int]`$MaxReplayAttempts")) "controlled-replay.ps1 must bound the number of until-entry-filled attempts"
Assert-True ($controlledReplay.Contains("[string]`$AggregateReportPath")) "controlled-replay.ps1 must write an aggregate report for repeated real replay attempts"
Assert-True ($controlledReplay.Contains("Read-ReplayArtifactSummary")) "controlled-replay.ps1 must summarize each replay artifact"
Assert-True ($controlledReplay.Contains("Write-AggregateReport")) "controlled-replay.ps1 must persist aggregate replay statistics"
Assert-True ($controlledReplay.Contains("polymarket_fills")) "controlled-replay.ps1 must stop based on observed Polymarket entry fills"

Write-Output "replay script checks passed"
