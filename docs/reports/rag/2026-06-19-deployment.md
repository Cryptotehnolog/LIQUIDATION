# LightRAG Dev Memory Deployment - 2026-06-19

## Сервисы

- `liquidation-omniroute`: запущен, Docker health `healthy`
- `liquidation-lightrag`: запущен, `/health` возвращает `200`
- `liquidation-free-deepseek`: остановлен; fallback отключён, пока не настроен LIQUIDATION-owned Infisical auth

## Порты

- Omniroute: `127.0.0.1:21128 -> 20128`
- LightRAG: `127.0.0.1:19621 -> 9621`
- FreeDeepseek fallback: `127.0.0.1:19655 -> 9655`, только при явном запуске compose profile `fallback`

## Health

- Omniroute `/v1/models`: `200`
- LightRAG `/health`: `200`
- LightRAG `/`: `200` после redirect в Web UI
- FreeDeepseek `/health`: недоступен, пока fallback остановлен
- FreeDeepseek `/v1/models`: недоступен, пока fallback остановлен

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

- FreeDeepseek fallback не usable, пока в LIQUIDATION не создан собственный Infisical secret `FREE_DEEPSEEK_AUTH_JSON`.
- LightRAG запускается, но logs показывают, что embedding binding всё ещё defaulting to `ollama` с empty embedding model. Real ingest/eval должен оставаться заблокированным, пока embedding provider/model не настроены и не проверены.
- `FREE_DEEPSEEK_REF=main` допустим только для local skeleton validation. Перед использованием fallback path нужно pin to commit или tag.

## Что Улучшить Или Автоматизировать

- Держать `liq-rag health` привязанным к real service checks для Omniroute, LightRAG и FreeDeepseek fallback.
- Добавить LIQUIDATION-owned Infisical secret для FreeDeepseek auth перед новым запуском fallback.
- Добавить LightRAG embedding configuration check, который fails before ingest при empty provider/model.
