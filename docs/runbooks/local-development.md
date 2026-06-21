# Local Development Runbook

## Цель

Локально проверять Rust foundation без real trading и без изменения Docker
контейнеров второго проекта.

## Проверки Rust

```powershell
cargo fmt --all --check
cargo clippy --workspace --all-targets -- -D clippy::correctness -D clippy::suspicious -D clippy::perf -D clippy::complexity -D clippy::style
cargo test --workspace
cargo run -p liq-cli -- replay dry-run --source bybit --start-unix-ms 1 --end-unix-ms 2
```

Ожидаемый результат CLI:

```text
dry-run ok
```

## Recorder Persistence Checks

Для проверки migrations и schema contract используется отдельный project-owned
TimescaleDB stack. Он использует только `liquidation-*` имена и loopback port
`127.0.0.1:15433`.

Конфигурация TimescaleDB использует только project-scoped переменные
`LIQUIDATION_POSTGRES_*`. Не использовать generic `POSTGRES_*`: они могут быть
заданы другим проектом или глобальной сессией PowerShell и silently изменить
пароль/имя БД.

Проверка без запуска контейнера, если он уже работает:

```powershell
.\scripts\test-recorder-persistence.ps1
```

Проверка только Docker Compose guard без подключения к БД:

```powershell
.\scripts\test-recorder-persistence.ps1 -ConfigOnly
```

Первый запуск с поднятием project-owned TimescaleDB:

```powershell
.\scripts\test-recorder-persistence.ps1 -Start
```

Если Docker Hub вернул `toomanyrequests` / pull-rate-limit, это не ошибка
проекта. Нормальное решение - выполнить `docker login` в Docker Desktop/CLI,
чтобы pull шёл как authenticated request. Не менять image на случайные mirror и
не добавлять retries как основной способ обхода.

Проверка Docker Hub auth и pull образа TimescaleDB:

```powershell
.\scripts\check-docker-hub.ps1 -Pull
```

Если проверка пишет, что Docker Hub не авторизован, выполнить:

```powershell
docker login
```

После успешного login повторить `.\scripts\check-docker-hub.ps1 -Pull`.
Скрипт должен fail-fast и не ждать несуществующий контейнер.

Команда выполняет:

- `docker compose config` guard для `liquidation-*` names;
- `liq db migrate` два раза подряд для idempotency;
- `liq db check-schema` для schema-domain alignment.
- insert roundtrip integration test можно запустить отдельно, если
  `DATABASE_URL` указывает на TimescaleDB:

```powershell
$env:DATABASE_URL="postgres://liquidation:liquidation@127.0.0.1:15433/liquidation"
cargo test -p liq-recorder --test persistence
```

## Docker Safety

Перед запуском инфраструктуры читать `docs/runbooks/docker-safety.md`.

Не выполнять:

```powershell
docker system prune
docker volume prune
docker compose down --remove-orphans
```

## Что Улучшить Или Автоматизировать

- Добавить `cargo nextest`.
- Добавить `cargo audit`.
- Добавить `cargo deny` с узкими license/advisory правилами.
- Добавить `gitleaks`.
- Добавить CI service job для disposable TimescaleDB, когда registry pull будет
  стабильным.
- Добавить weekly long-running load test после появления collector runtime.
