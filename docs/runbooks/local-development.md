# Local Development Runbook

## Цель

Локально проверять Rust foundation без real trading и без изменения Docker
контейнеров второго проекта.

## Проверки Rust

```powershell
cargo fmt --all --check
cargo clippy --workspace --all-targets -- -D clippy::correctness -D clippy::suspicious -D clippy::perf -D clippy::complexity -D clippy::style
cargo nextest run --workspace
cargo test --workspace --doc
cargo run -p liq-cli -- replay dry-run --source bybit --start-unix-ms 1 --end-unix-ms 2
```

На ноутбуке не запускать полный набор тяжёлых проверок без причины. `target/`
может разрастаться до нескольких GB, после чего Windows Defender начинает
сканировать build artifacts и CPU уходит в `MsMpEng`.

CPU diagnostics:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/diagnose-cpu.ps1
```

Если CPU грузит `MsMpEng`, лучшее локальное решение - добавить Defender
exclusion только для build artifacts, а не для всего repo:

```powershell
Add-MpPreference -ExclusionPath "D:\Liquidation\LIQUIDATION\target"
```

Команду нужно выполнять в PowerShell от администратора. Не исключать `docs/`,
`config/`, `.env`, `infra/` или весь `D:\Liquidation`: это снижает защиту от
случайно попавших secrets и вредных файлов.

Ожидаемый результат CLI:

```text
dry-run ok
```

## Security Gates

CI запускает:

- `cargo deny`;
- `gitleaks`.

Локальный запуск:

```powershell
cargo deny check advisories bans licenses sources
cargo audit
docker run --rm -v "${PWD}:/repo" zricethezav/gitleaks:v8.28.0 detect --source /repo --redact --verbose
```

`cargo audit` использует `.cargo/audit.toml` и игнорирует только
`RUSTSEC-2023-0071`: `cargo-audit` сканирует весь `Cargo.lock` и видит inactive
optional dependency `rsa` из `sqlx`, хотя active graph не содержит этот crate.
RustSec advisories для active graph дополнительно проверяет `cargo deny`.
Known duplicate transitive crates от `sqlx`, `tokio`, `tungstenite` и `clap`
зафиксированы точечным allowlist в `deny.toml`; новые duplicate crates всё ещё
будут видны в CI.

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

GitHub Actions также запускает disposable TimescaleDB service job и проверяет:

- migration idempotency;
- schema-domain alignment;
- recorder persistence roundtrip.

## Collector Live Probe

Перед постоянным collector runtime используйте только bounded probe:

```powershell
$env:DATABASE_URL="postgres://liquidation:liquidation@127.0.0.1:15433/liquidation"
cargo run -p liq-cli -- collector probe --source bybit --symbol BTCUSDT --max-messages 1 --read-timeout-seconds 30
cargo run -p liq-cli -- collector probe --source binance --symbol BTCUSDT --max-messages 1 --min-messages 0 --read-timeout-seconds 10
cargo run -p liq-cli -- collector probe --source okx --symbol BTC-USDT-SWAP --max-messages 1 --min-messages 0 --read-timeout-seconds 30
```

`normalized_events=0` в коротком probe не означает сбой: Bybit сначала присылает
subscription ack, а Binance `forceOrder` может молчать, если в окне проверки нет
ликвидаций. Для проверки обязательного события задавайте `--min-messages 1`, но
такая проверка может законно упасть по таймауту на спокойном рынке.

OKX в текущем инкременте raw-only diagnostic source. Он может писать
`raw_source_events`, но не пишет canonical `liquidation_events`, пока не добавлен
instrument metadata для корректного `notional_usd`.

Для OKX canonical probe используйте явный metadata cache:

```powershell
$env:DATABASE_URL="postgres://liquidation:liquidation@127.0.0.1:15433/liquidation"
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\fetch-okx-instruments.ps1 -Symbol BTC-USDT-SWAP -OutputPath .cache\okx\instruments-BTC-USDT-SWAP.json
cargo run -p liq-cli -- collector probe --source okx --symbol BTC-USDT-SWAP --okx-instruments-path .cache/okx/instruments-BTC-USDT-SWAP.json --max-messages 1 --min-messages 0 --read-timeout-seconds 30
```

Если `--okx-instruments-path` не задан, OKX остается raw-only. Это лучше, чем
тихо считать неверный `notional_usd`.

Если нужно проверить dashboard visibility для OKX, используйте bounded
`collector run`, а не только `collector probe`: `run` пишет `collector_health`
даже без liquidation event.

```powershell
$env:DATABASE_URL="postgres://liquidation:liquidation@127.0.0.1:15433/liquidation"
cargo run -p liq-cli -- collector run --source okx --symbol BTC-USDT-SWAP --okx-instruments-path .cache\okx\instruments-BTC-USDT-SWAP.json --max-runtime-seconds 15 --health-interval-seconds 3 --read-timeout-seconds 10 --batch-flush-interval-seconds 1
cargo run -p liq-cli -- collector status --source okx --json --window-minutes 60
```

Для bounded проверки long-running collector mode:

```powershell
$env:DATABASE_URL="postgres://liquidation:liquidation@127.0.0.1:15433/liquidation"
cargo run -p liq-cli -- collector run --source bybit --symbol BTCUSDT --max-runtime-seconds 5 --read-timeout-seconds 2 --health-interval-seconds 1 --batch-flush-interval-seconds 1 --batch-size 4
```

Команда должна завершиться сама и записать строки `collector_health`.

Для bounded проверки multi-source collector mode:

```powershell
$env:DATABASE_URL="postgres://liquidation:liquidation@127.0.0.1:15433/liquidation"
cargo run -p liq-cli -- collector run --source bybit --source binance --symbol BTCUSDT --max-runtime-seconds 5 --read-timeout-seconds 2 --health-interval-seconds 1 --batch-flush-interval-seconds 1 --batch-size 4
```

Для просмотра последних health rows без ручного `psql`:

```powershell
$env:DATABASE_URL="postgres://liquidation:liquidation@127.0.0.1:15433/liquidation"
cargo run -p liq-cli -- collector status --limit 10
cargo run -p liq-cli -- collector health --source bybit --limit 20
cargo run -p liq-cli -- collector status --json --window-minutes 60
```

`status=backpressure` означает, что bounded recorder channel оставался полным
дольше `--channel-send-timeout-seconds`. `status=circuit_open` означает, что
источник превысил reconnect budget за rolling 5 минут.

`collector status --json` предназначен для dashboard и alerting. Он отдаёт
агрегированный снимок:

- `sources[]`: состояние по `source`/`symbol`;
- `source_quality`, `coverage_role`, `participates_in_signals`: operational
  policy для dashboard source coverage;
- `freshness_ms`: возраст последнего raw payload, если он известен;
- `latency_bucket_*`: распределение последних latency samples в выбранном окне;
- `max_reconnects_5m`: reconnect trend внутри выбранного окна;
- `last_payload_ts` и `last_event_ts`: RFC3339 timestamps или `null`;
- `storage`: размер collector-facing таблиц и рост raw/canonical rows за окно.

Для фильтрации одного источника:

```powershell
$env:DATABASE_URL="postgres://liquidation:liquidation@127.0.0.1:15433/liquidation"
cargo run -p liq-cli -- collector status --source bybit --json --window-minutes 15
```

Для overlap validation между Bybit primary и OKX diagnostic:

```powershell
$env:DATABASE_URL="postgres://liquidation:liquidation@127.0.0.1:15433/liquidation"
cargo run -p liq-cli -- collector overlap-report --primary-source bybit --diagnostic-source okx --window-minutes 60 --bucket-seconds 60
```

Для bounded nightly-style diagnostics с artifacts:

```powershell
$env:DATABASE_URL="postgres://liquidation:liquidation@127.0.0.1:15433/liquidation"
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\run-market-data-nightly-check.ps1 -RuntimeSeconds 30 -HealthIntervalSeconds 5 -WindowMinutes 60
```

Отчёт сохраняет `collector-status.json`, `overlap-report.json`, `summary.md` и
`nightly-run.log` в `.cache/nightly-market-data/`.

Чтобы посмотреть тренд по нескольким сохранённым nightly artifacts:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/market-data-report-history.ps1 -InputRoot .cache/nightly-market-data
```

