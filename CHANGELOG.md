# Changelog

All notable changes to this skill will be documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [0.4.0] - 2026-06-21

Suilend protocol pack, share-token pricing as a general rule, a materialized-view serving layer, `dex_sui.trades` as the long-tail price source, and a verification toolkit.

### Added
- **Suilend protocol pack** (`references/protocol-patterns.md`): multi-market identity with `reserve_id` as the join key, the `event_json` conventions, the liquidation / obligation / forgive event catalog, protocol-native USD pricing including the cToken-vs-underlying distinction (the correctness core), the wrapped-token symbol map, the raw `deposited_value_usd` outlier gotcha (~$21.2B), and the IKA bad-debt episode (the only `ForgiveEvent` in Suilend history) as a worked case study.
- **Two Suilend example queries**: `examples/suilend-liquidations-priced.sql` (Dune query 7756564, the materialized-view source, 98,081 liquidations from 2024-03-13) and `examples/suilend-ika-bad-debt.sql` (Dune query 7757951).
- **Share-token vs underlying pricing** as a cross-protocol rule: Suilend cTokens via `supply_amount_usd_estimate / ctoken_supply`, Navi supply-index via `(raw/1e9) × (index/1e27)`.
- **`dex_sui.trades` as the long-tail Sui price source** (`references/sui-curated-tables.md`): daily VWAP recipe with address-LIKE matching on both side-address columns.
- **Materialized-view serving-layer pattern** (`references/sui-data-model.md`): one priced pass feeds a `result_*` matview, with honest tier (medium), cost (~117 credits), and refresh notes, plus the `createMaterializedView` gate.
- **Verification toolkit** (`references/verification-toolkit.md`, new file): raw-events recount (98,081 / 15,710 / 204, zero diff), stablecoin face-value cross-check (~0.05%), and the price-independent cToken penalty ratio (~6% realized versus the ~1.2 all-time USD ratio).
- **Pricing decision tree for Sui** (`references/sui-data-model.md`): protocol-emitted USD, then `dex_sui.trades` VWAP, then Pyth, with the `prices.*` coverage caveat.
- **Dashboard companion note** (README): generic Dune dashboard mechanics routed to Dune's official skill; the Suiscan `get_href` helper kept in the skill.

### Changed
- **Anti-patterns expanded** (`references/sui-data-model.md`): five new entries (share-tokens-as-underlying, seized/repaid as penalty, assuming `prices.*` covers Sui, `query_<id>` as cache, `searchTables` enumeration) plus a dedup block pointing at the already-documented items.
- **Pricing guidance now leads with protocol-emitted USD and `dex_sui.trades`** for Sui, across `SKILL.md` and `references/sui-data-model.md`.
- **README**: status badge to v0.4.0; "What's new in V0.4" section; file tree and proof-of-value updated for the Suilend pack and the fourth reference file.

### Notes
- Eval suite and additional protocol coverage deferred to [0.5.0].

## [0.3.1] — 2026-06-17

Docs reconciliation for the V0.3 release — no query/runtime changes.

