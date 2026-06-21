# RAG Stack Risk Review

Дата проверки: 2026-06-19.

## Что проверяли

- ApeRAG deployment risk.
- FreeDeepseekAPI as project-owned completion route.
- Local OpenAI-compatible embedding service.
- Historical OmniRoute provider routing/fallback decision.
- GitHub/community signals через `last30days`.

## `last30days` result

Raw output был переименован во время перехода со старого RAG design на
изолированный ApeRAG design. Текущий raw research для RAG stack не является
source of truth; актуальное operational состояние зафиксировано в runbooks и
implementation audit.

GitHub signals:

- `HKUDS/ApeRAG`: high adoption, but many open issues;
- `diegosouzapw/OmniRoute`: active gateway project with open issues;
- `ForgetMeAI/FreeDeepseekAPI`: smaller project, OpenAI-compatible proxy,
  multiple open issues.

Вывод: выбранная архитектура правильная только при health/eval/freshness gates.
Нельзя считать любой из этих компонентов безусловно stable.

## Official/project findings

Sources:
[ApeRAG GitHub](https://github.com/apecloud/ApeRAG),
[ApeRAG Document Upload Design](https://rag.apecloud.com/docs/design/document_upload_design),
[OmniRoute GitHub](https://github.com/diegosouzapw/OmniRoute),
[OmniRoute Docker Hub](https://hub.docker.com/r/diegosouzapw/omniroute),
[FreeDeepseekAPI GitHub](https://github.com/ForgetMeAI/FreeDeepseekAPI),
[OmniRoute custom provider discussion](https://github.com/diegosouzapw/OmniRoute/discussions/1983).

ApeRAG supports Docker Compose deployment and requires LLM/embedding
configuration. Official/project docs also mention API server and Web UI.

OmniRoute exposes OpenAI-compatible routing and auto-fallback concepts, but it
was removed from the current ApeRAG route to reduce dependency surface.

OmniRoute custom provider compatibility requires base URL to be reachable from
the OmniRoute container perspective. If provider and OmniRoute run in Docker,
container name/network addressing is safer than `localhost`.

FreeDeepseekAPI is useful as emergency route, but it depends on DeepSeek Web
behavior. Treat it as diagnostic fallback availability, not as `ok`.

Local check on 2026-06-19:

- current `stat-arb-free-deepseek` container responded on `/health`;
- `/v1/models` responded;
- `/v1/chat/completions` returned a short `OK` response.

This proves OpenAI-compatible completion compatibility in the current
environment, but does not justify reusing the second project's FreeDeepseek.

## Design impact

- Keep final route:
  `ApeRAG completion -> liquidation-free-deepseek`.
- Keep embeddings route:
  `ApeRAG embeddings -> liquidation-embedding`.
- Do not reuse second project's `omniroute` or `stat-arb-free-deepseek`.
- OmniRoute is historical/deprecated for this project and must not be restored
  without a new design decision.
- `liq-aperag health` MVP must expose `ok` or `failed` for ApeRAG API/Web,
  FreeDeepseek completion and embedding readiness.
- RAG index is not source of truth. Git docs remain authoritative.
- `liquidation-aperag:local` includes a project-owned build-time patch for the
  document status race; drift warnings are not accepted as normal.

## Что улучшить или автоматизировать

- Add `liq-aperag eval` with known Q/A pairs before trusting refreshed index.
- Add dashboard panel for active provider path and indexed/current commit.
- Pin `APERAG_BASE_IMAGE` by digest instead of floating nightly tag.
