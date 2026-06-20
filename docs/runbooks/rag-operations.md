# RAG Operations Runbook

## Цель

Этот runbook описывает operational model для LightRAG Dev Memory в проекте
`LIQUIDATION`: запуск, provider routing, backup, restore, health check и правила
обновления индекса.

RAG не является source of truth. Source of truth остается в Git: `docs/`,
specs, runbooks, research notes и reports. LightRAG является производным
semantic index и должен доказывать свежесть через Git commit hash.

## Финальная схема

Основной путь:

```text
LightRAG -> liquidation-omniroute -> Kiro combo
```

Аварийный LLM route:

```text
operator/liq-rag direct check -> liquidation-free-deepseek
```

`liquidation-free-deepseek` является обязательным резервом для LLM-доступа, но
не является автоматическим fallback для LightRAG, пока LightRAG
сконфигурирован на `liquidation-omniroute`. Если `liquidation-omniroute`
недоступен, RAG считается `failed`, а доступность FreeDeepseek записывается как
diagnostic `fallback_available`.

## Docker isolation

Использовать отдельный Docker stack с prefix `liquidation`.

Не трогать контейнеры второго проекта:

- `omniroute`;
- `stat-arb-free-qwen`;
- `stat-arb-free-deepseek`;
- все `aperag-*`;
- все `stat-arb-infisical-*`.

Перед любыми Docker-действиями:

```powershell
docker ps --format "{{.Names}} {{.Image}} {{.Status}} {{.Ports}}"
docker network ls
docker volume ls
```

Запрещены unscoped destructive commands:

```powershell
docker compose down --remove-orphans
docker system prune
docker volume prune
docker network prune
```

Если нужен `down`, он должен быть scoped:

```powershell
docker compose -p liquidation down
```

## Environment variables

Пути и порты не должны быть жестко привязаны к диску `D:`.

Минимальный набор переменных:

```dotenv
LIGHTRAG_DATA_PATH=
LIGHTRAG_BACKUP_PATH=
LIGHTRAG_REPORT_PATH=docs/reports/rag
LIGHTRAG_INDEXED_PATHS=docs/
LIGHTRAG_API_PORT=
LIQUIDATION_OMNIROUTE_PORT=
LIQUIDATION_FREE_DEEPSEEK_PORT=
LIQUIDATION_OMNIROUTE_BASE_URL=
LIQUIDATION_FREE_DEEPSEEK_BASE_URL=
LIQUIDATION_EMBEDDINGS_BASE_URL=
LIGHTRAG_EMBEDDING_BINDING=
LIGHTRAG_EMBEDDING_BINDING_HOST=
LIGHTRAG_EMBEDDING_MODEL=
LIGHTRAG_EMBEDDING_DIM=
LIGHTRAG_INGEST_TIMEOUT_SECONDS=
```

В repository хранить только `.env.example`. Реальные secrets должны храниться в
Infisical. `.env`, Infisical exports, API tokens и exchange credentials нельзя
индексировать в LightRAG.

## Infisical

На MVP не поднимать второй Infisical без необходимости. Использовать
существующий Infisical как external secret backend, но создать отдельный
project/environment для `LIQUIDATION`.

Правила:

- не менять containers `stat-arb-infisical-*`;
- не подключаться к internal Docker network второго проекта без отдельного
  решения;
- получать secrets через опубликованный URL, Infisical CLI или API;
- `liq-rag health` проверяет наличие нужных secret names, но никогда не выводит
  secret values.

Если существующий Infisical становится unstable dependency, отдельный Infisical
для `LIQUIDATION` рассматривается как follow-up.

## Provider routing

`liquidation-omniroute` должен использовать Kiro combo как primary route.

Ожидаемый combo:

- Kiro DeepSeek 3.2;
- Kiro GLM-5;
- Kiro Claude Sonnet 4.5;
- Kiro MiniMax M2.5;
- Kiro Qwen3 Coder Next.

