# Codex Network Runbook

Цель: включить GitHub/network access для Codex, не меняя GitHub credentials и
не ломая другие проекты.

## Настройка в Codex

Путь в UI:

1. `Настройки`.
2. `Конфигурация`.
3. `Настройки песочницы`.
4. Выбрать `Запись в рабочую область`.
5. Включить `Разрешить доступ к сети`.
6. Перезапустить Codex или открыть новую сессию.

Сеть может не примениться к уже запущенной сессии. После изменения permissions
нужен restart.

## Проверка после перезапуска

В Codex terminal:

```powershell
cd D:\Liquidation\LIQUIDATION
gh repo view Cryptotehnolog/LIQUIDATION
git ls-remote origin HEAD
git status --short
git branch -vv
```

Ожидаемо:

- `gh repo view` возвращает репозиторий;
- `git ls-remote origin HEAD` возвращает commit hash;
- `main` отслеживает `origin/main`.

## Если gh работает в PowerShell, но не в Codex

Проверить в обычном PowerShell:

```powershell
gh auth status
gh repo view Cryptotehnolog/LIQUIDATION
Test-NetConnection github.com -Port 443
```

Если обычный PowerShell работает, а Codex нет, проблема в permissions текущей
Codex-сессии, а не в token.

## Что не делать

```powershell
gh auth logout
git credential-manager erase
git config --global --unset credential.helper
```

Эти команды могут повлиять на другие проекты.

## Безопасное восстановление Git credentials

Если `gh auth status` работает, но Git не пушит:

```powershell
gh auth setup-git
git ls-remote origin HEAD
```

Это безопаснее, чем logout/login, потому что не удаляет существующие
credentials.

Для project-scoped доступа Codex в этом репозитории используйте:

```powershell
cd D:\Liquidation\LIQUIDATION
.\scripts\gh-project.ps1 auth status
.\scripts\gh-project.ps1 repo view Cryptotehnolog/LIQUIDATION
```

`gh auth setup-git` не нужен для обычных GitHub API operations через
`gh-project.ps1`.
