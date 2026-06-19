# LightRAG Dev Memory Deployment - 2026-06-19

## Сервисы

- `liquidation-omniroute`: запущен, Docker health `healthy`
- `liquidation-lightrag`: запущен, `/health` возвращает `200`
- `liquidation-free-deepseek`: настроен как LIQUIDATION-owned fallback через Infisical auth
- `liquidation-embeddings`: проектный OpenAI-compatible embedding service для LightRAG Dev Memory

## Порты

- Omniroute: `127.0.0.1:21128 -> 20128`
- LightRAG: `127.0.0.1:19621 -> 9621`
- FreeDeepseek fallback: `127.0.0.1:19655 -> 9655`, только при явном запуске compose profile `fallback`
- Embeddings: `127.0.0.1:21435 -> 21435`

## Health

- Omniroute `/v1/models`: `200`
- LightRAG `/health`: `200`
- LightRAG `/`: `200` после redirect в Web UI
- FreeDeepseek `/health`: ожидается `200`, если fallback profile запущен
- FreeDeepseek `/v1/models`: ожидается `200`, если fallback profile запущен
- Embeddings `/health`: ожидается `200`
- Embeddings `/v1/models`: должен содержать `liquidation-hash-embedding-1024`

## Созданные Docker Объекты

- network: `liquidation-rag`
- volumes:
  - `liquidation-omniroute-data`
  - `liquidation-free-deepseek-data`
- image:
  - `liquidation-free-deepseek:local`

## Safety Verification

- Existing second-project containers не были restarted, removed, renamed или reconfigured.
- `scripts/guard-compose.ps1 -EnvFile infra/lightrag/.env` passed.
- `scripts/check-images.ps1 -EnvFile infra/lightrag/.env` passed before corrective shutdown.
- `docker compose --env-file infra/lightrag/.env -f infra/lightrag/compose.yml -p liquidation config` passed.

## Корректирующее Действие

Temporary local bootstrap скопировал FreeDeepseek auth file второго проекта в ignored data directory LIQUIDATION. Это было неправильное решение: LIQUIDATION не должен зависеть от auth state второго проекта.

Корректирующее действие выполнено:

- `liquidation-free-deepseek` остановлен.
- Скопированный `infra/lightrag/data/secrets/deepseek-auth.json` удалён из LIQUIDATION.
- `scripts/bootstrap-freedeepseek-auth.ps1` больше не поддерживает source-file auth bootstrap.
- `docs/runbooks/freedeepseek-infisical-auth.md` явно запрещает cross-project auth reuse.

## Блокеры

- `liquidation-hash-embedding-1024` является MVP-компромиссом. Он достаточен для проверки инженерного lifecycle, но не является финальной semantic embedding model.
- Перед production-grade semantic RAG нужно заменить embedding backend на качественную модель и обновить eval threshold.
- `FREE_DEEPSEEK_REF` закреплён на commit `3c8494bd389020c0f2b2bd07094cfc7b44110015`, чтобы rebuild не подтягивал неожиданные изменения.

## Что Улучшить Или Автоматизировать

- Заменить `liquidation-hash-embedding-1024` на реальную embedding model после стабилизации Docker image pull или выбора managed provider.
- Добавить regression eval, который сравнивает качество hash backend и будущей semantic model.
- Добавить dashboard виджет: active LLM route, embedding model, indexed/current commit, eval status.
