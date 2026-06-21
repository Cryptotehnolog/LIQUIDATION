# ApeRAG Implementation Audit

Дата: 2026-06-21

## Цель

Проверить, почему `LIQUIDATION` ApeRAG Dev Memory выглядит нестабильно, и
отделить ошибки нашей интеграции от поведения ApeRAG.

## Проверенные источники

- ApeRAG repository: https://github.com/apecloud/ApeRAG
- `docs/en-US/design/document_upload_design.md` внутри образа
  `liquidation-aperag-api`
- `docs/en-US/design/indexing_architecture.md` внутри образа
  `liquidation-aperag-api`
- Runtime source внутри контейнера:
  - `/app/aperag/service/document_service.py`
  - `/app/aperag/tasks/reconciler.py`
  - `/app/config/celery_tasks.py`
  - `/app/aperag/db/models.py`

## Что подтверждено

1. ApeRAG использует two-phase upload:
   - `POST /api/v1/collections/{collection_id}/documents/upload`
   - `POST /api/v1/collections/{collection_id}/documents/confirm`

2. `confirm_documents()` переводит document из `UPLOADED` в `PENDING`, создаёт
   `DocumentIndex` records и запускает async reconciliation.

3. Для нашей collection включены только обязательные индексы:
   - `VECTOR`
   - `FULLTEXT`

4. По документации ApeRAG readiness должен наступать, когда все index records
   имеют `ACTIVE`. Тогда `Document.status` должен стать `COMPLETE`.

5. Фактическое состояние после ingest:
   - 31 document total;
   - 28 stored as `COMPLETE`;
   - 3 stored as `RUNNING`;
   - у всех 31 документов `VECTOR=ACTIVE` и `FULLTEXT=ACTIVE`;
   - для 3 stuck documents прямой вызов модели даёт:
     `stored=RUNNING`, но `computed=DocumentStatus.COMPLETE`.

## Root Cause

Проблема не в embeddings, не в FreeDeepseek, не в upload, не в UTF-8 и не в
retrieval.

Проблема в рассинхронизации `document.status` и `document_index.status` внутри
ApeRAG lifecycle:

- `document_index` уже показывает готовность (`ACTIVE/ACTIVE`);
- `Document.get_overall_index_status()` вычисляет `COMPLETE`;
- но persisted `document.status` остаётся `RUNNING` у части документов.

Worker logs подтверждают, что workflow для stuck documents завершился успешно:
`Document ... create COMPLETED SUCCESSFULLY! All indexes processed: VECTOR, FULLTEXT`.

## Почему Нужен Source Fix

До source-fix строгий wait на `document.status = COMPLETE` был проверен: после
1200 секунд часть документов оставалась `RUNNING`, хотя оба индекса были
`ACTIVE`.

Поэтому прежняя политика "считать usable по index statuses" была допустимой
только как диагностический этап. Для нормального состояния проекта она
недостаточна: `ingest` должен получать настоящий `document.status = COMPLETE`.

## Текущая правильная политика для LIQUIDATION

Документ считается готовым после ingest, если:

- `document.status = COMPLETE`;
- `vector_index_status` равен `ACTIVE` или `SKIPPED`;
- `fulltext_index_status` равен `ACTIVE` или `SKIPPED`.

`document.status != COMPLETE` при готовых индексах теперь считается drift и
блокирует acceptance.

## Source Fix

Добавлен project-owned patched image:

```text
liquidation-aperag:local
```

Он собирается из upstream base image `APERAG_BASE_IMAGE` и применяет build-time
source patch к:

```text
/app/aperag/tasks/reconciler.py
```

Patch добавляет PostgreSQL advisory transaction lock на `document_id` в
callbacks `on_index_created`, `on_index_failed` и `on_index_deleted`. Это
сериализует обновление `DocumentIndex` и пересчёт `Document.status` для одного
документа, убирая race между параллельными `VECTOR` и `FULLTEXT` callbacks.

## Автоматическая Проверка Drift

Добавлена runtime-проверка:

```powershell
.\scripts\liq-aperag.ps1 status docs/ -EnvFile infra/aperag/.env -CheckCommit -CheckDrift
```

Она возвращает `document_status_drift`:

- `ok`: drift нет;
- `warning`: persisted `document.status` не `COMPLETE`, но обязательные индексы
  `VECTOR/FULLTEXT` готовы. Это означает regression source-fix и блокирует
  acceptance;
- `failed`: документ в terminal bad status или обязательный индекс не готов.

`scripts/audit-aperag.ps1` запускает эту проверку автоматически, если передан
реальный `infra/aperag/.env`, существует index metadata и доступен ApeRAG admin
secrets file. Любой `warning` или `failed` больше не считается нормой.

## Что делать дальше

1. Не патчить ApeRAG container вручную. Это будет хрупко и сломается при
   rebuild/update image.
2. Держать patched image как воспроизводимое project-owned исправление.
3. При обновлении upstream ApeRAG проверять, нужен ли patch.
4. Если upstream исправит race, удалить локальный patch отдельным PR.

## Acceptance

Контур считается рабочим, если проходят:

```powershell
.\scripts\liq-aperag.ps1 health -EnvFile infra/aperag/.env
.\scripts\liq-aperag.ps1 ingest docs/ -EnvFile infra/aperag/.env
.\scripts\liq-aperag.ps1 eval -EnvFile infra/aperag/.env
.\scripts\liq-aperag.ps1 status docs/ -EnvFile infra/aperag/.env -CheckCommit -CheckDrift
.\scripts\audit-aperag.ps1 -EnvFile infra/aperag/.env.example
```

`ready_with_non_complete_status` должен быть пустым.
