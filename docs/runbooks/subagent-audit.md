# Subagent Audit Runbook

## Цель

Subagents в `LIQUIDATION` используются только для независимого read-only audit.
Они не являются управляющей системой, не имеют autopilot-прав и не принимают
финальные engineering decisions.

Основной цикл:

```text
audit -> Codex implementation -> tests -> review -> commit
```

## Разрешенные роли

- Architecture audit.
- Rust safety audit.
- Test coverage audit.
- Docker/secrets safety audit.
- Spec/implementation consistency audit.
- Research freshness audit.

## Что можно читать

Subagent может читать:

- `docs/superpowers/specs/`;
- `docs/superpowers/plans/`;
- `docs/runbooks/`;
- `docs/research/`;
- source files текущего task;
- test files текущего task;
- Git diff текущей ветки.

## Что нельзя делать

Subagent не должен:

- изменять файлы;
- запускать destructive Docker commands;
- менять Git history;
- пушить в GitHub;
- менять secrets, Infisical, `.env`, credentials;
- подключаться к чужим Docker networks;
- принимать решение о real trading;
- менять risk limits;
- запускать real orders;
- использовать MCP/write/autopilot права.

## Audit prompts

### Architecture audit

```text
Ты read-only architecture auditor. Проверь diff и план на нарушение границ:
модули, ownership, source-specific semantics, скрытые dependencies,
over-abstraction, пропущенные failure modes. Не предлагай code edits без
file/line references. Верни findings по severity.
```

### Rust safety audit

```text
Ты read-only Rust safety auditor. Проверь Rust diff на ownership, async,
error handling, decimal/money precision, unwrap/expect, lock across await,
stringly-typed APIs и clippy risks. Не меняй файлы. Верни findings с
file/line references.
```

### Test coverage audit

```text
Ты read-only test coverage auditor. Проверь, что tests покрывают source-specific
normalization, invalid configs, deterministic ids, replay dry-run failure modes
и migration contracts. Найди missing tests и explain risk.
```

### Docker/secrets safety audit

```text
Ты read-only Docker/secrets auditor. Проверь, что commands, compose files,
env examples и runbooks не могут задеть чужие containers/networks/volumes и не
утекают secrets. Любой finding должен ссылаться на конкретную строку.
```

### Spec consistency audit

```text
Ты read-only spec consistency auditor. Сравни implementation diff с specs,
runbooks и research decisions. Найди противоречия, hidden defaults и decisions,
которые не отражены в docs.
```

## Как Codex проверяет audit

Codex обязан:

1. Проверить каждый finding по файлу и строке.
2. Отбросить findings без конкретного evidence.
3. Исправлять только подтвержденные issues.
4. После исправления запускать relevant tests.
5. Перед commit запускать verification commands.
6. В final summary отделять fixed findings от rejected findings.

## Blockers перед commit

Commit запрещен, если найдено:

- real trading path без paper-only guard;
- secret или token в repo;
- Docker command, способная затронуть чужой project;
- source-quality semantics потеряны при normalization;
- OKX REST backfill снова включен без нового research;
- Binance snapshot-only используется как production signal source;
- money/fee/notional calculation использует float;
- `unwrap()` или `expect()` на recoverable runtime path;
- test failure;
- spec contradiction без documented decision.

## Что улучшить или автоматизировать

- Добавить reusable audit prompt files в `docs/runbooks/audit-prompts/`.
- Добавить checklist в PR template.
- Добавить CI job, который проверяет запрещенные Docker commands и secrets.
- Добавить command `liq audit prepare`, который собирает diff и relevant docs
  для read-only subagent review.
