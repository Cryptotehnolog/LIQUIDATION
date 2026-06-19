# LightRAG Dev Memory Deployment - 2026-06-19

## Services

- `liquidation-omniroute`: running, Docker health `healthy`
- `liquidation-lightrag`: running, `/health` returns `200`
- `liquidation-free-deepseek`: running under compose profile `fallback` after temporary local auth bootstrap

## Ports

- Omniroute: `127.0.0.1:21128 -> 20128`
- LightRAG: `127.0.0.1:19621 -> 9621`
- FreeDeepseek fallback: `127.0.0.1:19655 -> 9655`

## Health

- Omniroute `/v1/models`: `200`
- LightRAG `/health`: `200`
- LightRAG `/`: `200` after redirect to Web UI
- FreeDeepseek `/health`: `200`
- FreeDeepseek `/v1/models`: `200`

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

- FreeDeepseek is currently usable as a fallback route, but auth was bootstrapped from a read-only copy of the second project's `deepseek-auth.json`. This is acceptable only as a temporary local bootstrap.
- Long-term FreeDeepseek auth still needs a LIQUIDATION-owned Infisical secret `FREE_DEEPSEEK_AUTH_JSON`.
- LightRAG starts, but logs show embedding binding is still defaulting to `ollama` with an empty embedding model. Real ingest/eval should remain blocked until embedding provider/model are configured and verified.
- `FREE_DEEPSEEK_REF=main` is acceptable for local skeleton validation only. It must be pinned to a commit or tag before relying on the fallback path.

## What To Improve Or Automate

- Keep `liq-rag health` wired to real service checks for Omniroute, LightRAG, and FreeDeepseek fallback.
- Replace temporary cross-project auth copy with a LIQUIDATION-owned Infisical secret.
- Add a LightRAG embedding configuration check that fails before ingest when provider/model are empty.
