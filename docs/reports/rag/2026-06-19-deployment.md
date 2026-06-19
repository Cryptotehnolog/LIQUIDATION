# LightRAG Dev Memory Deployment - 2026-06-19

## Services

- `liquidation-omniroute`: running, Docker health `healthy`
- `liquidation-lightrag`: running, `/health` returns `200`
- `liquidation-free-deepseek`: image built, service moved to compose profile `fallback`, not running by default

## Ports

- Omniroute: `127.0.0.1:21128 -> 20128`
- LightRAG: `127.0.0.1:19621 -> 9621`
- FreeDeepseek fallback: `127.0.0.1:19655 -> 9655` when profile `fallback` is enabled

## Health

- Omniroute `/v1/models`: `200`
- LightRAG `/health`: `200`
- LightRAG `/`: `200` after redirect to Web UI
- FreeDeepseek `/health`: not available because fallback profile is not running

## Docker Objects Created

- network: `liquidation-rag`
- volumes:
  - `liquidation-omniroute-data`
  - `liquidation-free-deepseek-data`
- image:
  - `liquidation-free-deepseek:local`

## Safety Verification

- Existing second-project containers were not restarted, removed, renamed, or reconfigured.
- `scripts/guard-compose.ps1 -EnvFile infra/lightrag/.env` passed.
- `scripts/check-images.ps1 -EnvFile infra/lightrag/.env` passed.
- `docker compose --env-file infra/lightrag/.env -f infra/lightrag/compose.yml -p liquidation config` passed.

## Blockers

- FreeDeepseek cannot be considered usable until `deepseek-auth.json` is provided through an ignored local path or Infisical-backed secret flow.
- LightRAG starts, but logs show embedding binding is still defaulting to `ollama` with an empty embedding model. Real ingest/eval should remain blocked until embedding provider/model are configured and verified.
- `FREE_DEEPSEEK_REF=main` is acceptable for local skeleton validation only. It must be pinned to a commit or tag before relying on the fallback path.

## What To Improve Or Automate

- Add `liq-rag health` real service checks for Omniroute, LightRAG, and FreeDeepseek fallback.
- Add a secret bootstrap runbook for FreeDeepseek auth via Infisical without writing secrets into Git.
- Add a LightRAG embedding configuration check that fails before ingest when provider/model are empty.
