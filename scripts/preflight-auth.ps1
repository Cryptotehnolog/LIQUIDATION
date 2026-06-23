param(
    [string]$Repo = "Cryptotehnolog/LIQUIDATION",
    [string]$EnvFile = "infra/aperag/.env",
    [string]$InfisicalProjectId = "",
    [string]$InfisicalDomain = "http://127.0.0.1:8080",
    [string]$InfisicalEnvironment = "dev",
    [string]$InfisicalPath = "/",
    [string]$InfisicalSecretName = "FREE_DEEPSEEK_AUTH_JSON",
    [switch]$CheckInfisicalSecret,
    [switch]$Json
)

$ErrorActionPreference = "Stop"

function Invoke-Captured {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    $processInfo = [System.Diagnostics.ProcessStartInfo]::new()
    if ($FilePath -match '\.(cmd|bat)$') {
        $processInfo.FileName = $env:ComSpec
        $processInfo.Arguments = "/d /c call " + (Quote-CmdArg $FilePath) + " " + (Join-CmdArgs $Arguments)
    } else {
        $processInfo.FileName = $FilePath
        $processInfo.Arguments = Join-NativeArgs $Arguments
    }
    $processInfo.RedirectStandardOutput = $true
    $processInfo.RedirectStandardError = $true
    $processInfo.UseShellExecute = $false

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $processInfo
    $process.Start() | Out-Null
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()

    [pscustomobject]@{
        exit_code = $process.ExitCode
        stdout = ($stdout | Out-String).Trim()
        stderr = ($stderr | Out-String).Trim()
    }
}

function Join-NativeArgs {
    param([Parameter(Mandatory = $true)][string[]]$Items)

    return (($Items | ForEach-Object {
        if ($_ -match '[\s"]') {
            '"' + $_.Replace('\', '\\').Replace('"', '\"') + '"'
        } else {
            $_
        }
    }) -join " ")
}

function Join-CmdArgs {
    param([Parameter(Mandatory = $true)][string[]]$Items)

    return (($Items | ForEach-Object {
        if ($_ -match '[\s&()^|<>"]') {
            '"' + $_.Replace('"', '""') + '"'
        } else {
            $_
        }
    }) -join " ")
}

function Quote-CmdArg {
    param([Parameter(Mandatory = $true)][string]$Item)

    return '"' + $Item.Replace('"', '""') + '"'
}

function New-Check {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][ValidateSet("ok", "warn", "fail", "skip")][string]$Status,
        [Parameter(Mandatory = $true)][string]$Message,
        [string]$Details = ""
    )

    [ordered]@{
        name = $Name
        status = $Status
        message = $Message
        details = $Details
    }
}

function Find-CommandPath {
    param([Parameter(Mandatory = $true)][string[]]$Names)

    foreach ($name in $Names) {
        $command = Get-Command $name -ErrorAction SilentlyContinue
        if ($command) {
            return $command.Source
        }
    }

    return $null
}

function Read-DotEnv {
    param([Parameter(Mandatory = $true)][string]$Path)

    $values = @{}
    if (-not (Test-Path $Path)) {
        return $values
    }

    foreach ($line in Get-Content $Path) {
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
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$Default = ""
    )

    if ($Values.ContainsKey($Name) -and -not [string]::IsNullOrWhiteSpace($Values[$Name])) {
        return $Values[$Name]
    }

    return $Default
}

function Redact-Output {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return ""
    }

    $redacted = $Text -replace 'gho_[A-Za-z0-9_]+', 'gho_***'
    $redacted = $redacted -replace '(?i)(token|secret|password|cookie)\s*[:=]\s*\S+', '$1=***'
    return $redacted.Trim()
}

$checks = New-Object System.Collections.Generic.List[object]
$envValues = Read-DotEnv $EnvFile
$authFile = Get-EnvValue $envValues "FREE_DEEPSEEK_AUTH_FILE" "./data/secrets/deepseek-auth.json"
if (-not [System.IO.Path]::IsPathRooted($authFile)) {
    $authFile = Join-Path "infra/aperag" $authFile
}

