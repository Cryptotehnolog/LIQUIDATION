# ApeRAG Dev Memory Full Audit

Дата: 2026-06-21

## Итог

ApeRAG Dev Memory пригоден для качественной разработки проекта LIQUIDATION.
Это не trading runtime memory и не источник торговых решений.

Текущий рабочий контур:

```text
ApeRAG completion -> liquidation-free-deepseek
ApeRAG embeddings -> liquidation-embedding
```

Текущий RAG route использует только project-owned ApeRAG services и не
переиспользует legacy memory или local embedding routes.

## Что Исправлено Во Время Аудита

- `liq-aperag eval` больше не принимает частичный успех как `ok`: все eval
  cases должны пройти.
- Eval dataset теперь поддерживает обязательные `expected_all` terms и явно
  показывает `missing_all_terms`.
- Eval использует top-5 retrieval gate и требует обязательные terms в одном
  concrete result/chunk.
- `liq-aperag ingest` теперь индексирует tracked и untracked-but-not-ignored
  docs через `git ls-files --cached --others --exclude-standard`.
- Добавлены short retrieval anchors в `docs/runbooks/aperag-dev-memory.md` для
  paper-only, archive verification, canonical deletion и fee model.
- `paper-only` rule добавлен в `docs/runbooks/fee-model.md`, чтобы real trading
  gate находился по естественному запросу.
- После swarm audit eval ужесточён до top-5, `expected_source`, проверки terms
  в одном result/chunk и freshness/drift preflight перед eval.
- Default Dev Memory collection исключает raw research, query plans и JSON
  status files; они остаются audit trail в repo, но не default retrieval source.
- `guard-compose.ps1` проверяет Docker `secrets.file`, чтобы ignored `.env` не
  мог смонтировать auth-файл второго проекта.
- `check-images.ps1` получил fallback на `git -c http.sslBackend=openssl`, если
  Windows Schannel ломает `git ls-remote`.

## Проверки

Свежие команды аудита:

```powershell
.\scripts\liq-aperag.ps1 ingest docs/ -EnvFile infra/aperag/.env
.\scripts\liq-aperag.ps1 eval -EnvFile infra/aperag/.env
.\scripts\liq-aperag.ps1 status docs/ -EnvFile infra/aperag/.env -CheckCommit -CheckDrift
.\scripts\audit-aperag.ps1 -EnvFile infra/aperag/.env
.\scripts\audit-aperag.ps1 -EnvFile infra/aperag/.env.example
.\scripts\guard-compose.ps1 -EnvFile infra/aperag/.env.example
.\scripts\check-images.ps1 -EnvFile infra/aperag/.env.example
.\scripts\test-aperag-dev-memory.ps1
.\scripts\test-freedeepseek-auth-scripts.ps1
git diff --check
```

Результаты:

- ingest: 24 documents, all `COMPLETE`, vector/fulltext indexes `ACTIVE`;
- status: commit hash matches, docs tree hash matches, drift status `ok`;
- eval: 6/6, score `1`;
- compose guard: only `liquidation-*` services, containers, networks and
  volumes;
- PowerShell parse: 13 scripts parsed successfully;
- patched ApeRAG reconciler present in API and worker containers;
- ignored runtime files are not tracked by Git;
- no hard secret/token pattern found in tracked project files. Matches are
  variable names, redaction regexes, runbook commands or test fixtures.
- swarm audit: P0 не найдено; подтверждённые P1/P2 findings исправлены или
  отмечены как residual workflow issue.

## Residual Risks

- `check-images.ps1` can be rate-limited by registries. Default local mode
  reports registry rate limits as warnings; `-StrictRemoteManifests` should be
  used before deployment windows where remote manifest verification is required.
- Raw research notes can reduce rank quality. Default Dev Memory now excludes
  raw research plans/JSON from the main collection; a separate archive
  collection can be added later.
- `git add --renormalize .` requires a clean deletion state. In the current
  large migration, deleted legacy files should be staged/committed or restored
  before running whole-tree renormalization again.
- Current memory is suitable for development continuity, not for automated
  trading decisions.

## Следующее Улучшение

- Add scheduled `audit-aperag` report.
- Add dashboard status panel for collection freshness, drift and eval score.
- Add CI job for scripts syntax, compose guard and secret scan.