`liquidation-free-deepseek` подключается как emergency LLM route. Если возможно
подключить его в `liquidation-omniroute` как OpenAI-compatible provider, он
может быть last fallback в combo. Direct fallback из `liq-rag` можно считать
usable только после отдельной команды, которая действительно выполняет RAG query
или LLM task через FreeDeepseek. Один только `/health` FreeDeepseek не делает
LightRAG usable.

Минимальные provider checks:

```powershell
Invoke-WebRequest "$env:LIQUIDATION_OMNIROUTE_BASE_URL/v1/models" -UseBasicParsing
Invoke-WebRequest "$env:LIQUIDATION_FREE_DEEPSEEK_BASE_URL/v1/models" -UseBasicParsing
```

Для completion check использовать короткий non-streaming request. Streaming не
является обязательным для MVP RAG.

## Embeddings

MVP использует Ollama, установленную на Windows host, как embedding backend.
LightRAG работает в Docker и обращается к host Ollama через:

```text
http://host.docker.internal:11434
```

Host-side scripts проверяют Ollama через:

```text
http://127.0.0.1:11434
```

Default model: `nomic-embed-text`.

Причина выбора: `all-minilm` был быстрым, но оказался несовместим с текущим
LightRAG graph indexing: entity/relation embeddings превышали контекст модели.
`nomic-embed-text` возвращает 768-dimensional embeddings и лучше подходит для
локального LightRAG Dev Memory. `bge-m3` не является default, потому что он
тяжелее и может создавать лишнюю нагрузку на ноутбук и Docker Desktop.

Default chunking для `nomic-embed-text`: `LIGHTRAG_CHUNK_TOKEN_SIZE=900` и
`LIGHTRAG_CHUNK_OVERLAP_TOKEN_SIZE=100`. Меньшие значения вроде `256/32`
создают слишком много chunks и резко замедляют graph extraction через LLM.

Если embedding model меняется, старый LightRAG index нельзя использовать как
совместимый. Нужно остановить `liquidation-lightrag`, перенести старый
`rag_storage` в `infra/lightrag/backups/`, поднять LightRAG заново и выполнить
полный `liq-rag ingest docs/`.

Минимальные embedding checks:

```powershell
Invoke-WebRequest "http://127.0.0.1:11434/api/version" -UseBasicParsing
Invoke-WebRequest "http://127.0.0.1:11434/api/tags" -UseBasicParsing
.\scripts\benchmark-ollama-embeddings.ps1
```

## Health statuses

`liq-rag health` должен возвращать один из статусов:

- `ok`: `liquidation-omniroute` доступен, Kiro combo отвечает, LightRAG
  доступен, embedding route отвечает, index fresh, последний `liq-rag eval`
  выше threshold.
- `failed`: primary route, LightRAG, embedding route, index freshness или eval
  непригодны. Если FreeDeepseek отвечает, report должен показывать
  `fallback_available = true`, но это diagnostic-only, пока LightRAG не умеет
  переключаться на него.

Если indexed Git commit hash не совпадает с текущим Git commit для tracked docs,
status должен включать `stale`. Stale RAG output нельзя использовать как
основание для изменения strategy, risk limits или runbooks.

## Ingest

Базовая команда:

```powershell
liq-rag ingest docs/
```

Ingest должен:

- читать только paths из `LIGHTRAG_INDEXED_PATHS`;
- включать curated memory layer `docs/rag-index/`;
- применять denylist для secrets, raw data и тяжёлых planning artifacts,
  включая `docs/research/raw/` и `docs/superpowers/`;
- проверять, что runtime config LightRAG совпадает с `.env`;
- падать, если LightRAG возвращает failed documents после pipeline;
- использовать `LIGHTRAG_INGEST_TIMEOUT_SECONDS` для длинных graph-indexing
  runs, вместо hardcoded бесконечного ожидания;
