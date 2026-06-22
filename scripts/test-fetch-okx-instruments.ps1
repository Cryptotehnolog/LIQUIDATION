param()

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

$scriptPath = Join-Path $repoRoot "scripts\fetch-okx-instruments.ps1"
$tempDir = Join-Path ([IO.Path]::GetTempPath()) ("liq-okx-fetch-test-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $tempDir *> $null

try {
    $validInput = Join-Path $tempDir "valid.json"
    $validOutput = Join-Path $tempDir "okx-instruments.json"
    @'
{
  "code": "0",
  "msg": "",
  "data": [
    {
      "instType": "SWAP",
      "instId": "BTC-USDT-SWAP",
      "ctVal": "0.01",
      "ctValCcy": "BTC"
    }
  ]
}
'@ | Set-Content -LiteralPath $validInput -Encoding UTF8

    & $scriptPath -Symbol "BTC-USDT-SWAP" -InputPath $validInput -OutputPath $validOutput
    if (-not (Test-Path -LiteralPath $validOutput)) {
        throw "validated OKX instruments JSON was not written"
    }
    $validBytes = [IO.File]::ReadAllBytes($validOutput)
    if ($validBytes.Length -ge 3 -and $validBytes[0] -eq 0xEF -and $validBytes[1] -eq 0xBB -and $validBytes[2] -eq 0xBF) {
        throw "validated OKX instruments JSON must be UTF-8 without BOM"
    }
    $validSaved = Get-Content -Raw -LiteralPath $validOutput | ConvertFrom-Json
    if ($validSaved.data[0].instId -ne "BTC-USDT-SWAP") {
        throw "validated output must preserve requested instrument"
    }
    if ($validSaved.data[0].ctVal -ne "0.01" -or $validSaved.data[0].ctValCcy -ne "BTC") {
        throw "validated output must preserve contract value metadata"
    }

    $invalidInput = Join-Path $tempDir "invalid.json"
    $invalidOutput = Join-Path $tempDir "invalid-output.json"
    @'
{
  "code": "0",
  "msg": "",
  "data": [
    {
      "instType": "SWAP",
      "instId": "BTC-USDT-SWAP",
      "ctValCcy": "BTC"
    }
  ]
}
'@ | Set-Content -LiteralPath $invalidInput -Encoding UTF8

    $failed = $false
    try {
        & $scriptPath -Symbol "BTC-USDT-SWAP" -InputPath $invalidInput -OutputPath $invalidOutput
    } catch {
        $failed = $true
    }
    if (-not $failed) {
        throw "missing ctVal must fail validation"
    }
    if (Test-Path -LiteralPath $invalidOutput) {
        throw "invalid OKX instruments JSON must not be written"
    }

    Write-Host "fetch OKX instruments test ok"
} finally {
    if (Test-Path -LiteralPath $tempDir) {
        Remove-Item -LiteralPath $tempDir -Recurse -Force
    }
}
