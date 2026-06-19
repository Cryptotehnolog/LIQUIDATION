# Infrastructure Preflight - 2026-06-19

## Git

- status: clean
- branch: `main 70ed7ae [origin/main] docs: plan lightrag memory deployment`

## Docker

Выполнена read-only инвентаризация. Контейнеры, networks, volumes и images не изменялись.

### Существующие Containers

Эти containers относятся ко второму проекту или общей локальной инфраструктуре. Deployment проекта LIQUIDATION не должен их изменять:

- `omniroute` - `diegosouzapw/omniroute:latest` - `127.0.0.1:20128->20128/tcp` - healthy
- `stat-arb-free-qwen` - `free_qwen-stat-arb-free-qwen` - `127.0.0.1:3264->3264/tcp` - healthy
- `stat-arb-free-deepseek` - `free_deepseek-stat-arb-free-deepseek` - `127.0.0.1:9655->9655/tcp` - healthy
- `aperag-frontend` - `apecloud/aperag-frontend:v0.0.0-nightly` - `127.0.0.1:13000->3000/tcp`
- `aperag-celeryworker` - `apecloud/aperag:v0.0.0-nightly`
- `aperag-api` - `apecloud/aperag:v0.0.0-nightly` - `127.0.0.1:18000->8000/tcp` - healthy
- `aperag-celerybeat` - `apecloud/aperag:v0.0.0-nightly`
- `aperag-flower` - `apecloud/aperag:v0.0.0-nightly` - `127.0.0.1:15555->5555/tcp`
- `aperag-es` - `apecloud/elasticsearch:8.8.2` - `127.0.0.1:19200->9200/tcp` - healthy
- `aperag-redis` - `apecloud/redis:6` - `127.0.0.1:16379->6379/tcp` - healthy
- `aperag-postgres` - `apecloud/pgvector:pg16` - `127.0.0.1:15432->5432/tcp` - healthy
- `aperag-qdrant` - `apecloud/qdrant:v1.13.4` - `127.0.0.1:16333->6333/tcp` - healthy
- `stat-arb-infisical-backend` - `infisical/infisical:latest` - `127.0.0.1:8080->8080/tcp`
- `stat-arb-infisical-redis` - `redis:7-alpine`
- `stat-arb-infisical-db` - `postgres:14-alpine` - healthy

### Существующие Networks

- `aperag_default`
- `bridge`
- `free_deepseek_default`
- `free_qwen_default`
- `host`
- `none`
- `stat-arb-infisical_infisical`

### Существующие Volumes

- `aperag_aperag-es-data`
- `aperag_aperag-postgres-data`
- `aperag_aperag-qdrant-data`
- `aperag_aperag-redis-data`
- `aperag_aperag-shared-data`
- `omniroute-data`
- `stat-arb-infisical_pg_data`
- `stat-arb-infisical_redis_data`

## Ports

### Занятые Или Зарезервированные

- `20128` - существующий `omniroute`
- `3264` - существующий `stat-arb-free-qwen`
- `9655` - существующий `stat-arb-free-deepseek`
- `13000` - существующий `aperag-frontend`
- `18000` - существующий `aperag-api`
- `15555` - существующий `aperag-flower`
- `19200` - существующий `aperag-es`
- `16379` - существующий `aperag-redis`
- `15432` - существующий `aperag-postgres`
- `16333` - существующий `aperag-qdrant`
- `8080` - существующий `stat-arb-infisical-backend`
- `8501`, `9222`, `19206`, `50128` - другие локальные listeners, не использовать без отдельной проверки

### Выбраны Для LIQUIDATION

- `21128` - proposed host port для `liquidation-omniroute`
- `19655` - proposed host port для `liquidation-free-deepseek`
- `19621` - proposed host port для `liquidation-lightrag`

Все три proposed ports были свободны во время preflight.

## Read-Only Checks

- existing FreeDeepseek `/health`: `200`
- existing FreeDeepseek `/v1/models`: `200`
- existing Omniroute `/v1/models`: `200`

Эти checks подтверждают, что сервисы второго проекта сейчас доступны. Они не перезапускались и не перенастраивались.

## Blockers

- отсутствуют для Task 1 и Task 2.
- перед реальным deployment всё ещё нужно проверить image names и создать игнорируемый `infra/lightrag/.env` до любого `docker compose pull` или `docker compose up`.

## Что Улучшить Или Автоматизировать

- Добавить `scripts/preflight.ps1`, чтобы эту инвентаризацию можно было повторять перед каждым infrastructure change.
- Добавить guard, который падает, если compose file ссылается на container names, networks или volumes без префикса `liquidation-*`.
- Добавить dashboard tile для RAG health статусов `ok`, `degraded-but-usable` и `failed`.
