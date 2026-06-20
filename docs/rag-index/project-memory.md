# Project Memory

## Назначение

Этот файл является входной точкой LightRAG Dev Memory для проекта
`LIQUIDATION`. Он хранит сжатую рабочую память: принятые решения, запреты,
границы проекта и ссылки на более подробные decision records и summaries.

Git repository остаётся source of truth. LightRAG является производным индексом.
Если LightRAG stale, failed или eval ниже threshold, использовать repository
docs напрямую.

## Текущая Архитектурная Линия

- Разработка ведётся на Rust.
- Реальная торговля запрещена до paper trading и replay validation.
- Primary RAG path: `LightRAG -> liquidation-omniroute -> Kiro combo`.
- Emergency diagnostic route: `liq-rag -> liquidation-free-deepseek`.
- FreeDeepseek availability не делает RAG usable, пока LightRAG не умеет
  проверенный direct failover.
- Docker services проекта должны иметь prefix `liquidation-*`.
- Контейнеры второго проекта нельзя трогать: `omniroute`,
  `stat-arb-free-qwen`, `stat-arb-free-deepseek`, `aperag-*`,
  `stat-arb-infisical-*`.

## Что Индексирует LightRAG

Default graph index включает короткие operational docs:

- `docs/rag-index/`;
- `docs/runbooks/`;
- `docs/research/` без `docs/research/raw/`;
- `docs/reports/` без runtime JSON reports.

Default graph index исключает тяжёлые source artifacts:

- `docs/superpowers/`;
- `docs/research/raw/`;
- secrets, `.env`, Infisical exports, database dumps, market-data blobs.

Большие specs и plans должны попадать в RAG через короткие summaries в
`docs/rag-index/summaries/`.

## Ключевые Decision Records

- [LightRAG Dev Memory](decisions/lightrag-dev-memory.md)
- [Docker Isolation](decisions/docker-isolation.md)
- [LLM Routing](decisions/llm-routing.md)
- [Rust Foundation](decisions/rust-foundation.md)

## Ключевые Summaries

- [Data Foundation Paper Replay Design](summaries/data-foundation-paper-replay-design.md)
- [Data Foundation Increment 1](summaries/data-foundation-increment-1.md)
- [LightRAG Dev Memory Deployment](summaries/lightrag-dev-memory-deployment.md)

## Обязательные Проверки Перед Доверием К Памяти

```powershell
.\scripts\liq-rag.ps1 status --check-commit -EnvFile infra/lightrag/.env
.\scripts\liq-rag.ps1 eval -EnvFile infra/lightrag/.env
.\scripts\liq-rag.ps1 health -EnvFile infra/lightrag/.env
.\scripts\audit-rag.ps1
```

Все четыре проверки должны проходить. Иначе RAG считается подсказкой, но не
рабочей памятью для принятия инженерных решений.
