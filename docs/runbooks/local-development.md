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
- Добавить disposable TimescaleDB migration test.
- Добавить weekly long-running load test после появления collector runtime.
