# Docker Safety Runbook

Цель: запускать инфраструктуру проекта `LIQUIDATION`, не ломая Docker-контейнеры
других проектов.

## Чужие контейнеры

Считать неприкосновенными:

- `omniroute`;
- `stat-arb-free-qwen`;
- `stat-arb-free-deepseek`;
- legacy `free_deepseek` stacks второго проекта;
- все `aperag-*`;
- все `stat-arb-infisical-*`.

Не останавливать, не удалять, не переименовывать и не подключать к их networks
без отдельного решения.

## Обязательный prefix

Для этого проекта использовать:

```powershell
docker compose -p liquidation ...
```

Все project-owned containers, networks и volumes должны иметь prefix
`liquidation`.

## Безопасные read-only команды

```powershell
docker ps
docker ps --format "{{.Names}} {{.Image}} {{.Status}} {{.Ports}}"
docker compose -p liquidation ps
docker volume ls
docker network ls
```

## Запрещено без отдельного решения

```powershell
docker system prune
docker volume prune
docker network prune
docker compose down --remove-orphans
docker rm -f <чужой-контейнер>
docker volume rm <чужой-volume>
docker network rm <чужая-network>
```

Если нужен `down`, команда должна быть scoped:

```powershell
docker compose -p liquidation down
```

`--remove-orphans` использовать только после проверки, что orphan containers
принадлежат project name `liquidation`.

## Проверка портов

Перед добавлением сервиса проверить занятые порты:

```powershell
docker ps --format "{{.Names}} {{.Ports}}"
netstat -ano | findstr LISTENING
```

Новые порты проекта должны быть явно записаны в `compose` и не конфликтовать с:

- `13000`, `18000`, `15555`, `19200`, `16379`, `15432`, `16333`;
- `8080`;
- `20128`, `3264`, `9655`.

## Перед запуском нового compose

1. Проверить `docker ps`.
2. Проверить, что команда содержит `-p liquidation`.
3. Проверить, что volumes и networks имеют prefix `liquidation`.
4. Проверить, что нет destructive flags.

## После запуска

```powershell
docker compose -p liquidation ps
docker ps --format "{{.Names}} {{.Status}} {{.Ports}}"
```

Если появились контейнеры без prefix `liquidation`, остановиться и разобраться
до продолжения.
