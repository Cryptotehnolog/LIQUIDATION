# ApeRAG Operations Runbook

## Цель

Этот runbook описывает operational model для ApeRAG Dev Memory в проекте
`LIQUIDATION`: запуск, provider routing, health check, backup, restore и
правила обновления индекса.

Repository docs остаются source of truth. ApeRAG является производным
retrieval/index слоем и должен доказывать свежесть через metadata и eval.

## Финальная Схема

Основной путь:

```text
ApeRAG completion -> liquidation-free-deepseek
ApeRAG embeddings -> liquidation-embedding
```

`liquidation-free-deepseek` является project-owned completion route. Он не должен
переиспользовать auth, containers, networks, volumes или browser profile второго
проекта.

## Docker Isolation

Разрешённый prefix для этого проекта:

```text
liquidation-
```

Не трогать контейнеры второго проекта:

- `omniroute`;
- `free_qwen`;
- `free_deepseek`;
- `aperag`;
- все `stat-arb-*`.

Запрещены unscoped destructive commands:

```powershell
docker system prune
docker volume prune
docker network prune
docker compose down --remove-orphans
```

Если нужен `down`, он должен быть scoped на compose файл проекта:

```powershell
docker compose --env-file infra/aperag/.env -f infra/aperag/compose.yml -p liquidation down
```

## Environment Variables

В repository хранить только `infra/aperag/.env.example`. Реальный
`infra/aperag/.env`, secrets, Infisical exports и auth files не коммитить.

Ключевые переменные:

```dotenv
APERAG_HOST=127.0.0.1
APERAG_WEB_PORT=23000
APERAG_API_PORT=28000
APERAG_DATA_PATH=./data
APERAG_REPORT_PATH=docs/reports/aperag
APERAG_INDEXED_PATHS=docs/
LIQUIDATION_FREE_DEEPSEEK_PORT=19655
LIQUIDATION_EMBEDDING_PORT=28001
APERAG_PRIMARY_MODEL=deepseek-chat
APERAG_EMBEDDING_MODEL=sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2
```

## Provider Routing

OmniRoute больше не является частью ApeRAG route. Текущая рабочая схема:

- completion: `liquidation-free-deepseek`, model `deepseek-chat`;
- embeddings: `liquidation-embedding`, model
  `sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2`.

Текущая проверенная модель для ApeRAG completion:

```dotenv
APERAG_PRIMARY_MODEL=deepseek-chat
APERAG_FALLBACK_MODEL=deepseek-chat
```

После `docker compose up -d` выполнить:

```powershell
.\scripts\setup-aperag-routing.ps1 -EnvFile infra/aperag/.env
```

Скрипт создаёт локального ApeRAG admin-пользователя, сохраняет credentials в
ignored `infra/aperag/data/secrets/aperag-admin.env`, публикует provider'ы
`liquidation-free-deepseek` и `liquidation-embedding`, затем выставляет default
completion и embedding models.

## Embeddings

Embeddings закрывает отдельный локальный OpenAI-compatible сервис:

```text
http://127.0.0.1:28001/v1/embeddings
```

Модель:

```text
sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2
```

Ожидаемый размер вектора: `384`.

## Health Statuses

`scripts/liq-aperag.ps1 health` должен проверять:

- ApeRAG API docs;
- ApeRAG Web UI;
- FreeDeepseek `/v1/models`;
- FreeDeepseek `/v1/chat/completions`;
- embedding service `/v1/models`;
- embedding service `/v1/embeddings`.

- `ok`: ApeRAG API/Web, FreeDeepseek completion и embeddings отвечают.
- `degraded-but-usable`: ApeRAG API/Web и FreeDeepseek отвечают, но embeddings
  недоступны; ingest/index запрещён.
- `failed`: ApeRAG API/Web или FreeDeepseek completion недоступны.

Дополнительный `memory_status`:

- `ready-for-ingest`: completion и embeddings готовы;
- `completion-only-no-embedding`: chat route работает, но индексировать docs ещё
  нельзя.

## Ingest

Ingest выполняется только через project-owned CLI:

```powershell
.\scripts\liq-aperag.ps1 ingest docs/ -EnvFile infra/aperag/.env
```

Команда:

- проверяет `health`;
- создаёт или обновляет collection `LIQUIDATION Dev Memory`;
- делает full refresh документов внутри этой collection;
- загружает tracked и untracked non-ignored `.md` и `.txt` из `docs/`;
- ждёт `COMPLETE` document status и `ACTIVE` vector/fulltext indexes;
- пишет ignored metadata в `docs/reports/aperag/index-metadata.json`.

JSON-файлы, включая `docs/research/status.json`, `docs/research/plans/**` и
generated `docs/reports/aperag/*.json`, не индексируются в default Dev Memory
collection. Raw research notes и query plans могут жить в repository как audit
trail, но default retrieval должен опираться на curated `.md`/`.txt` docs.