- сохранять indexed Git commit hash;
- сохранять ingestion timestamp;
- сохранять indexed paths;
- сохранять ingestion config version;
- писать report в `LIGHTRAG_REPORT_PATH`.

При добавлении нового большого source doc нужно добавить или обновить
соответствующий summary/decision record в `docs/rag-index/`.

После ingest обязательно запускать:

```powershell
liq-rag eval
liq-rag status --check-commit
```

## Eval

Базовая команда:

```powershell
liq-rag eval
```

Eval dataset хранится в Git, а не в LightRAG index. Минимальный threshold:
top-5 recall или simple answer accuracy не ниже 80%. Mean reciprocal rank
сохраняется как trend metric.

Если eval ниже threshold, index считается непригодным для development decisions.

## Commit freshness

Базовая команда:

```powershell
liq-rag status --check-commit
```

Команда сравнивает indexed Git commit hash с текущим Git commit. Если docs
changed после последнего ingest, команда должна вернуть warning или non-zero
exit code.

## Backup

Индекс можно пересобрать, поэтому backup RAG менее критичен, чем backup
repository docs. Но metadata, eval dataset и ingestion reports должны
сохраняться надежно.

Рекомендуемая политика:

- daily metadata backup;
- weekly full backup;
- backup verification после создания;
- хранить backups в `LIGHTRAG_BACKUP_PATH`;
- не хранить backup archives в Git.

Планируемые команды:

```powershell
liq-rag backup create
liq-rag backup verify
liq-rag backup list
```

Daily metadata backup должен включать:

- indexed Git commit hash;
- ingestion timestamp;
- indexed paths;
- eval result;
- provider health snapshot;
- LightRAG image/container version.

Weekly full backup должен включать LightRAG data volume или directory из
`LIGHTRAG_DATA_PATH`.

## Restore

Restore должен начинаться с dry-run:

```powershell
liq-rag restore --dry-run <backup-id>
```

Dry-run проверяет:

- backup exists;
- checksum valid;
- schema/config version compatible;
- target `LIGHTRAG_DATA_PATH` writable;
- restore не затронет чужие Docker volumes.

Фактический restore:

```powershell
liq-rag restore <backup-id>
liq-rag health
liq-rag eval
liq-rag status --check-commit
```

Если restore прошел, но commit hash stale, индекс можно использовать только как
поисковую подсказку; authoritative source остается в repository docs.

## Daily health check

Ежедневная проверка:

```powershell
liq-rag health
liq-rag status --check-commit
liq-rag eval
```

Report писать в:

```text
docs/reports/rag/YYYY-MM-DD.md
```

Минимальное содержимое report:

- status: `ok` или `failed`;
- active provider path;
- fallback availability как diagnostic field;
- indexed commit;
- current commit;
- index age;
- eval score;
- backup status;
- warnings.

## Правила обновления индекса

Запускать ingest:

- после изменения `docs/`;
- после изменения specs/runbooks;
- после добавления research notes или reports;
- после обновления documentation snapshots;
- вручную после urgent API announcements.

Weekly scheduled rebuild остается fallback, но не заменяет commit-based refresh.

## Acceptance checks

RAG deployment считается пригодным, когда локально проходят:

```powershell
liq-rag ingest docs/
liq-rag eval
liq-rag health
liq-rag status --check-commit
```

`failed` блокирует использование RAG и требует fallback на repository docs.
FreeDeepseek availability может помочь оператору, но не заменяет LightRAG
fallback без отдельной реализации direct route.

## Что улучшить или автоматизировать

- Добавить `liq-rag` как Rust CLI subcommand.
- Добавить port preflight: занятые ports, container names, networks, volumes.
- Добавить dashboard panel: RAG status, active provider, indexed/current commit,
  eval score, backup freshness.
- Добавить CI warning: docs changed, но RAG metadata stale.
- Добавить provider failover test: Omniroute недоступен, FreeDeepseek отвечает.
