# Fee Model Runbook

Цель: не принимать решения о real trading на основании paper PnL без fees и
execution costs.

## MVP venues

Первый fee model покрывает:

- Polymarket;
- Hyperliquid.

Другие venues добавляются позже, когда появятся в strategy execution path.

## Что считать отдельно

Replay report должен показывать:

- gross PnL;
- Polymarket fees или explicit zero-fee assumption;
- Hyperliquid maker/taker fees;
- slippage;
- funding или holding costs, если применимо;
- failed hedge penalty;
- partial hedge penalty;
- timeout penalty;
- net PnL.

## Версионирование

Каждый fee schedule должен иметь:

- `fee_schedule_version`;
- дату проверки;
- source link;
- caveats;
- список affected venues.

`replay_runs` должен записывать `fee_schedule_version`.

## Gate для real trading

Real trading запрещен, пока:

- net PnL после fees не стабилен в replay;
- paper-live не показывает приемлемый net PnL;
- slippage и failed hedge penalties не учтены;
- fee assumptions не подтверждены свежими источниками.

## Проверки

Перед релизом fee model:

- unit tests для расчёта fees;
- regression fixtures для replay reports;
- отдельный тест, где gross PnL положительный, но net PnL отрицательный;
- проверка, что отчёт не скрывает fees внутри одной итоговой строки.
