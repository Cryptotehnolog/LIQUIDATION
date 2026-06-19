$ErrorActionPreference = "Stop"

function Invoke-Script {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    $stdoutPath = Join-Path $env:TEMP ("liq-script-test-out-" + [Guid]::NewGuid().ToString("N") + ".txt")
    $stderrPath = Join-Path $env:TEMP ("liq-script-test-err-" + [Guid]::NewGuid().ToString("N") + ".txt")
    $scriptPath = (Resolve-Path $Path).Path

    $processArgs = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", $scriptPath
    ) + $Arguments

    $process = Start-Process powershell.exe `
        -ArgumentList $processArgs `
        -NoNewWindow `
        -PassThru `
        -Wait `
        -RedirectStandardOutput $stdoutPath `
        -RedirectStandardError $stderrPath

    return [pscustomobject]@{
        ExitCode = $process.ExitCode
        Output = ((Get-Content -Raw -LiteralPath $stdoutPath), (Get-Content -Raw -LiteralPath $stderrPath)) -join "`n"
    }
}

function Assert-True {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Assert-Contains {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Expected,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $Text.Contains($Expected)) {
        throw "$Message`nExpected: $Expected`nActual: $Text"
    }
}

$createScript = "scripts/create-freedeepseek-auth.ps1"
$publishScript = "scripts/publish-freedeepseek-auth-to-infisical.ps1"
$roundtripScript = "scripts/verify-infisical-roundtrip.ps1"

$createValidate = Invoke-Script $createScript @("-ValidateOnly")
Assert-True ($createValidate.ExitCode -eq 0) "create script validate-only should succeed for default ignored LIQUIDATION paths"
Assert-Contains $createValidate.Output "create-freedeepseek-auth validation passed" "create script should report validation success"

$externalCreate = Invoke-Script $createScript @(
    "-ValidateOnly",
    "-AuthPath",
    "D:\Statistical Arbitrage\data\free_deepseek\deepseek-auth.json"
)
Assert-True ($externalCreate.ExitCode -ne 0) "create script should reject auth paths outside LIQUIDATION data"
Assert-Contains $externalCreate.Output "outside LIQUIDATION infra/lightrag/data" "create script should explain path scope failure"

$publishWithoutProject = Invoke-Script $publishScript @("-DryRun")
Assert-True ($publishWithoutProject.ExitCode -ne 0) "publish script should require explicit LIQUIDATION project id"
Assert-Contains $publishWithoutProject.Output "InfisicalProjectId is required" "publish script should explain missing project id"

$publishDryRun = Invoke-Script $publishScript @(
    "-InfisicalProjectId",
    "liq-test-project-id",
    "-DryRun"
)
Assert-True ($publishDryRun.ExitCode -eq 0) "publish dry-run should validate local auth without contacting Infisical"
Assert-Contains $publishDryRun.Output "dry-run: Infisical secret publish skipped" "publish dry-run should report skipped write"

$publishSource = Get-Content -Raw -LiteralPath $publishScript
Assert-True (-not $publishSource.Contains('$SecretName=$authJson')) "publish script must not pass auth JSON through CLI arguments"
Assert-Contains $publishSource '@$authFullPath' "publish script should use Infisical file reference syntax"

$roundtripValidate = Invoke-Script $roundtripScript @(
    "-InfisicalProjectId",
    "liq-test-project-id",
    "-ValidateOnly"
)
Assert-True ($roundtripValidate.ExitCode -eq 0) "roundtrip validate-only should succeed for default ignored paths"
Assert-Contains $roundtripValidate.Output "verify-infisical-roundtrip validation passed" "roundtrip validate-only should report validation success"

$roundtripWithoutProject = Invoke-Script $roundtripScript @("-ValidateOnly")
Assert-True ($roundtripWithoutProject.ExitCode -ne 0) "roundtrip script should require explicit LIQUIDATION project id"
Assert-Contains $roundtripWithoutProject.Output "InfisicalProjectId is required" "roundtrip script should explain missing project id"

Write-Output "freedeepseek auth script tests passed"
