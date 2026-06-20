# Decision: Rust Foundation

## Решение

Основной runtime проекта писать на Rust, а не на Python.

## Обоснование

Проект требует стабильного collector, нормализации данных, recorder, replay и
paper trading harness. Rust даёт сильные типы, контроль ошибок, async runtime и
хорошую дисциплину для финансового кода.

## MVP Foundation

- Rust workspace.
- Config validation.
- Connector traits.
- Bybit/Binance collectors как первые sources.
- Normalized canonical liquidation events.
- Durable recorder.
- Replay dry-run.
- Paper-only strategy harness.

## Запреты

- Никакой real trading до paper trading, replay validation и fee/slippage gates.
- Не смешивать collector foundation с dashboard и live execution в первом
  инкременте.
