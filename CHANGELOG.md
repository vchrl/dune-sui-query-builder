# Changelog

All notable changes to this skill will be documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [0.1.2] — 2026-05-14

Filename clarity: rename `references/sui-dex-patterns.md` → `references/sui-curated-tables.md`. Content unchanged.

### Changed
- Renamed `references/sui-dex-patterns.md` → `references/sui-curated-tables.md`. The file documents 5 curated Sui spell tables (`dex_sui.trades`, `sui_tvl.btc_ecosystem`, `sui_daily.stats`, `sui_walrus.base_table`, `cex.addresses`) — only one of which is DEX. The original filename implied DEX-only scope, which was misleading (Walrus inside a file named `dex-patterns` is confusing).
- Updated 5 internal cross-references: README.md file tree, SKILL.md opening guidance + Build mode routing, `references/sui-data-model.md` cross-reference, and 2 mentions in this changelog's v0.1.1 entry.

---

## [0.1.1] — 2026-05-14

DEX coverage and curated-table audit, with spellbook source review.

### Added
- `references/sui-curated-tables.md` (renamed from `sui-dex-patterns.md` in v0.1.2) — new reference covering the 5 curated Sui spell tables (`dex_sui.trades`, `sui_tvl.btc_ecosystem`, `sui_daily.stats`, `sui_walrus.base_table`, `cex.addresses`), plus the `sui_tvl.*_gold` intermediates
- Schema for `dex_sui.trades` (28 columns) and full project list (9 DEXs since Sui mainnet launch)
- Schema for `sui_tvl.btc_ecosystem` (29 columns)
- **Verified schema for `sui_tvl.lending_pools_gold` via probe query**: 10 columns, all BTC-denominated
- **Spellbook source review**: 5 lending protocols are decoded in bronze tables (navi, suilend, scallop, bucket, alphalend) but only the BTC slice is published as a gold table
- Decision tree (mermaid): when to use curated spell tables vs. raw `sui.events`
- 4 worked example queries — DEX volume by project, DEX vs lending TVL split, top pairs, daily PTB/zkLogin activity
- Cross-references to `@insights4vc` and `@seoul` reference dashboards

### Changed
- README hook reframed: now leads with what *does* exist for Sui (5 spell tables), then explains where raw events are still required
- README "How this fits with Dune's tooling" table expanded — 7 domains with explicit verified coverage status; Sui lending row now reflects partial BTC-only coverage rather than "none"
- README V0.1 limitations updated: precise wording around BTC-only gold layer + bronze tables existing
- SKILL.md routing: DEX/BTCfi/Walrus/chain-stats queries now route to `sui-curated-tables.md` first (renamed from `sui-dex-patterns.md` in v0.1.2)
- `sui-data-model.md` opening: documents all 5 curated tables explicitly instead of scoping vaguely

### Investigation
- Verified via Dune MCP `searchTables`, `executeQueryById`, `getDuneQuery`, `createDuneQuery` probe on 2026-05-14
- Cross-validated against [@insights4vc/tradingdexgeneralsui](https://dune.com/insights4vc/tradingdexgeneralsui) and [@insights4vc/btcfi-protocol-level](https://dune.com/insights4vc/btcfi-protocol-level) reference dashboards
- Reviewed [duneanalytics/spellbook Sui models](https://github.com/duneanalytics/spellbook/tree/main/dbt_subprojects/daily_spellbook/models/sui) to verify bronze/silver/gold layering

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
