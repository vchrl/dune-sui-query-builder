# Changelog

All notable changes to this skill will be documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [0.1.0] — 2026-05-14

Initial public release.

### Included
- `SKILL.md` — task router with four modes (Build / Debug / Optimize / Investigate), LiveFetch and Pyth Hermes core patterns, response format templates, uncertainty handling
- `references/sui-data-model.md` — Dune Sui table catalog (`sui.events`, `sui.objects`, `sui.move_call`, `sui.transactions`), 8 Sui-specific edge cases, full LiveFetch documentation, Pyth Hermes integration, 8 anti-patterns from production dashboards
- `references/protocol-patterns.md` — Navi 3-package archaeology, Suilend `ReserveAssetDataEvent` schema, the V8 4-stage dynamic pipeline with annotated SQL, comparative Suilend vs Navi analysis, useful public Dune query references
- `examples/navi-v8-pipeline.sql` — production SQL extracted standalone for copy-paste use

### Validated through
- The [Sui Lending: Navi vs Suilend dashboard](https://dune.com/0x_vcharles/sui-lending-navi-vs-suilend) — 15 visualizations across both protocols, 100% on-chain pipeline
- The mementomori7777 mislabel investigation (the most-cited "Navi" dashboard on Dune is actually querying Suilend's package)
- Cross-validation of Navi-9 normalization, Ray-encoded rates, `prices.hour` double-hex encoding, Sui address normalization edge cases

### Known limitations
- Only Navi and Suilend deeply mapped — other Sui protocols (Cetus, Bluefin, Scallop, Aftermath, DeepBook, Volo, Haedal) listed as triggers but not yet documented with schemas
- Liquidation event paths for Navi flagged in the skill but not yet sampled
- Pyth feed IDs verified April 2026 — recommend verification before production use
- Some `event_json` field paths are best-guesses from SDK code, flagged with uncertainty disclaimers
- Historical Navi TVL path documented but not implemented (`sui_tryGetPastObject` snapshots)
- No automated eval suite yet

---

## Roadmap

### [0.2.0] — planned
- **Audit emerging Sui curated tables** — `dex_sui.trades`, `sui_walrus.*`, `sui_daily.*`, `sui_tvl.*`. Document schemas, coverage, freshness, and integration patterns with raw `sui.events` work.
- **Pure-Pyth pricing** replacing the `prices.hour` + Pyth hybrid for the Navi pipeline (discover feed IDs from Navi's on-chain oracle registry, batch in one Hermes call, add confidence intervals + EMA prices)
- **Historical Navi TVL** via `sui_tryGetPastObject` — date → checkpoint → object version mapping
- **Cetus protocol patterns** — concentrated liquidity DEX schemas
- **Bluefin protocol patterns** — perpetuals + orderbook
- **Automated eval suite** — corpus of prompts + expected behaviors

### Future
- Additional protocols: Scallop, DeepBook, Aftermath, Volo, Haedal
- Walrus and Seal patterns if Mysten ecosystem analytics use cases emerge
- Generalized "discover all events emitted by a package" workflow as a documented sub-skill
- Migration guide if Dune introduces decoded protocol tables for Sui
