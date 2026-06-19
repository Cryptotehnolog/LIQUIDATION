# LightRAG Dev Memory

## Цель

LightRAG Dev Memory нужен как быстрый semantic index по документации проекта.
Он помогает не держать все решения в чате, но не заменяет Git и Markdown files.

Главное правило: `docs/` и committed specs/runbooks являются source of truth.
LightRAG является производным индексом. Если индекс устарел, недоступен или не
прошел eval, доверяем repository docs, а не ответам RAG.

## Изоляция Docker

LightRAG для `LIQUIDATION` должен запускаться отдельным Docker stack.

Правила:

- не трогать существующие containers `aperag-*`, `omniroute`,
  `stat-arb-free-qwen`, `stat-arb-free-deepseek`, `stat-arb-infisical-*`;
- не выполнять unscoped `docker compose down`, `docker system prune`,
  `docker volume prune` или удаление containers/volumes без prefix проекта;
- использовать prefix `liquidation` для compose project, containers, networks,
  volumes и ports;
- перед изменениями проверять `docker ps --format "{{.Names}}"`;
- любые cleanup commands должны быть scoped только на `liquidation-*`.

Если есть сомнение, что команда может задеть второй проект, команда не
выполняется.

## Что индексировать

На первом этапе индексируются только repo-owned docs:

- `docs/superpowers/specs/`;
- `docs/runbooks/`;
- `docs/research/`;
- `docs/reports/`;
- `docs/snapshots/`, если snapshots уже normalized и committed.

Запрещено индексировать:

- `.env`;
- Infisical exports;
- private keys;
- exchange credentials;
- API tokens;
- raw market-data blobs;
- database dumps;
- Docker volumes второго проекта.

## Обязательная metadata индекса

Каждый ingest должен сохранять:

- indexed Git commit hash;
- branch;
- ingestion timestamp;
- indexed paths;
- ingestion config version;
- LightRAG container/image version;
- eval result.

Без этой metadata индекс считается непригодным для разработки.

## Команды проекта

Планируемые команды:

```powershell
liq-rag ingest docs/
liq-rag eval
liq-rag health
liq-rag status --check-commit
```

`liq-rag ingest docs/` перестраивает индекс по repository docs.

`liq-rag eval` проверяет retrieval quality на known question/answer pairs.
Минимальный порог: top-5 recall или simple answer accuracy не ниже 80%.
Mean reciprocal rank сохраняется как trend metric.

`liq-rag health` проверяет доступность LightRAG, storage health, возраст
последнего ingest и результат последнего eval.

Health status должен различать:

- `ok`: `liquidation-omniroute` и Kiro combo работают, index fresh, eval выше
  threshold;
- `degraded-but-usable`: `liquidation-omniroute` недоступен, но
  `liquidation-free-deepseek` отвечает напрямую;
- `failed`: не работают ни `liquidation-omniroute`, ни
  `liquidation-free-deepseek`, или LightRAG/index/eval непригодны.

`liq-rag status --check-commit` сравнивает indexed Git commit hash с текущим
Git commit. Если индекс отстал от repository docs, команда должна вернуть
ошибку или high-severity warning.

## Daily health check

Ежедневная проверка должна:

- запускать `liq-rag health`;
- запускать `liq-rag status --check-commit`;
- показывать возраст индекса;
- показывать последний eval score;
- отправлять alert, если LightRAG stale, unavailable или eval ниже threshold.

Alert должен быть виден минимум в structured logs. Позже можно добавить
GitHub issue, dashboard notification или внешний канал.

## Поведение при сбоях

Если LightRAG unavailable, stale или ниже quality threshold:

- не блокировать разработку;
- не блокировать CI;
- не блокировать collector/replay;
- не использовать RAG output как основание для изменения стратегии;
- читать source docs напрямую из repository.

RAG помогает вспоминать и находить, но не принимает решения.

## Что улучшить или автоматизировать

- Добавить `liq-rag` как Rust CLI subcommand или отдельный small tool.
- Добавить scheduled job для daily health check.
- Добавить dashboard panel: indexed commit, current commit, freshness, eval
  score, status.
- Добавить pre-commit или CI check, который предупреждает: docs changed, а
  LightRAG index не обновлен.
- Добавить ingestion report в `docs/reports/rag/`.