$gitPath = Find-CommandPath @("git")
if (-not $gitPath) {
    $checks.Add((New-Check "git_executable" "fail" "git не найден в PATH текущей Codex-среды"))
} else {
    $checks.Add((New-Check "git_executable" "ok" "git найден" $gitPath))

    $remote = Invoke-Captured $gitPath @("remote", "get-url", "origin")
    if ($remote.exit_code -eq 0) {
        $checks.Add((New-Check "git_remote_origin" "ok" "origin доступен" (Redact-Output $remote.stdout)))
    } else {
        $checks.Add((New-Check "git_remote_origin" "fail" "origin не прочитан" (Redact-Output ($remote.stderr + "`n" + $remote.stdout))))
    }

    $lsRemote = Invoke-Captured $gitPath @("ls-remote", "origin", "HEAD")
    if ($lsRemote.exit_code -eq 0) {
        $checks.Add((New-Check "git_remote_head" "ok" "git может читать origin HEAD" (Redact-Output $lsRemote.stdout)))
    } else {
        $fallback = Invoke-Captured $gitPath @("-c", "http.sslBackend=openssl", "ls-remote", "origin", "HEAD")
        if ($fallback.exit_code -eq 0) {
            $checks.Add((New-Check "git_remote_head" "warn" "git origin HEAD работает только с http.sslBackend=openssl в этой среде" (Redact-Output $fallback.stdout)))
        } else {
            $details = "default: $($lsRemote.stderr)`nopenssl: $($fallback.stderr)"
            $checks.Add((New-Check "git_remote_head" "fail" "git не смог прочитать origin HEAD" (Redact-Output $details)))
        }
    }
}

$ghPath = Find-CommandPath @("gh", "gh.exe")
if (-not $ghPath) {
    $checks.Add((New-Check "gh_executable" "fail" "GitHub CLI не найден в PATH текущей Codex-среды"))
} else {
    $checks.Add((New-Check "gh_executable" "ok" "GitHub CLI найден" $ghPath))

    $projectGhPath = Join-Path "scripts" "gh-project.ps1"
    if (Test-Path $projectGhPath) {
        $projectGhUser = Invoke-Captured "powershell" @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $projectGhPath, "api", "user", "--jq", ".login")
        if ($projectGhUser.exit_code -eq 0) {
            $checks.Add((New-Check "gh_project_api_user" "ok" "project-local GitHub API token работает" (Redact-Output $projectGhUser.stdout)))
        } else {
            $checks.Add((New-Check "gh_project_api_user" "warn" "project-local GitHub API token не работает; запустите scripts/setup-project-gh-auth.ps1" (Redact-Output ($projectGhUser.stdout + "`n" + $projectGhUser.stderr))))
        }

        $projectGhRepo = Invoke-Captured "powershell" @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $projectGhPath, "repo", "view", $Repo, "--json", "nameWithOwner,visibility,url")
        if ($projectGhRepo.exit_code -eq 0) {
            $checks.Add((New-Check "gh_project_repo_view" "ok" "project-local GitHub API может читать $Repo" (Redact-Output $projectGhRepo.stdout)))
        } else {
            $checks.Add((New-Check "gh_project_repo_view" "warn" "project-local GitHub API не подтвердил доступ к $Repo" (Redact-Output ($projectGhRepo.stdout + "`n" + $projectGhRepo.stderr))))
        }
    } else {
        $checks.Add((New-Check "gh_project_wrapper" "skip" "scripts/gh-project.ps1 не найден"))
    }

    $ghStatus = Invoke-Captured $ghPath @("auth", "status")
    if ($ghStatus.exit_code -eq 0) {
        $checks.Add((New-Check "gh_auth_status" "ok" "gh auth status успешен" (Redact-Output ($ghStatus.stdout + "`n" + $ghStatus.stderr))))
    } else {
        $checks.Add((New-Check "gh_auth_status" "warn" "gh auth status неуспешен в текущей Codex-среде; это не доказывает, что пользовательский GitHub token сломан" (Redact-Output ($ghStatus.stdout + "`n" + $ghStatus.stderr))))
    }

    $ghRepo = Invoke-Captured $ghPath @("repo", "view", $Repo, "--json", "name,url")
    if ($ghRepo.exit_code -eq 0) {
        $checks.Add((New-Check "gh_api_repo_view" "ok" "gh API может читать репозиторий $Repo" (Redact-Output $ghRepo.stdout)))
    } else {
        $checks.Add((New-Check "gh_api_repo_view" "warn" "gh API не подтвердил доступ к $Repo в текущей Codex-среде" (Redact-Output ($ghRepo.stdout + "`n" + $ghRepo.stderr))))
    }
}

