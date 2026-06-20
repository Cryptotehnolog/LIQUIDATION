# LightRAG Dev Memory Deployment - 2026-06-19

## Сервисы

- `liquidation-omniroute`: запущен, Docker health `healthy`
- `liquidation-lightrag`: запущен, `/health` возвращает `200`
- `liquidation-free-deepseek`: настроен как LIQUIDATION-owned fallback через Infisical auth
- Ollama host service: используется как embedding backend для LightRAG Dev Memory

## Порты

- Omniroute: `127.0.0.1:21128 -> 20128`
- LightRAG: `127.0.0.1:19621 -> 9621`
- FreeDeepseek fallback: `127.0.0.1:19655 -> 9655`, только при явном запуске compose profile `fallback`
- Ollama host API: `127.0.0.1:11434`

## Health

- Omniroute `/v1/models`: `200`
- LightRAG `/health`: `200`
- LightRAG `/`: `200` после redirect в Web UI
- FreeDeepseek `/health`: ожидается `200`, если fallback profile запущен
- FreeDeepseek `/v1/models`: ожидается `200`, если fallback profile запущен
- Ollama `/api/version`: `200`
- Ollama `/api/tags`: содержит `nomic-embed-text:latest`
- Ollama `/api/embed`: возвращает 768-dimensional embeddings

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

- `all-minilm` был проверен и отклонен для LightRAG graph indexing: entity/relation embeddings превышали контекст модели.
- `nomic-embed-text` является текущим локальным default: он тяжелее, но совместимее с LightRAG graph pipeline.
- `bge-m3` не является default и требует отдельного approval/benchmark перед использованием.
- `FREE_DEEPSEEK_REF` закреплён на commit `e54d324e1d6be1f4d074f5c7f078ae5d94deade8`, чтобы rebuild не подтягивал неожиданные изменения.
- FreeDeepseek fallback сейчас diagnostic-only для RAG health: LightRAG остаётся сконфигурированным на Omniroute, поэтому падение Omniroute считается `failed`, даже если FreeDeepseek отвечает.

## Что Улучшить Или Автоматизировать

- Добавить regression eval, который сравнивает `nomic-embed-text` с будущими кандидатами вроде `bge-m3:567m`.
- Добавить dashboard виджет: active LLM route, embedding model, indexed/current commit, eval status.