Trend report сохраняется в `.cache/market-data-report-history/`.

Dashboard history endpoint отдаёт trend samples из `collector_health` через
локальный HTTP server:

```text
http://127.0.0.1:18080/api/collector/history
```

Перед добавлением или изменением источника market data:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\check-source-addition.ps1
```

Для read-only dashboard skeleton:

```powershell
$env:DATABASE_URL="postgres://liquidation:liquidation@127.0.0.1:15433/liquidation"
cargo run -p liq-cli -- collector dashboard --bind 127.0.0.1:18080 --window-minutes 60 --poll-seconds 5
```

Для обычного operator-запуска используйте wrapper:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/start-dashboard.ps1
```

Он выбирает live mode при наличии `DATABASE_URL`; иначе запускает fixture mode,
чтобы dashboard можно было открыть без поднятой БД. Проверить выбранную команду
без запуска сервера:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/start-dashboard.ps1 -PrintCommandOnly
```

Smoke test dashboard edge states:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test-dashboard-smoke.ps1
```

После smoke test screenshots лежат в:

```text
.cache/dashboard-smoke/desktop.png
.cache/dashboard-smoke/mobile.png
```

## Heavy Tests

Heavy tests не запускаются на каждом push. Локально:

```powershell
$env:DATABASE_URL="postgres://liquidation:liquidation@127.0.0.1:15433/liquidation"
cargo test -p liq-recorder --test load -- --ignored --nocapture
cargo test -p liq-collector -- --ignored --nocapture
```

GitHub Actions запускает эти проверки в `Heavy CI` по расписанию и вручную через
`workflow_dispatch`.

## Docker Safety

Перед запуском инфраструктуры читать `docs/runbooks/docker-safety.md`.

Не выполнять:

```powershell
docker system prune
docker volume prune
docker compose down --remove-orphans
```

## Что Улучшить Или Автоматизировать

- Расширить scheduled heavy CI до multi-hour stability test, когда появится
  отдельный long-running fixture runner.
