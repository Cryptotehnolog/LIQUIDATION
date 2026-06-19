# FreeDeepseek Auth Через Infisical

## Назначение

Этот runbook описывает безопасный способ подготовить `deepseek-auth.json` для `liquidation-free-deepseek`, не коммитя secrets в Git и не переиспользуя containers второго проекта.

## Важное Ограничение

FreeDeepseek не является primary route. Primary route:

```text
LightRAG -> liquidation-omniroute -> Kiro combo
```

FreeDeepseek используется только как fallback:

```text
liq-rag / LightRAG -> liquidation-free-deepseek напрямую
```

Не запускать `liquidation-free-deepseek` без auth file. Без `deepseek-auth.json` сервис либо открывает interactive menu, либо завершает процесс в non-interactive режиме.

## Что Нельзя Делать

- Не копировать auth files из второго проекта.
- Не подключать `liquidation-free-deepseek` к Docker networks второго проекта.
- Не коммитить `deepseek-auth.json`, browser cookies, Infisical exports или `.env`.
- Не запускать `docker compose --profile fallback up -d`, пока auth file не создан и не проверен.

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
infra/lightrag/data/secrets/deepseek-auth.json
```

Этот путь должен совпадать с `FREE_DEEPSEEK_AUTH_FILE` в ignored `infra/lightrag/.env`.

## Bootstrap

1. Убедиться, что локальный `.env` не tracked:

```powershell
git check-ignore -v infra/lightrag/.env
```

2. Создать локальную директорию для secrets:

```powershell
New-Item -ItemType Directory -Force -Path infra/lightrag/data/secrets | Out-Null
```

3. Получить secret из Infisical и записать его в ignored файл.

Пример команды зависит от выбранного Infisical CLI/profile. Безопасный шаблон:

```powershell
$authJson = infisical secrets get FREE_DEEPSEEK_AUTH_JSON --plain
$authJson | Set-Content -Encoding UTF8 infra/lightrag/data/secrets/deepseek-auth.json
```

Если CLI возвращает quoted string или escaped JSON, сначала проверить файл вручную:

```powershell
Get-Content -Raw infra/lightrag/data/secrets/deepseek-auth.json | ConvertFrom-Json | Out-Null
```

4. Проверить, что файл ignored:

```powershell
git check-ignore -v infra/lightrag/data/secrets/deepseek-auth.json
```

## Start Fallback

Запускать fallback только после успешной проверки JSON:

```powershell
.\scripts\check-images.ps1 -EnvFile infra/lightrag/.env
.\scripts\guard-compose.ps1 -EnvFile infra/lightrag/.env
docker compose --env-file infra/lightrag/.env -f infra/lightrag/compose.yml -p liquidation --profile fallback up -d liquidation-free-deepseek
```

Проверить:

```powershell
Invoke-WebRequest http://127.0.0.1:19655/health -UseBasicParsing
Invoke-WebRequest http://127.0.0.1:19655/v1/models -UseBasicParsing
```

## Stop Fallback

```powershell
docker compose --env-file infra/lightrag/.env -f infra/lightrag/compose.yml -p liquidation stop liquidation-free-deepseek
```

## Rotation

Если DeepSeek отвечает `401`, `403`, просит новый session или PoW:

1. Обновить login через штатный FreeDeepseek flow на локальной машине с браузером.
2. Обновить `FREE_DEEPSEEK_AUTH_JSON` в Infisical.
3. Пересоздать локальный ignored `deepseek-auth.json`.
4. Перезапустить только `liquidation-free-deepseek`.

## Health Semantics

- `ok`: LightRAG доступен, Omniroute доступен, configured LLM model присутствует в `/v1/models`.
- `degraded-but-usable`: LightRAG доступен, primary route не готов, FreeDeepseek fallback отвечает.
- `failed`: LightRAG недоступен или нет usable LLM route.

## Что Улучшить Или Автоматизировать

- Добавить `scripts/bootstrap-freedeepseek-auth.ps1`, когда будет выбран точный Infisical CLI profile.
- Добавить проверку JSON schema для `deepseek-auth.json`.
- Добавить dashboard tile для fallback route status.
