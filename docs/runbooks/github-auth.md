# GitHub Auth Safety Runbook

Цель: безопасно проверить и восстановить работу GitHub CLI/Git для репозитория
`Cryptotehnolog/LIQUIDATION`, не ломая авторизацию и рабочие процессы других
проектов.

## Главное правило

Не выполнять `gh auth logout`, не удалять credentials и не менять глобальные
настройки Git без отдельного решения. Другие проекты могут использовать тот же
Git Credential Manager, keyring или GitHub CLI account.

## Безопасная проверка

В обычном PowerShell:

```powershell
gh auth status
```

Ожидаемый результат:

- account: `Cryptotehnolog`;
- active account: `true`;
- protocol: `https`;
- token scopes включают `repo` и `workflow`.

Проверить доступ к репозиторию:

```powershell
gh repo view Cryptotehnolog/LIQUIDATION
```

Проверить сетевой доступ к GitHub:

```powershell
Test-NetConnection github.com -Port 443
```

`TcpTestSucceeded` должен быть `True`.

## Настройка Git через gh

Если `gh auth status` работает, но `git ls-remote` или `git push` не работают,
безопасный первый шаг:

```powershell
gh auth setup-git
```

Эта команда настраивает Git использовать GitHub CLI credentials для GitHub. Она
не требует logout и не должна ломать второй проект.

## Проверка этого репозитория

Всегда выполнять Git-команды из папки проекта:

```powershell
cd D:\Liquidation\LIQUIDATION
git remote -v
git ls-remote origin HEAD
```

Remote должен указывать на:

```text
https://github.com/Cryptotehnolog/LIQUIDATION.git
```

## Push

Перед push проверить локальное состояние:

```powershell
git status --short
git branch -vv
git log --oneline -5
```

Затем:

```powershell
git push origin main
```

После push:

```powershell
git status --short
git branch -vv
```

Рабочее дерево должно быть чистым, а `main` должен отслеживать `origin/main`.

## Что не делать без отдельного решения

```powershell
gh auth logout
git credential-manager erase
git config --global --unset credential.helper
git config --global --unset-all credential.helper
git config --global --unset-all http.proxy
git config --global --unset-all https.proxy
```

Эти команды могут повлиять на другие проекты.

## Если Codex не видит GitHub

Иногда Codex-среда может иметь ограниченный network access, хотя обычный
PowerShell работает. В таком случае:

1. Проверить `gh auth status` и `gh repo view` в обычном PowerShell.
2. Выполнить `git push origin main` из обычного PowerShell.
3. Не делать вывод, что token сломан, пока обычный PowerShell не проверен.

Codex может продолжать делать локальные изменения и коммиты, а сетевые GitHub
операции выполнять через обычный PowerShell.
