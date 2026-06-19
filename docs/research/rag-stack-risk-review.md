# RAG Stack Risk Review

Дата проверки: 2026-06-19.

## Что проверяли

- LightRAG deployment risk.
- OmniRoute provider routing/fallback.
- FreeDeepseekAPI as emergency route.
- GitHub/community signals через `last30days`.

## `last30days` result

Raw output:
[lightrag-omniroute-freedeepseekapi-docker-reliability-raw-rag-stack-risk.md](raw/lightrag-omniroute-freedeepseekapi-docker-reliability-raw-rag-stack-risk.md)

GitHub signals:

- `HKUDS/LightRAG`: high adoption, but many open issues;
- `diegosouzapw/OmniRoute`: active gateway project with open issues;
- `ForgetMeAI/FreeDeepseekAPI`: smaller project, OpenAI-compatible proxy,
  multiple open issues.

Вывод: выбранная архитектура правильная только при health/eval/fallback gates.
Нельзя считать любой из этих компонентов безусловно stable.

## Official/project findings

Sources:
[LightRAG GitHub](https://github.com/HKUDS/LightRAG),
[LightRAG API Server docs](https://github.com/HKUDS/LightRAG/blob/main/docs/LightRAG-API-Server.md),
[OmniRoute GitHub](https://github.com/diegosouzapw/OmniRoute),
[OmniRoute Docker Hub](https://hub.docker.com/r/diegosouzapw/omniroute),
[FreeDeepseekAPI GitHub](https://github.com/ForgetMeAI/FreeDeepseekAPI),
[OmniRoute custom provider discussion](https://github.com/diegosouzapw/OmniRoute/discussions/1983).

LightRAG supports Docker Compose deployment and requires LLM/embedding
configuration. Official/project docs also mention API server and Web UI.

OmniRoute exposes OpenAI-compatible routing and auto-fallback concepts.

OmniRoute custom provider compatibility requires base URL to be reachable from
the OmniRoute container perspective. If provider and OmniRoute run in Docker,
container name/network addressing is safer than `localhost`.

FreeDeepseekAPI is useful as emergency route, but it depends on DeepSeek Web
behavior. Treat it as `degraded-but-usable`, not as `ok`.

Local check on 2026-06-19:

- current `stat-arb-free-deepseek` container responded on `/health`;
- `/v1/models` responded;
- `/v1/chat/completions` returned a short `OK` response.

This proves compatibility in the current environment, but does not remove the
need for separate `liquidation-free-deepseek`.

## Design impact

- Keep final route:
  `LightRAG -> liquidation-omniroute -> Kiro combo`.
- Keep emergency route:
  `LightRAG/liq-rag -> liquidation-free-deepseek`.
- Do not reuse second project's `omniroute` or `stat-arb-free-deepseek`.
- `liq-rag health` must expose `ok`, `degraded-but-usable`, `failed`, and
  `stale`.
- RAG index is not source of truth. Git docs remain authoritative.

## Что улучшить или автоматизировать

- Add provider failover test: Omniroute down, FreeDeepseek direct route alive.
- Add Docker network preflight: OmniRoute can reach FreeDeepseek by service name.
- Add `liq-rag eval` with known Q/A pairs before trusting refreshed index.
- Add dashboard panel for active provider path and indexed/current commit.
