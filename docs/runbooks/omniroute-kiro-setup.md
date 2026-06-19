# OmniRoute Kiro Setup

## Назначение

Этот runbook описывает ручной вход в project-owned `liquidation-omniroute` и критерии готовности primary LLM route для LightRAG.

## URL

Открыть в браузере:

```text
http://127.0.0.1:21128/dashboard
```

Также работает базовый URL:

```text
http://127.0.0.1:21128
```

Он делает redirect на `/dashboard`.

## Что Настроить

В `liquidation-omniroute` нужно подключить provider Kiro AI и создать combo/model, который совпадает с `LIGHTRAG_LLM_MODEL` в ignored `infra/lightrag/.env`.

Текущий default:

```dotenv
LIGHTRAG_LLM_MODEL=my-ai
KIRO_PROVIDER_NAME=kiro
KIRO_COMBO_NAME=my-ai
```

Если в OmniRoute создается combo с другим именем, обновить `LIGHTRAG_LLM_MODEL` и `KIRO_COMBO_NAME` только в ignored `infra/lightrag/.env`.

## Проверка

После настройки provider/combo:

```powershell
Invoke-WebRequest http://127.0.0.1:21128/v1/models -UseBasicParsing
.\scripts\liq-rag.ps1 health -EnvFile infra/lightrag/.env
```

`liq-rag health` должен вернуть:

```text
ok: health report written: docs\reports\rag\health-report.json
```

Если `/v1/models` отвечает `200`, но `configured_model_present=false`, значит OmniRoute работает, но LightRAG model name не совпадает с созданным combo.

## Что Нельзя Делать

- Не менять второй project container `omniroute` на `127.0.0.1:20128`.
- Не копировать provider credentials из второго проекта без явного решения.
- Не коммитить credentials, exports или `.env`.
- Не считать LightRAG готовым к ingest, пока `liq-rag health` не вернул `ok` и embedding config не заполнен.

## Что Улучшить Или Автоматизировать

- Добавить `scripts/check-omniroute-model.ps1`, если OmniRoute UI/API стабильно позволяет получать combo details.
- Добавить dashboard tile, показывающий configured model и `configured_model_present`.
