# Deferred Ideas Backlog

Цель: хранить все решения формата "не делаем сейчас, но не забыть" вне чата.
Если идея отложена, она должна попасть сюда или в более конкретный runbook с
ссылкой из этого файла.

## Правило

Нельзя оставлять postponed/parking-lot идеи только в чате. Для каждой идеи нужно
записать:

- что именно отложено;
- почему сейчас не делаем;
- когда возвращаемся;
- что будет считаться готовностью начать;
- связанный runbook/spec.

## Backlog

### GitHub Artifact Trend Comparator

**Статус:** deferred.

**Что это:** сравнение nightly GitHub Actions artifacts между датами, чтобы
видеть тренд качества источников: OKX usefulness, stale/ok status, raw/canonical
events, overlap buckets, metadata validity, API docs changelog warnings.

**Почему не сейчас:** это полезный reliability/ops слой, но он не блокирует
переход к pre-strategy increment. Сейчас главный bottleneck - отсутствие
Polymarket market-data recorder, Hyperliquid hedge/paper model, fee/funding
model и deterministic replay harness.

**Когда возвращаемся:**

- после минимального Polymarket recorder, Hyperliquid paper hedge model и replay
  foundation;
- раньше, если nightly market-data diagnostics или API docs changelog начинают
  регулярно давать warnings;
- обязательно перед длительным paper soak, потому что там нужен trend across
  days, а не только последний snapshot.

**Готовность начать:**

- есть несколько nightly artifacts в GitHub Actions;
- `scripts/market-data-report-history.ps1` стабильно строит локальный trend;
- `scripts/gh-project.ps1` умеет читать runs/artifacts через project-local GitHub
  auth.

**Ожидаемый результат:**

- `scripts/market-data-report-history-from-github.ps1` или аналогичный wrapper;
- краткий Markdown/JSON report по нескольким GitHub artifact runs;
- warning, если OKX/source coverage ухудшается;
- dashboard/future alerting могут читать JSON без парсинга Markdown.

**Связанные файлы:**

- `docs/runbooks/strategy-readiness.md`
- `docs/runbooks/source-addition.md`
- `scripts/market-data-report-history.ps1`
- `.github/workflows/nightly-market-data.yml`

### Replay From Archive

**Статус:** deferred.

**Что это:** режим replay, который читает Parquet archives напрямую, минуя hot
TimescaleDB.

**Почему не сейчас:** сначала нужен минимальный deterministic replay over hot
data. Archive replay важен для глубоких backtests, но не блокирует первый
strategy replay.

**Когда возвращаемся:** после появления archive export/verification и первого
рабочего replay harness.

**Связанные файлы:**

- `docs/superpowers/specs/2026-06-19-data-foundation-paper-replay-design.md`
- `docs/runbooks/rag-operations.md`

### Extra Diagnostic Exchanges After OKX

**Статус:** deferred.

**Что это:** добавление новых diagnostic liquidation sources сверх Bybit,
Binance и OKX.

**Почему не сейчас:** текущий bottleneck не в количестве liquidation sources, а
в отсутствии второй стороны стратегии: Polymarket data, Hyperliquid hedge model,
fees/funding и replay.

**Когда возвращаемся:** после strategy replay foundation или если current source
coverage деградирует по nightly diagnostics.

**Связанные файлы:**

- `docs/runbooks/source-addition.md`
- `docs/runbooks/strategy-readiness.md`

## Что улучшить или автоматизировать

Добавить guard, который ищет слова `later`, `deferred`, `postponed`, `nice to
have`, `parking lot` в docs и требует ссылку на этот backlog или явный reason в
том же файле.
