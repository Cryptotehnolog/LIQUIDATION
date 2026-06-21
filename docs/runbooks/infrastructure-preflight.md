# Infrastructure Preflight Runbook

## Цель

Перед deployment ApeRAG Dev Memory проверить локальную инфраструктуру так,
чтобы не сломать второй проект в Docker.

Preflight read-only по умолчанию. Любое изменение Docker допускается только
после отдельного deployment plan и только для project-owned names с prefix
`liquidation`.

## Scope

Проверяем:

- Docker daemon доступен;
- чужие containers живы;
- занятые ports известны;
- existing FreeDeepseek и embedding route проверены read-only;
- будущие `liquidation-*` names не конфликтуют;
- Git clean;
- Git/GitHub/Infisical auth context понятен;
- secrets не лежат в repo;
- research status актуален.

Не делаем:

- `docker system prune`;
- `docker volume prune`;
- `docker network prune`;
- `docker compose down --remove-orphans`;
- restart чужих containers;
- подключение чужих containers к новым networks;
- изменение Infisical containers второго проекта.

## Команды preflight

### Git

```powershell
git status --short
git branch -vv
```

Ожидаемо: рабочее дерево чистое, branch `main` синхронизирован с `origin/main`.

### Auth Context

```powershell
.\scripts\preflight-auth.ps1
```

Эта команда разделяет разные auth layers, чтобы не путать пользовательскую
среду и текущую Codex-среду:

- `git_remote_head` проверяет Git remote access;
- `gh_auth_status` проверяет GitHub CLI auth именно в текущей Codex-среде;
- `gh_api_repo_view` проверяет GitHub API через `gh`;
- `infisical_executable` проверяет, виден ли Infisical CLI;
- `docker_daemon` проверяет Docker access без изменения контейнеров;
- `freedeepseek_auth_ignored` проверяет, что локальный auth file не попадёт в Git.

Важно: warning по `gh_auth_status` в Codex-среде не означает, что пользовательский
GitHub token сломан. Не запускать `gh auth logout` для диагностики.

Для явной проверки secret в Infisical использовать только explicit
LIQUIDATION project id:

```powershell
.\scripts\preflight-auth.ps1 `
  -InfisicalProjectId "<LIQUIDATION_PROJECT_ID>" `
  -CheckInfisicalSecret
```

### Docker inventory

```powershell
docker ps --format "table {{.Names}}\t{{.Image}}\t{{.Ports}}\t{{.Status}}"
docker network ls --format "table {{.Name}}\t{{.Driver}}\t{{.Scope}}"
docker volume ls --format "table {{.Name}}\t{{.Driver}}"
```

Ожидаемо: чужие containers остаются running/healthy. Project-owned containers
для `LIQUIDATION` должны иметь prefix `liquidation`.

### Ports

```powershell
docker ps --format "{{.Names}} {{.Ports}}"
netstat -ano | findstr LISTENING
```

Запрещено использовать ports, уже занятые вторым проектом:

- `20128`;
- `3264`;
- `9655`;
- `13000`;
- `18000`;
- `15555`;
- `19200`;
- `16379`;
- `15432`;
- `16333`;
- `8080`.

### Project FreeDeepseek proof

```powershell
Invoke-WebRequest "http://127.0.0.1:19655/health" -UseBasicParsing
Invoke-WebRequest "http://127.0.0.1:19655/v1/models" -UseBasicParsing
```

Completion smoke test:

```powershell
$body = @{
  model = "deepseek-chat"
  messages = @(@{ role = "user"; content = "Reply with OK only." })
  max_tokens = 5
  stream = $false
} | ConvertTo-Json -Depth 5

Invoke-WebRequest `
  -Uri "http://127.0.0.1:19655/v1/chat/completions" `
  -Method POST `
  -Headers @{ Authorization = "Bearer test" } `
  -Body $body `
  -ContentType "application/json" `
  -TimeoutSec 60 `
  -UseBasicParsing
```

Это должен быть project-owned container `liquidation-free-deepseek`, не
FreeDeepseek второго проекта.

### Project Embedding proof

```powershell
$body = @{
  model = "sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2"
  input = @("test document")
} | ConvertTo-Json -Depth 5

Invoke-WebRequest "http://127.0.0.1:28001/v1/models" -UseBasicParsing
Invoke-WebRequest `
  -Uri "http://127.0.0.1:28001/v1/embeddings" `
  -Method POST `
  -Body $body `
  -ContentType "application/json" `
  -TimeoutSec 120 `
  -UseBasicParsing
```

Это должен быть project-owned container `liquidation-embedding`.

### Secrets scan

```powershell
git ls-files
rg -n "gho_|ghp_|sk-|api[_-]?key|secret|password|token" .env docs config crates .github
```

Ожидаемо: реальные secrets отсутствуют. `.env.example` может содержать только
имена переменных без значений.

### Research freshness

```powershell
python -m json.tool docs/research/status.json
```

Ожидаемо: JSON валиден, `research_date` не старше decision window для текущего
этапа.

## Preflight report

Перед deployment создать report:

```text
docs/reports/preflight/YYYY-MM-DD-infrastructure.md
```

Минимальное содержимое:

- Git status;
- auth preflight summary;
- Docker containers summary;
- occupied ports;
- chosen `liquidation-*` ports;
- `liquidation-free-deepseek` result;
- `liquidation-embedding` result;
- secrets scan result;
- blockers.

## Blockers

Deployment запрещен, если:

- рабочее дерево dirty без объяснения;
- Docker daemon недоступен;
- чужой container unhealthy после read-only checks;
- выбранный port конфликтует;
- найден secret в repo;
- `docs/research/status.json` невалиден;
- planned container/network/volume name не имеет prefix `liquidation`;
- требуется изменить второй проект для работы `LIQUIDATION`.

## Что улучшить или автоматизировать

- Добавить `scripts/preflight.ps1`.
- Добавить `scripts/preflight-auth.ps1`.
- Добавить JSON output для dashboard.
- Добавить port allocation helper.
- Добавить automatic report generation в `docs/reports/preflight/`.
