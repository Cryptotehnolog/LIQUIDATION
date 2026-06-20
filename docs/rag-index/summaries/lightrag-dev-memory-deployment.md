# Summary: LightRAG Dev Memory Deployment

Source document:

- `docs/superpowers/plans/2026-06-19-lightrag-dev-memory-deployment.md`

## Цель

Поднять project-owned LightRAG Dev Memory до Rust foundation, чтобы проектная
память не зависела от чата и не трогала второй Docker project.

## Реализованная Схема

- `liquidation-lightrag` - LightRAG API/Web UI.
- `liquidation-omniroute` - primary OpenAI-compatible route to Kiro combo.
- `liquidation-free-deepseek` - fallback service, diagnostic-only for current
  health semantics.
- Ollama на Windows host даёт embeddings через `nomic-embed-text`.

## Важные Исправления

- `all-minilm` отклонён: несовместим с LightRAG graph indexing.
- Default embeddings: `nomic-embed-text`, dimension 768.
- Heavy docs не индексируются напрямую: `docs/superpowers/` и
  `docs/research/raw/` исключены.
- Curated memory должна жить в `docs/rag-index/`.
- `FREE_DEEPSEEK_REF` должен быть pinned to commit SHA.

## Acceptance

Команды должны проходить локально:

```powershell
.\scripts\liq-rag.ps1 ingest docs/ -EnvFile infra/lightrag/.env
.\scripts\liq-rag.ps1 eval -EnvFile infra/lightrag/.env
.\scripts\liq-rag.ps1 health -EnvFile infra/lightrag/.env
.\scripts\liq-rag.ps1 status --check-commit -EnvFile infra/lightrag/.env
.\scripts\audit-rag.ps1
```
