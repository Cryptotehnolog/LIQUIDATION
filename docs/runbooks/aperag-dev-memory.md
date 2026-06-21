# ApeRAG Dev Memory

## Назначение

`LIQUIDATION` переходит на изолированный ApeRAG-контур для development memory.
Repository docs остаются source of truth, а ApeRAG является производным
retrieval/index слоем.

## Финальная Схема

```text
ApeRAG completion -> liquidation-free-deepseek
ApeRAG embeddings -> liquidation-embedding
```

FreeDeepseek не должен использовать auth, containers, networks, volumes или
browser profile второго проекта.

Текущий verified completion route:

```dotenv
APERAG_PRIMARY_MODEL=deepseek-chat
APERAG_FALLBACK_MODEL=deepseek-chat
APERAG_EMBEDDING_MODEL=sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2
```

OmniRoute больше не является частью ApeRAG route.

## Docker Isolation

Запрещено трогать контейнеры второго проекта:

- `omniroute`;
- `free_qwen`;
- `free_deepseek`;
- `aperag`;
- `stat-arb-*`.

Разрешённый prefix для этого проекта:

```text
liquidation-
```

## Индексация

В ApeRAG можно индексировать большие docs, specs, runbooks, research notes и
reports. Secrets, `.env`, Infisical exports, raw market-data dumps и database
backups запрещены.

## Acceptance Checks

Минимальный рабочий контур:

```powershell
.\scripts\guard-compose.ps1 -EnvFile infra/aperag/.env.example
.\scripts\check-images.ps1 -EnvFile infra/aperag/.env.example
.\scripts\liq-aperag.ps1 health -EnvFile infra/aperag/.env
.\scripts\setup-aperag-routing.ps1 -EnvFile infra/aperag/.env
.\scripts\liq-aperag.ps1 ingest docs/ -EnvFile infra/aperag/.env
.\scripts\liq-aperag.ps1 eval -EnvFile infra/aperag/.env
.\scripts\liq-aperag.ps1 status docs/ -EnvFile infra/aperag/.env -CheckCommit
```

Если registry временно ограничил manifest-запросы, `check-images.ps1` пишет
warning и продолжает локальный аудит. Для строгого pre-deployment режима:

```powershell
.\scripts\check-images.ps1 -EnvFile infra/aperag/.env.example -StrictRemoteManifests
```

Если health показывает `memory_status = completion-only-no-embedding`, ApeRAG
подключён к LLM completion, но ещё не готов для ingest/index. Нужен рабочий
`liquidation-embedding`.

`liq-aperag.ps1 ingest` делает full refresh project-owned collection: удаляет
старые документы из collection, загружает tracked docs, ждёт `COMPLETE` и
`ACTIVE` индексов, затем пишет ignored
`docs/reports/aperag/index-metadata.json`.

`liq-aperag.ps1 eval` выполняет retrieval smoke tests из
`docs/reports/aperag/eval-questions.json`. В eval есть отдельная проверка
русского UTF-8, потому что PowerShell 5.1 может испортить JSON response, если
читать его через `Invoke-RestMethod`.

Generated JSON в `docs/reports/aperag/`, research status JSON и query plans не
индексируются в ApeRAG default collection. Markdown audit reports можно
индексировать как operational memory.

## Critical Retrieval Anchors

Эти короткие anchors нужны, чтобы ApeRAG быстро находил важные project rules,
которые подробно раскрыты в больших specs.

- `paper-only`: реальная торговля запрещена до paper trading, replay reports,
  stable net paper PnL после fees, slippage и hedge penalties. Вопросы про
  торговлю "на бумаге" должны возвращать это правило.
- `archive verification`: Parquet archive считается verified только после
  checksum validation, readback проверки, row count, timestamp bounds,
  column statistics и проверки `parquet_schema_version`.
- `canonical deletion`: canonical events можно удалять только после verified
  archive и установленного `canonical_deletion_watermark`.
- `fee model`: первые venues для fees - Polymarket и Hyperliquid. Replay должен
  показывать gross PnL, fees, slippage, penalties и net PnL отдельно.

## Что Улучшить Или Автоматизировать

- Добавить scheduled freshness report.
- Добавить weekly backup metadata check.
