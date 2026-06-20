# Decision: LLM Routing

## Решение

Primary route для LightRAG:

```text
LightRAG -> liquidation-omniroute -> Kiro combo
```

Emergency diagnostic route:

```text
liq-rag -> liquidation-free-deepseek
```

## Обоснование

Omniroute даёт routing и Kiro combo. FreeDeepseek полезен как резерв, но зависит
от DeepSeek Web behavior и auth state. Поэтому его нельзя считать равным
primary route без отдельной failover реализации и eval.

## Health Semantics

- `ok`: Omniroute, Kiro combo, LightRAG, embeddings, freshness и eval работают.
- `failed`: любой обязательный gate сломан.
- `fallback_available = true`: FreeDeepseek отвечает напрямую, но это
  diagnostic-only.

## Последствия

RAG не будет ложно показывать usable status только потому, что FreeDeepseek
живой. Это строже, но честнее для проекта, связанного с торговлей.
