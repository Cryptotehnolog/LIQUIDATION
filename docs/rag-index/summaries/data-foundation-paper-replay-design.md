# Summary: Data Foundation Paper Replay Design

Source documents:

- `docs/superpowers/specs/2026-06-19-data-foundation-paper-replay-design.md`
- `docs/superpowers/specs/2026-06-19-data-foundation-paper-replay-design-ru.md`

## Суть

Стратегия строится вокруг статистического арбитража между liquidation cascades
на futures venues и prediction markets. MVP не торгует реальными деньгами:
сначала collector, recorder, quality reports и paper replay.

## Data Foundation

- Собственный liquidation aggregator вместо зависимости от Moon Dev API.
- Source-specific adapters: Binance как snapshot-only diagnostic, Bybit как
  primary candidate, OKX/Hyperliquid позже.
- Canonical liquidation events должны всегда иметь `notional_usd`; если цена
  или quantity не позволяют рассчитать notional, событие invalid для strategy.
- Raw payload хранится горячим ограниченно и архивируется отдельно.

## Replay And Paper Trading

- Replay должен быть deterministic.
- Strategy должна быть plugin-like через trait/interface.
- Fill models: conservative `trade_cross` и optimistic `book_touch`; depth
  model только после надёжного L2 data.
- Нужны fee/slippage/funding/timeout assumptions для Polymarket и Hyperliquid.

## RAG И Агенты

RAG является development memory, не source of truth. Agents allowed только как
read-only audit, без write/autopilot прав.

## Критичные Gates

- Paper trading до real trading.
- Data-quality reports before strategy confidence.
- CI, migration checks, cargo audit/deny follow-up.
- Docker/secret isolation.
