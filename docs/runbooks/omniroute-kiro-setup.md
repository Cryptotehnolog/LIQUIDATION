# OmniRoute Kiro Setup (Deprecated)

## Назначение

Этот runbook сохранён как историческая заметка. OmniRoute больше не является
частью ApeRAG route проекта `LIQUIDATION`.

Текущая рабочая схема:

```text
ApeRAG completion -> liquidation-free-deepseek
ApeRAG embeddings -> liquidation-embedding
```

Не использовать этот runbook для текущего deployment.

## URL

Исторически использовался URL:

```text
http://127.0.0.1:21128/dashboard
```

Также работает базовый URL:

```text
http://127.0.0.1:21128
```

Он делает redirect на `/dashboard`.

## Что Настроить

Текущий default больше не связан с Kiro:

```dotenv
APERAG_PRIMARY_MODEL=deepseek-chat
APERAG_EMBEDDING_MODEL=sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2
```

## Проверка

Актуальная проверка:

```powershell
.\scripts\liq-aperag.ps1 health -EnvFile infra/aperag/.env
```

`liq-aperag health` должен вернуть JSON со статусом:

```text
status: ok
```

## Что Нельзя Делать

- Не менять второй project container `omniroute` на `127.0.0.1:20128`.
- Не возвращать OmniRoute в ApeRAG route без отдельного design decision.
- Не коммитить credentials, exports или `.env`.
- Не считать ApeRAG готовым к ingest, пока `liq-aperag health` не вернул
  `memory_status = ready-for-ingest`.

## Что Улучшить Или Автоматизировать

Ничего для текущего RAG route. Любая будущая автоматизация вокруг OmniRoute
требует отдельного design decision и не входит в active ApeRAG Dev Memory.