$infisicalCommandPath = Find-CommandPath @("infisical.cmd", "infisical", "infisical.exe")
if (-not $infisicalCommandPath) {
    $checks.Add((New-Check "infisical_executable" "warn" "Infisical CLI не найден в PATH текущей Codex-среды"))
} else {
    $checks.Add((New-Check "infisical_executable" "ok" "Infisical CLI найден" $infisicalCommandPath))

    $version = Invoke-Captured $infisicalCommandPath @("--version")
    if ($version.exit_code -eq 0) {
        $checks.Add((New-Check "infisical_version" "ok" "Infisical CLI отвечает" (Redact-Output ($version.stdout + "`n" + $version.stderr))))
    } else {
        $checks.Add((New-Check "infisical_version" "warn" "Infisical CLI найден, но --version завершился ошибкой" (Redact-Output ($version.stdout + "`n" + $version.stderr))))
    }

    if ($CheckInfisicalSecret) {
        if ([string]::IsNullOrWhiteSpace($InfisicalProjectId)) {
            $checks.Add((New-Check "infisical_secret_read" "skip" "Проверка secret пропущена: нужен explicit InfisicalProjectId"))
        } else {
            $infisicalArgs = @(
                "secrets", "get", $InfisicalSecretName,
                "--env=$InfisicalEnvironment",
                "--path=$InfisicalPath",
                "--projectId=$InfisicalProjectId",
                "--plain",
                "--silent"
            )
            if (-not [string]::IsNullOrWhiteSpace($InfisicalDomain)) {
                $infisicalArgs += "--domain=$InfisicalDomain"
            }

            $secretRead = Invoke-Captured -FilePath $infisicalCommandPath -Arguments $infisicalArgs
            if ($secretRead.exit_code -eq 0) {
                $checks.Add((New-Check "infisical_secret_read" "ok" "Secret $InfisicalSecretName читается из explicit LIQUIDATION project id; значение не выводится"))
            } else {
                $checks.Add((New-Check "infisical_secret_read" "warn" "Secret $InfisicalSecretName не прочитан из Infisical" (Redact-Output ($secretRead.stdout + "`n" + $secretRead.stderr))))
            }
        }
    } else {
        $checks.Add((New-Check "infisical_secret_read" "skip" "Secret read не выполнялся; добавьте -CheckInfisicalSecret для явной проверки"))
    }
}

$dockerPath = Find-CommandPath @("docker", "docker.exe")
if (-not $dockerPath) {
    $checks.Add((New-Check "docker_executable" "warn" "Docker CLI не найден в PATH текущей Codex-среды"))
} else {
    $checks.Add((New-Check "docker_executable" "ok" "Docker CLI найден" $dockerPath))
    $dockerVersion = Invoke-Captured $dockerPath @("version", "--format", "{{.Server.Version}}")
    if ($dockerVersion.exit_code -eq 0) {
        $checks.Add((New-Check "docker_daemon" "ok" "Docker daemon доступен из текущей Codex-среды" (Redact-Output $dockerVersion.stdout)))
    } else {
        $checks.Add((New-Check "docker_daemon" "warn" "Docker daemon не доступен без дополнительного разрешения или прав" (Redact-Output ($dockerVersion.stdout + "`n" + $dockerVersion.stderr))))
    }
}

if (Test-Path $authFile) {
    $checks.Add((New-Check "freedeepseek_auth_file" "ok" "FreeDeepseek auth-файл существует; содержимое не выводится" $authFile))
} else {
    $checks.Add((New-Check "freedeepseek_auth_file" "warn" "FreeDeepseek auth-файл не найден в expected ignored path" $authFile))
}

if ($gitPath) {
    $ignore = Invoke-Captured $gitPath @("check-ignore", "-v", $authFile)
    if ($ignore.exit_code -eq 0) {
        $checks.Add((New-Check "freedeepseek_auth_ignored" "ok" "FreeDeepseek auth path ignored Git" (Redact-Output $ignore.stdout)))
    } else {
        $checks.Add((New-Check "freedeepseek_auth_ignored" "fail" "FreeDeepseek auth path не ignored Git" $authFile))
    }
}

$summaryStatus = if (($checks | Where-Object { $_.status -eq "fail" }).Count -gt 0) {
    "fail"
} elseif (($checks | Where-Object { $_.status -eq "warn" }).Count -gt 0) {
    "warn"
} else {
    "ok"
}

$report = [ordered]@{
    generated_at = (Get-Date).ToUniversalTime().ToString("o")
    status = $summaryStatus
    repo = $Repo
    env_file = $EnvFile
    checks = $checks
}

if ($Json) {
    $report | ConvertTo-Json -Depth 8
} else {
    Write-Output "Auth preflight status: $summaryStatus"
    foreach ($check in $checks) {
        Write-Output ("[{0}] {1}: {2}" -f $check.status, $check.name, $check.message)
        if (-not [string]::IsNullOrWhiteSpace($check.details)) {
            Write-Output ("  {0}" -f ($check.details -replace "`r?`n", "`n  "))
        }
    }
}

if ($summaryStatus -eq "fail") {
    exit 1
}
