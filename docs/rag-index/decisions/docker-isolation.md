# Decision: Docker Isolation

## Решение

Все Docker resources проекта `LIQUIDATION` должны использовать prefix
`liquidation-*` и отдельный compose project `liquidation`.

## Обоснование

На ноутбуке уже работает второй проект с контейнерами Omniroute, FreeDeepseek,
ApeRAG и Infisical. Главный operational risk - случайно остановить, удалить или
перенастроить этот проект.

## Правила

- Не выполнять unscoped `docker compose down`, `docker system prune`,
  `docker volume prune`, `docker network prune`.
- Не трогать контейнеры `omniroute`, `stat-arb-free-qwen`,
  `stat-arb-free-deepseek`, `aperag-*`, `stat-arb-infisical-*`.
- Перед deployment запускать `scripts/guard-compose.ps1`.
- `LIGHTRAG_HOST` должен быть `127.0.0.1` или `localhost`.
- Bind mounts должны оставаться внутри `infra/lightrag/data`.

## Последствия

Deployment становится чуть более многословным, зато риск сломать второй проект
снижается до контролируемого минимума.
