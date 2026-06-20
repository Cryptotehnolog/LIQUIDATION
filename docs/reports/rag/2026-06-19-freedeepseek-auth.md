# LIQUIDATION FreeDeepseek Auth - 2026-06-19

## Что Сделано

- Создана отдельная LIQUIDATION-owned DeepSeek Web session через интерактивный FreeDeepseekAPI auth flow.
- Auth file создан только в ignored зоне LIQUIDATION: `infra/lightrag/data/secrets/deepseek-auth.json`.
- Рабочая копия FreeDeepseekAPI для auth находится только в ignored зоне LIQUIDATION: `infra/lightrag/data/freedeepseek-auth-work`.
- Chrome profile для этой session находится только в ignored зоне LIQUIDATION: `infra/lightrag/data/chrome-profiles/freedeepseek-liq`.
- Второй проект и его FreeDeepseek auth не использовались.

## Verification

- `git check-ignore -v infra/lightrag/data/secrets/deepseek-auth.json`: passed.
- `npm run doctor -- --offline`: passed.
- Docker compose image/source validation: passed.
- Compose guard для `liquidation-*` names/networks/volumes: passed.
- `liquidation-free-deepseek`: running on `127.0.0.1:19655`.
- `GET /health`: `status=ok`, `config_ready=true`.
- `GET /v1/models`: returned supported DeepSeek Web aliases.
- `POST /v1/chat/completions` with `deepseek-chat`: returned `ok`.
- `scripts/liq-rag.ps1 health -EnvFile infra/lightrag/.env`: `ok`.

## Infisical Decision

- Auth опубликован в LIQUIDATION-owned Infisical project как `FREE_DEEPSEEK_AUTH_JSON`.
- Roundtrip verification passed: secret прочитан обратно во временный ignored file и прошёл `npm run doctor -- --offline`.
- Publish в Infisical должен требовать explicit LIQUIDATION project id.
- Implicit Infisical CLI context запрещён, потому что он может указывать на второй проект.
- Секрет должен публиковаться через file reference syntax, а не как JSON в CLI argument.

## Automation Added

- `scripts/create-freedeepseek-auth.ps1`: refresh auth, path guards, `doctor --offline`, optional smoke test.
- `scripts/publish-freedeepseek-auth-to-infisical.ps1`: dry-run и guarded publish с обязательным `-InfisicalProjectId`.
- `scripts/verify-infisical-roundtrip.ps1`: guarded readback из Infisical, `doctor --offline`, cleanup temp auth.
- `scripts/test-freedeepseek-auth-scripts.ps1`: regression tests для path guards, required project id и запрета передачи JSON secret через CLI arguments.

## Known Gaps

- Для полностью non-interactive automation позже нужен LIQUIDATION-owned machine identity token или service token.
- `FREE_DEEPSEEK_REF` закреплён на commit SHA перед production-like rebuild.

## Что Улучшить Или Автоматизировать

- Добавить scheduled health check для `liquidation-free-deepseek`, который пишет status в dashboard/reports.
