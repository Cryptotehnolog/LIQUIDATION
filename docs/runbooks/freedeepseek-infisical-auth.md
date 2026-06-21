# FreeDeepseek Auth Через Infisical

## Назначение

Этот runbook описывает безопасный способ подготовить `deepseek-auth.json` для `liquidation-free-deepseek`, не коммитя secrets в Git и не переиспользуя containers, networks, volumes или auth files второго проекта.

## Важное Ограничение

FreeDeepseek является primary completion route для ApeRAG:

```text
ApeRAG completion -> liquidation-free-deepseek
```

Embeddings закрывает отдельный локальный сервис:

```text
ApeRAG embeddings -> liquidation-embedding
```

Не запускать `liquidation-free-deepseek` без auth file. Без `deepseek-auth.json` сервис либо открывает interactive menu, либо завершает процесс в non-interactive режиме.

## Что Нельзя Делать

- Не копировать auth files из второго проекта.
- Не использовать `deepseek-auth.json`, browser session, cookies или exports второго проекта даже временно.
- Не подключать `liquidation-free-deepseek` к Docker networks второго проекта.
- Не коммитить `deepseek-auth.json`, browser cookies, Infisical exports или `.env`.
- Не запускать `docker compose up -d`, пока auth file не создан и не проверен.

## Исправление От 2026-06-19

Ранее был выполнен временный local bootstrap через read-only copy auth file второго проекта. Это было неправильное решение: оно нарушает границу между проектами и может создать скрытую зависимость от чужой session.

Корректирующее действие:

- `liquidation-free-deepseek` остановлен.
- Локальная копия `infra/aperag/data/secrets/deepseek-auth.json` удалена из проекта LIQUIDATION.
- `scripts/bootstrap-freedeepseek-auth.ps1` больше не поддерживает чтение auth из произвольного source file.
- Единственный разрешённый путь bootstrap: LIQUIDATION-owned secret `FREE_DEEPSEEK_AUTH_JSON` из Infisical.

## Secret Layout

Рекомендуемый secret в Infisical:

```text
Project: LIQUIDATION
Environment: dev
Secret name: FREE_DEEPSEEK_AUTH_JSON
Secret value: полный JSON deepseek-auth.json
```

Локальный ignored путь:

```text
infra/aperag/data/secrets/deepseek-auth.json
```

Этот путь должен совпадать с `FREE_DEEPSEEK_AUTH_FILE` в ignored `infra/aperag/.env`.

## Bootstrap

### Автоматический Refresh Auth

Для создания или обновления собственного LIQUIDATION auth используйте:

```powershell
.\scripts\create-freedeepseek-auth.ps1
```

Скрипт:

- пишет auth только в `infra/aperag/data/secrets/deepseek-auth.json`;
- использует Chrome profile только в `infra/aperag/data/chrome-profiles/freedeepseek-liq`;
- блокирует paths вне `infra/aperag/data`;
- запускает `npm run doctor -- --offline`;
- нормализует JSON в UTF-8 без BOM.

Если нужно проверить уже созданный auth без открытия браузера:

```powershell
.\scripts\create-freedeepseek-auth.ps1 -SkipInteractive
```

Если `liquidation-free-deepseek` уже запущен и нужен live smoke test:

```powershell
.\scripts\create-freedeepseek-auth.ps1 -SkipInteractive -SmokeTest
```

### Publish В Infisical

Публикация в Infisical разрешена только с explicit LIQUIDATION project id:

```powershell
.\scripts\publish-freedeepseek-auth-to-infisical.ps1 `
  -InfisicalProjectId "<LIQUIDATION_PROJECT_ID>"
```

Dry-run без записи:

```powershell
.\scripts\publish-freedeepseek-auth-to-infisical.ps1 `
  -InfisicalProjectId "<LIQUIDATION_PROJECT_ID>" `
  -DryRun
```

Почему project id обязателен: CLI context может указывать на второй проект. Скрипт специально отказывается публиковать secret без `-InfisicalProjectId`, чтобы исключить accidental write в чужой Infisical project.

Секрет не передаётся в command line как JSON. Скрипт использует Infisical file reference syntax:

```text
FREE_DEEPSEEK_AUTH_JSON=@infra/aperag/data/secrets/deepseek-auth.json
```

Это снижает риск утечки через process list или shell history.

### Roundtrip Verification

После публикации обязательно проверить, что secret читается обратно и остаётся валидным FreeDeepseek auth:

```powershell
.\scripts\verify-infisical-roundtrip.ps1 `
  -InfisicalProjectId "<LIQUIDATION_PROJECT_ID>" `
  -InfisicalDomain "http://127.0.0.1:8080"