Markdown audit reports в `docs/reports/aperag/` индексируются, потому что это
человеческие operational notes, а не generated runtime metadata.

## Eval

Retrieval quality проверяется командой:

```powershell
.\scripts\liq-aperag.ps1 eval -EnvFile infra/aperag/.env
```

Eval dataset:

```text
docs/reports/aperag/eval-questions.json
```

Обязательные проверки включают:

- текущую provider route;
- Docker isolation;
- русский UTF-8 retrieval;
- paper-only trading;
- комиссии Polymarket/Hyperliquid;
- archive verification.

Eval является top-5 retrieval gate. Каждый case может указывать
`expected_source`, а обязательные terms должны находиться в одном найденном
result/chunk. Eval не передаёт expected terms как search keywords, чтобы не
подсказывать поиску правильный ответ.

PowerShell 5.1 нельзя использовать для чтения ApeRAG JSON через
`Invoke-RestMethod`: он может неверно декодировать UTF-8 response без charset.
`liq-aperag.ps1` читает `RawContentStream` и декодирует bytes через
`UTF8.GetString`.

## Known ApeRAG Status Drift

В ApeRAG возможен рассинхрон между persisted `document.status` и фактическим
состоянием индексов:

- `document.status` может оставаться `RUNNING`;
- при этом `VECTOR` и `FULLTEXT` уже находятся в `ACTIVE`;
- runtime method `Document.get_overall_index_status()` для такого документа
  может вычислять `COMPLETE`.

Для `LIQUIDATION` это означает:

- использовать project-owned patched ApeRAG image `liquidation-aperag:local`;
- patch применяется на build-time к `aperag/tasks/reconciler.py`;
- patch сериализует callback updates для одного `document_id` через PostgreSQL
  advisory transaction lock;
- `ingest` должен ждать настоящий `document.status = COMPLETE`;
- `status -CheckDrift` остаётся guard-проверкой и должен возвращать `ok`;
- не исправлять drift post-factum через ручные DB updates.

Подробный аудит: `docs/reports/aperag/implementation-audit.md`.

## Archive Verification Anchor

Для Parquet archive verification обязательны checksum validation, readback
проверка, row count, timestamp bounds, column statistics и
`parquet_schema_version`. Canonical deletion разрешён только после verified
archive и установленного `canonical_deletion_watermark`.

## Freshness

Проверка свежести:

```powershell
.\scripts\liq-aperag.ps1 status docs/ -EnvFile infra/aperag/.env -CheckCommit
```

`-CheckCommit` должен падать, если:

- metadata отсутствует;
- Git commit в metadata не совпадает с текущим `HEAD`;
- hash индексируемых docs не совпадает с metadata.

Проверка drift-статусов ApeRAG:

```powershell
.\scripts\liq-aperag.ps1 status docs/ -EnvFile infra/aperag/.env -CheckCommit -CheckDrift
```

`document_status_drift.status`:

- `ok`: persisted document statuses и обязательные индексы согласованы;
- `warning`: status drift обнаружен. Это не считается нормальным состоянием и
  требует root-cause audit;
- `failed`: есть terminal status (`FAILED`, `DELETED`, `EXPIRED`) или
  обязательный индекс не готов.

`warning` и `failed` блокируют acceptance текущего RAG-контура.

## Acceptance Checks

Минимальные локальные проверки:

```powershell
.\scripts\guard-compose.ps1 -EnvFile infra/aperag/.env.example
.\scripts\check-images.ps1 -EnvFile infra/aperag/.env.example
.\scripts\test-aperag-dev-memory.ps1
.\scripts\audit-aperag.ps1
.\scripts\liq-aperag.ps1 health -EnvFile infra/aperag/.env
.\scripts\setup-aperag-routing.ps1 -EnvFile infra/aperag/.env
.\scripts\liq-aperag.ps1 ingest docs/ -EnvFile infra/aperag/.env
.\scripts\liq-aperag.ps1 eval -EnvFile infra/aperag/.env
.\scripts\liq-aperag.ps1 status docs/ -EnvFile infra/aperag/.env -CheckCommit -CheckDrift
```

`check-images.ps1` по умолчанию не блокирует локальный аудит, если Docker Hub
вернул pull-rate-limit; в этом случае он пишет warning и продолжает проверку
остальных источников. Для строгой проверки перед deployment использовать:

```powershell
.\scripts\check-images.ps1 -EnvFile infra/aperag/.env.example -StrictRemoteManifests
```

## Что Улучшить Или Автоматизировать

- Добавить dashboard panel: ApeRAG status, collection freshness, eval score,
  active provider path.
- Добавить scheduled report в `docs/reports/aperag/`.
