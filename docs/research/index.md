# Research Index

Дата проверки: 2026-06-19.

Цель research: найти свежую информацию, которая усиливает разработку
`LIQUIDATION` до implementation plan.

## Метод

Использован `last30days` как community/risk-signal layer. Доступные источники в
текущей Codex-среде:

- Reddit;
- Hacker News;
- Polymarket;
- GitHub;
- grounding.

Недоступны без дополнительной настройки:

- X/Twitter;
- YouTube;
- TikTok;
- Instagram.

Вывод: `last30days` полезен для свежих жалоб, GitHub activity и community
signals, но official docs остаются source of truth для API, fees и endpoint
semantics.

## Research notes

- [exchange-liquidation-feeds.md](exchange-liquidation-feeds.md)
- [polymarket-market-data-and-fees.md](polymarket-market-data-and-fees.md)
- [hyperliquid-execution-fees.md](hyperliquid-execution-fees.md)
- [rag-stack-risk-review.md](rag-stack-risk-review.md)
- [rust-data-stack.md](rust-data-stack.md)

Raw `last30days` outputs сохранены в [raw/](raw/). Query plans сохранены в
[plans/](plans/).

## Decisions changed

- OKX REST liquidation backfill больше не считается verified candidate.
  Official OKX changelog указывает, что REST endpoint был delisted; для real-time
  liquidation orders нужно использовать WebSocket channel.
- Binance liquidation stream остается diagnostic snapshot-only source, потому
  что official docs говорят, что публикуется только крупнейшая или последняя
  liquidation order в 1000 ms window.
- Polymarket fill model должен опираться на recorded WebSocket market channel,
  trades и orderbook snapshots; для fees нельзя hardcode zero-fee assumption.
- Hyperliquid hedge model должен учитывать fees, funding и ограниченную depth
  видимость L2 book.
- RAG deployment должен иметь health/eval/freshness/drift gates. Текущая схема:
  ApeRAG completion через `liquidation-free-deepseek`, embeddings через
  `liquidation-embedding`; OmniRoute больше не является частью ApeRAG route.

## Что улучшить или автоматизировать

- Добавить `docs/research/status.json` с датой проверки, source coverage и
  sections, которые были обновлены после research.
- Добавить scheduled research refresh перед каждым крупным implementation plan.
- Подключить X/Twitter или X API только если понадобится более сильный
  incident-signal layer.
