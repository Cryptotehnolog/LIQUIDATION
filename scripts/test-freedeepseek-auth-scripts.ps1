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
$bootstrapScript = "scripts/bootstrap-freedeepseek-auth.ps1"
$roundtripScript = "scripts/verify-infisical-roundtrip.ps1"

$createSource = Get-Content -Raw $createScript
Assert-True (-not $createSource.Contains('"FREE_DEEPSEEK_REF" "main"')) "create script must not default FreeDeepseek ref to main"

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

$prefixBypassCreate = Invoke-Script $createScript @(
    "-ValidateOnly",
    "-AuthPath",
    "infra/lightrag/data2/secrets/deepseek-auth.json"
)
Assert-True ($prefixBypassCreate.ExitCode -ne 0) "create script should reject data2 prefix-bypass paths"
Assert-Contains $prefixBypassCreate.Output "outside LIQUIDATION infra/lightrag/data" "create script should explain data2 path scope failure"

$publishWithoutProject = Invoke-Script $publishScript @("-DryRun")
Assert-True ($publishWithoutProject.ExitCode -ne 0) "publish script should require explicit LIQUIDATION project id"
Assert-Contains $publishWithoutProject.Output "InfisicalProjectId is required" "publish script should explain missing project id"

$publishPrefixBypass = Invoke-Script $publishScript @(
    "-InfisicalProjectId",
    "liq-test-project-id",
    "-AuthPath",
    "infra/lightrag/data2/secrets/deepseek-auth.json",
    "-DryRun"
)
Assert-True ($publishPrefixBypass.ExitCode -ne 0) "publish script should reject data2 prefix-bypass paths"
Assert-Contains $publishPrefixBypass.Output "outside LIQUIDATION infra/lightrag/data" "publish script should explain data2 path scope failure"

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
Assert-True (-not $publishSource.Contains('--token=$InfisicalToken')) "publish script must not pass Infisical token through CLI arguments"

$bootstrapSource = Get-Content -Raw -LiteralPath $bootstrapScript
Assert-Contains $bootstrapSource "InfisicalProjectId is required" "bootstrap script should require explicit LIQUIDATION project id"
Assert-True (-not $bootstrapSource.Contains('--token=$InfisicalToken')) "bootstrap script must not pass Infisical token through CLI arguments"

$bootstrapValidate = Invoke-Script $bootstrapScript @("-ValidateOnly")
Assert-True ($bootstrapValidate.ExitCode -eq 0) "bootstrap validate-only should validate local ignored target without Infisical access"
Assert-Contains $bootstrapValidate.Output "auth target is ignored" "bootstrap validate-only should report ignored target"

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

$roundtripPrefixBypass = Invoke-Script $roundtripScript @(
    "-InfisicalProjectId",
    "liq-test-project-id",
    "-RoundtripAuthPath",
    "infra/lightrag/data2/secrets/roundtrip-check/deepseek-auth.json",
    "-ValidateOnly"
)
Assert-True ($roundtripPrefixBypass.ExitCode -ne 0) "roundtrip script should reject data2 prefix-bypass paths"
Assert-Contains $roundtripPrefixBypass.Output "outside LIQUIDATION infra/lightrag/data" "roundtrip script should explain data2 path scope failure"

Write-Output "freedeepseek auth script tests passed"
