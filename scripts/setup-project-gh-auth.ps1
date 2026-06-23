$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$env:GH_CONFIG_DIR = Join-Path $repoRoot ".cache\gh-cli"
New-Item -ItemType Directory -Force -Path $env:GH_CONFIG_DIR | Out-Null

Set-Location $repoRoot

Write-Host "Project GH_CONFIG_DIR: $env:GH_CONFIG_DIR"
Write-Host "Use a GitHub token for Cryptotehnolog/LIQUIDATION."
Write-Host "Required scopes for a classic PAT: repo, workflow, read:org, gist."
Write-Host "The token will be stored only under ignored .cache/gh-cli for this repository."

$secureToken = Read-Host "Paste GitHub token (hidden input)" -AsSecureString
$bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureToken)

try {
    $plainToken = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    if ([string]::IsNullOrWhiteSpace($plainToken)) {
        throw "Token is empty."
    }

    $env:GH_TOKEN = $plainToken
    $login = (& gh api user --jq ".login").Trim()
    if ([string]::IsNullOrWhiteSpace($login)) {
        throw "GitHub login is empty after token validation."
    }

    $hostsPath = Join-Path $env:GH_CONFIG_DIR "hosts.yml"
    $hostsContent = @"
github.com:
    oauth_token: $plainToken
    git_protocol: https
    users:
        ${login}:
    user: $login
"@
    Set-Content -LiteralPath $hostsPath -Value $hostsContent -Encoding UTF8
    Remove-Item Env:\GH_TOKEN -ErrorAction SilentlyContinue

    gh auth status
    gh api user --jq ".login"
    gh repo view Cryptotehnolog/LIQUIDATION --json nameWithOwner,visibility,url
}
finally {
    Remove-Item Env:\GH_TOKEN -ErrorAction SilentlyContinue
    if ($bstr -ne [IntPtr]::Zero) {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
    Remove-Variable plainToken -ErrorAction SilentlyContinue
    Remove-Variable secureToken -ErrorAction SilentlyContinue
}
