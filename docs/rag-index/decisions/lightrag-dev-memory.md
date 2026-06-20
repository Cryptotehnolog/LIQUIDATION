# Decision: LightRAG Dev Memory

## Решение

Использовать LightRAG как локальную development memory поверх repository docs,
но не как source of truth.

## Обоснование

LightRAG полезен для semantic retrieval, но его graph indexing тяжёлый: он
делает LLM extraction сущностей и связей. Поэтому нельзя индексировать весь
репозиторий как dump. Индекс должен получать curated memory layer и короткие
operational docs.

## Правила

- Git docs authoritative.
- LightRAG index disposable и пересобираемый.
- `docs/rag-index/` является главным curated memory layer.
- `docs/superpowers/` не индексируется напрямую.
- `docs/research/raw/` не индексируется напрямую.
- Большие docs получают summaries в `docs/rag-index/summaries/`.
- RAG usable только когда `status`, `eval`, `health` и `audit-rag` проходят.

## Последствия

Память становится быстрее и стабильнее, но требует дисциплины: после крупных
изменений нужно обновлять summary/decision, а не надеяться, что LightRAG
переварит огромный plan file.