```

Скрипт:

- читает `FREE_DEEPSEEK_AUTH_JSON` из Infisical;
- пишет его во временный ignored файл `infra/aperag/data/secrets/roundtrip-check/deepseek-auth.json`;
- запускает `npm run doctor -- --offline`;
- удаляет временный auth и temp env после проверки.

### Bootstrap Из Infisical В Local File

1. Убедиться, что локальный `.env` не tracked:

```powershell
git check-ignore -v infra/aperag/.env
```

2. Проверить target path:

```powershell
.\scripts\bootstrap-freedeepseek-auth.ps1 -ValidateOnly
```

3. Создать локальную директорию для secrets:

```powershell
New-Item -ItemType Directory -Force -Path infra/aperag/data/secrets | Out-Null
```

4. Получить secret из Infisical и записать его в ignored файл.

Bootstrap всегда требует explicit LIQUIDATION project id. Не полагаться на
локальный `infisical init` context: он может указывать на второй проект.

Если используется browser login:

```powershell
.\scripts\bootstrap-freedeepseek-auth.ps1 `
  -InfisicalProjectId "<LIQUIDATION_PROJECT_ID>"
```

Если используется machine identity или service token, не передавать token через
CLI argument. Сначала установить переменную окружения только для текущей
PowerShell-сессии:

```powershell
$env:INFISICAL_TOKEN = "<MACHINE_IDENTITY_OR_SERVICE_TOKEN>"
.\scripts\bootstrap-freedeepseek-auth.ps1 `
  -InfisicalProjectId "<LIQUIDATION_PROJECT_ID>"
Remove-Item Env:\INFISICAL_TOKEN
```

Если CLI возвращает quoted string или escaped JSON, сначала проверить файл вручную:

```powershell
Get-Content -Raw infra/aperag/data/secrets/deepseek-auth.json | ConvertFrom-Json | Out-Null
```

`scripts/bootstrap-freedeepseek-auth.ps1` записывает JSON как UTF-8 без BOM. Это важно: Node `JSON.parse` падает, если файл начинается с BOM.

5. Проверить, что файл ignored:

```powershell
git check-ignore -v infra/aperag/data/secrets/deepseek-auth.json
```

## Start FreeDeepseek

Запускать FreeDeepseek только после успешной проверки JSON:

```powershell
.\scripts\check-images.ps1 -EnvFile infra/aperag/.env
.\scripts\guard-compose.ps1 -EnvFile infra/aperag/.env
docker compose --env-file infra/aperag/.env -f infra/aperag/compose.yml -p liquidation up -d liquidation-free-deepseek
```

Проверить:

```powershell
Invoke-WebRequest http://127.0.0.1:19655/health -UseBasicParsing
Invoke-WebRequest http://127.0.0.1:19655/v1/models -UseBasicParsing
```

## Stop FreeDeepseek

```powershell
docker compose --env-file infra/aperag/.env -f infra/aperag/compose.yml -p liquidation stop liquidation-free-deepseek
```

## Rotation

Если DeepSeek отвечает `401`, `403`, просит новый session или PoW:

1. Обновить login через штатный FreeDeepseek flow на локальной машине с браузером.
2. Обновить `FREE_DEEPSEEK_AUTH_JSON` в Infisical.
3. Пересоздать локальный ignored `deepseek-auth.json`.
4. Перезапустить только `liquidation-free-deepseek`.

## Health Semantics

- `ok`: ApeRAG доступен, FreeDeepseek completion отвечает, `liquidation-embedding` отвечает.
- `degraded-but-usable`: ApeRAG и FreeDeepseek отвечают, но embeddings недоступны; ingest/index запрещён.
- `failed`: ApeRAG или FreeDeepseek completion недоступны.

`liq-aperag health` дополнительно пишет `routing_status`, чтобы отличать
проблемы самого ApeRAG от проблем LLM routing.

## Что Улучшить Или Автоматизировать

- Добавить проверку JSON schema для `deepseek-auth.json`.
- Добавить dashboard tile для FreeDeepseek route status.