### Changed
- **README:** status badge → v0.3.1; the Architecture mermaid rebuilt for the multi-market V9 flow (market discovery → 48 reserves → Stage 4 = Navi on-chain `PriceOracle`, not Pyth Hermes); the "Which Dune source" decision tree gains the protocol on-chain-oracle pricing path; proof-of-value + file tree updated; added a "What's new in V0.3" section.
- `references/protocol-patterns.md`: forward-pointer from the V8 pipeline section to the V9 multi-market + oracle subsections; reserve-count notes clarified (Main's 35 + isolated).
- `references/sui-data-model.md`: cross-reference to anti-pattern #9 (http_post CTE re-fire) in the LiveFetch section; current-state reserve count 35 → 48.
- **Examples reorganized:** `navi-v9-multimarket.sql` and `navi-v9-multimarket-historical.sql` are now the primary examples (dropped the `.draft` suffix — both validated and merged in [0.3.0]); the Main-only Pyth-priced V8.1 query moved to `examples/legacy/navi-v8-pipeline.sql` (preserved, labeled, body unchanged).

## [0.3.0] — 2026-06-17

Navi multi-market TVL (isolated markets) + on-chain oracle pricing.

### Added
- **Multi-market discovery.** The Navi pipeline now covers all 4 markets — Main + 3 isolated (Ember, Matrixdock, Sui Eco) — discovered dynamically from `0x1e4a13a0…::event::MarketCreated`. Each market is a separate shared `…::storage::Storage` object with its own reserves table; reserve objects are byte-identical across markets. **48 reserves** total (was 35). Full object IDs + the discovery chain in `references/protocol-patterns.md` § "Navi isolated markets".
- **Navi on-chain `PriceOracle` as primary pricing** (`protocol-patterns.md` § "Navi on-chain PriceOracle"). Object `0x1568865e…`, `price_oracles: Table<u8, Price>` keyed by `oracle_id`; USD = `value / 10^decimal`. The exact source Navi uses for liquidations; matches Navi's open-api `oracle.price`. Covers metals/RWA (XAUM, XAGM, eACRED) that Pyth Benchmarks returns null for.
- **Anti-pattern #9** (`protocol-patterns.md` § "Key technical discoveries"): DuneSQL re-fires `http_post` in any CTE referenced more than once → "too many HTTP requests" past the ~40 cap even when the logical count is low. Fix: linearize to single-reference, carry the join key (`market_id`) on the row.
- **`object_id` re-key requirement** documented: per-market `asset_id` (u8) collides across markets (asset 0 is SUI in Main, USDC in Ember); key every reserve join on the globally-unique `object_id`.
- Two example queries: `examples/navi-v9-multimarket.sql` (live), `examples/navi-v9-multimarket-historical.sql` (90-day).

### Changed
- **Live pipeline:** Pyth Hermes CTE **deleted** (a "fallback" `http_post` fires every run + carries ~4% flake); `prices.hour` retained as a free table-read fallback; `'unmatched'` is the safety tag.
- **Historical replay:** extended to all markets; **scoped** on-chain-oracle replay from `sui.objects` for the 3 metals/RWA Price objects (XAUM 31, eACRED 35, XAGM 36) via `WHERE object_id IN (…)` — **170 credits**, under the ~230 baseline (a full-oracle replay would blow it: oracle Price objects churn every tick — XAUM 313K, eACRED 232K versions in 90d). Fed assets stay on `prices.hour → Pyth Benchmarks`. **Never zero-fill:** an unpriced (date, reserve) surfaces fail-loud (`unpriced=true`, NULL).

### Investigation
- Discovery + data model verified on-chain via Sui RPC + Navi Move source (`create_new_market`, `MarketCreated`). Validated is_temp drafts `7739371` (live) / `7739975` (historical) vs Navi same-moment figures: **supply ≤0.05%, borrow 0.054%, net-TVL 0.008%** (totals); historical **170 credits / 3,569 rows / 4 markets**, 1 fail-loud unpriced row (eACRED 2026-04-15, a one-day gap in the oracle's own update stream).
- **Production queries `7377142` (live) and `7528506` (historical) are NOT yet promoted** — drafts validated; promotion is a separate pending decision.

## [0.2.0] — 2026-05-18

Navi historical TVL replay pattern landed; Pyth Benchmarks bulk-historical endpoint documented; critical Navi-9 normalization bug fix.

### Added
- **Navi V0.2 historical replay architecture** (`references/protocol-patterns.md` § "V0.2 — Historical replay") — full pipeline documentation for daily Navi TVL reconstruction via `sui.objects` indexed replay + Pyth Benchmarks historical pricing. Worked example query `7528506` (90-day daily, all 35 reserves, matches Navi portal Total Supply within 0.2%).
- **Pyth Benchmarks TradingView shim pattern** (`references/sui-data-model.md`) — new subsection documenting `https://benchmarks.pyth.network/v1/shims/tradingview/history` as the correct endpoint for bulk historical pricing. Hermes `/v2/updates/price/<ts>` rate-limits hard under parallel calls (HTTP 429 at ~20-30 concurrent), Benchmarks returns full OHLCV history per feed in single response. Verified symbols table and complete SQL parse pattern included.
- **Mysten RPC batching constraint** (`references/protocol-patterns.md`) — explicit documentation that `fullnode.mainnet.sui.io` rejects JSON-RPC 2.0 batching (error `-32005`, verified May 18 2026); naive `N parallel http_post` pipelines flake at scale, forcing the indexed-`sui.objects` architecture for historical replay.
- **Dune per-query HTTP cap** (~40 calls) documented in `sui-data-model.md`.
- **`sui.objects.object_json` JSON path convention** — new technical discovery (#7) in `protocol-patterns.md`, with full RPC-vs-`sui.objects` path comparison table for Navi reserves. Also documented in `sui-data-model.md` § "sui.objects — Full Schema" usage notes.
- **3-package union scope clarification** — new technical discovery (#8) in `protocol-patterns.md`: the 3-package archaeology applies to *events* only; reserve objects are stable across migrations (still carry legacy `0xd899cf7d` struct type), so historical state replay needs zero era-handling.
- **USDY Pyth feed ID** (`e393449f6aff8a4b6d3e1165a7c9ebec103685f3b41e60db4277b5b6d10e7326`) added to the verified feeds table in `sui-data-model.md` and to the V8.1 example SQL. USDY is a yield-bearing token currently trading ~$1.13, not $1 — flat-$1 fallback was visibly wrong on the ~$2.1M USDY supply.
- **`sui.objects.coin_type` formatting note** — returns coin types without `0x` prefix, unlike RPC; requires same address-canonicalization downstream.

### Fixed
- **Navi-9 normalization bullet** (`protocol-patterns.md` § "Key technical discoveries" #1) — previously claimed `raw / 1e9 = native amount`, which silently under-reports older reserves by 5-11%. Corrected to `(raw / 1e9) × (index / 1e27)`. The bug hid on recent BTC reserves (xBTC, enzoBTC, MBTC) where index ≈ 1.00, but caused visible drift on SUI (~9%), DEEP (~9%), WAL (~8%), USDC native (~11%).
- **V8 SQL example** in `protocol-patterns.md` (lines 259–261) — applied the same index multiplication fix.
- **`examples/navi-v8-pipeline.sql`** — applied the index multiplication fix and added USDY feed. Header bumped to V8.1 with explanation of the fix.

### Changed
- `protocol-patterns.md` § "What v2 would do" reframed as "V0.2 — Historical replay (DONE, May 2026)" with the actual architecture (indexed `sui.objects`, not the originally-proposed `sui_tryGetPastObject`). Includes architecture table, cost benchmarks, and reference to live query `7528506`.
- Suilend-vs-Navi comparison table row for "Historical TVL replay" updated: Navi is no longer "Hard" — now "Tractable via `sui.objects` indexed replay + Pyth Benchmarks historical (V0.2 of this skill)".
- "Useful Public Dune Query References" updated: `7377142` re-labeled as V8.1 with fix note; `7528506` added.

### Investigation
- Validated via Dune MCP probes on 2026-05-18:
  - `7528359` — `sui.objects` coverage probe (all 35 reserves, 100% coverage on 30-day window)
  - `7528368` — JSON schema sample for SUI reserve (discovered `$.value.*` path convention)
  - `7528380` — All-35 reserve parsing validation (no exceptions)
  - `7528403` — Historical depth probe (1,022 days of clean coverage available)
  - `7528512` — Pyth Benchmarks endpoint shape probe
  - `7528623` — USDY Pyth feed probe (confirmed missing from `prices.hour`, available at `Crypto.USDY/USD` benchmarks symbol)
- Cross-validated final supply/borrow numbers against Navi's portal frontend at https://app.naviprotocol.io/ on 2026-05-18 — all 35 reserves match within 0.5%, total Protocol TVL within 0.2%.

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
- Historical Navi TVL path documented but not implemented (`sui_tryGetPastObject` snapshots) — **resolved in [0.2.0]** via indexed `sui.objects` replay (query `7528506`); the `sui_tryGetPastObject` route was superseded
- No automated eval suite yet

---

## Roadmap

### [0.5.0] - planned
- **Automated eval suite**: corpus of prompts + expected behaviors, run on every skill update.
- **Audit emerging Sui curated tables**: `sui_walrus.*`, `sui_daily.*`, `sui_tvl.*` schemas, coverage, and freshness (the `dex_sui.trades` price-source path landed in [0.4.0]).
- **Cetus protocol patterns**: concentrated liquidity DEX schemas.
- **Bluefin protocol patterns**: perpetuals + orderbook.
- **Evaluate Navi's MCP** ([naviprotocol.gitbook.io](https://naviprotocol.gitbook.io)) as a cross-check-only source against the on-chain pipeline, not a data dependency.

### Future
- Additional protocols: Scallop, DeepBook, Aftermath, Volo, Haedal
- Walrus and Seal patterns if Mysten ecosystem analytics use cases emerge
- Generalized "discover all events emitted by a package" workflow as a documented sub-skill
- Migration guide if Dune introduces decoded protocol tables for Sui
