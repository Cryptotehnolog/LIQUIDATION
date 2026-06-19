# Research Before Implementation Runbook

Цель: перед implementation plan проверить быстро меняющиеся внешние assumptions.

## Что проверять

- Exchange API changes for liquidation streams.
- Polymarket market-data behavior.
- Hyperliquid fees, funding, execution details.
- Public reports about feed latency, outages, or schema changes.
- Current fee schedules and caveats.

## Где хранить результаты

Research notes сохраняются в:

```text
docs/research/
```

Формат имени:

```text
YYYY-MM-DD-topic.md
```

## Шаблон research note

```markdown
# Research: <topic>

Дата проверки: YYYY-MM-DD

## Вопрос

Что проверяли и почему это важно.

## Источники

- [source name](https://example.com) — дата доступа, краткое назначение.

## Выводы

- Короткие проверяемые выводы.

## Caveats

- Что осталось неизвестным или нестабильным.

## Влияние на дизайн

- Что меняем в spec/plan.
- Что не меняем и почему.
```

## Правила

- Research не заменяет official docs и fixtures.
- Если источник неофициальный, это должно быть явно отмечено.
- Если вывод влияет на risk, fee model или execution, он должен попасть в spec
  или ADR.
- Не использовать research как основание для real trading без paper validation.
