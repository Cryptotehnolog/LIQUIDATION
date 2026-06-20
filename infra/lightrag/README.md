# LightRAG Dev Memory Infrastructure

Этот stack принадлежит только проекту LIQUIDATION. Все project-owned containers, networks и volumes должны использовать префикс `liquidation-*`.

Нельзя переиспользовать или менять containers второго проекта:

- `omniroute`
- `stat-arb-free-qwen`
- `stat-arb-free-deepseek`
- `aperag-*`
- `stat-arb-infisical-*`

Перед любым `docker compose pull`, `docker compose build` или `docker compose up` запустить:

```powershell
.\scripts\preflight.ps1
.\scripts\check-images.ps1 -EnvFile infra/lightrag/.env
.\scripts\guard-compose.ps1 -EnvFile infra/lightrag/.env
docker compose --env-file infra/lightrag/.env -f infra/lightrag/compose.yml -p liquidation config
```

## Image Policy

- `diegosouzapw/omniroute:latest` проверен через `docker manifest inspect`.
- `ghcr.io/hkuds/lightrag:latest` проверен через `docker manifest inspect`.
- `forgetmeai/freedeepseekapi:latest` не подтвержден: registry вернул `denied/unauthorized`, а GitHub repository не публикует container package. Поэтому `liquidation-free-deepseek` собирается локально из `ForgetMeAI/FreeDeepseekAPI` через `infra/lightrag/free-deepseek/Dockerfile`.

`FREE_DEEPSEEK_REF` должен быть закреплён на commit SHA или tag. Значение `main`
запрещено для deployment, потому что rebuild может подтянуть несовместимые изменения.

## FreeDeepseek Fallback

`liquidation-free-deepseek` находится в compose profile `fallback` и не запускается default-командой `docker compose up -d`.

Причина: FreeDeepseek требует `deepseek-auth.json`. Без него контейнер либо показывает interactive menu, либо падает в non-interactive режиме. Запускать fallback можно только после создания ignored auth file и проверки:

```powershell
.\scripts\check-images.ps1 -EnvFile infra/lightrag/.env
docker compose --env-file infra/lightrag/.env -f infra/lightrag/compose.yml -p liquidation --profile fallback up -d liquidation-free-deepseek
```

## Source Of Truth

Git docs остаются source of truth. LightRAG index является disposable derived index. Если `liq-rag status --check-commit` показывает stale, index нельзя использовать как актуальную память разработки.

## Secrets

В repository хранится только `.env.example`. Реальный `infra/lightrag/.env`, auth files, Infisical exports, cookies и API keys не коммитятся.
