# ApeRAG Dev Memory Infrastructure

Этот каталог содержит только infrastructure skeleton для изолированной памяти
проекта `LIQUIDATION`.

## Принципы

- Все container names, networks и volumes начинаются с `liquidation-`.
- Контур второго проекта не используется и не изменяется.
- Реальный `infra/aperag/.env`, secrets и runtime data не коммитятся.
- `liquidation-free-deepseek` является project-owned completion route.
- `liquidation-embedding` является project-owned embeddings route.
- OmniRoute не является частью текущего ApeRAG route.
- `liquidation-aperag:local` является project-owned patched ApeRAG image.
- ApeRAG отвечает за ingest, retrieval, UI/API и collections.

## Проверки Перед Deployment

```powershell
.\scripts\check-images.ps1 -EnvFile infra/aperag/.env.example
.\scripts\guard-compose.ps1 -EnvFile infra/aperag/.env.example
docker compose --env-file infra/aperag/.env.example -f infra/aperag/compose.yml -p liquidation config
```

## Локальные Адреса

- ApeRAG Web UI: `http://127.0.0.1:23000/web/`
- ApeRAG API docs: `http://127.0.0.1:28000/docs`
- FreeDeepseek: `http://127.0.0.1:19655`
- Embeddings: `http://127.0.0.1:28001`

## Что Улучшить Или Автоматизировать

- Pin `APERAG_BASE_IMAGE` digest вместо floating nightly tag.
- Добавить dashboard panel для freshness/eval/status.
