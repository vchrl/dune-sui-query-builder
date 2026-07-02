# Dune Sui Query Builder

An [agent skill](https://agentskills.io/) for building, debugging, and optimizing **DuneSQL** queries against **Sui** blockchain data — chained Sui RPC and Pyth Hermes patterns that go beyond what indexed tables alone can deliver. Works with Claude, Cursor, OpenCode, Codex, Gemini CLI, and any agent-skill-compatible tool.

![status](https://img.shields.io/badge/status-v0.4.1%20experimental-orange) ![license](https://img.shields.io/badge/license-MIT-blue) ![sui](https://img.shields.io/badge/chain-Sui-4DA2FF) ![dune](https://img.shields.io/badge/engine-DuneSQL-F26DB6)

---

## The hook

Sui's lending and most protocol-specific DeFi don't have decoded curated tables on Dune. The official `lending.*` tables [cover 15 EVM chains](https://docs.dune.com/data-catalog/curated/lending/overview); `dex.trades` [covers EVM + Solana](https://docs.dune.com/data-catalog/curated/dex-trades/overview), not Sui directly. **What does exist for Sui** (verified May 2026): 5 curated spell tables — `dex_sui.trades` (DEX swaps across 9 protocols, full multi-asset), `sui_tvl.btc_ecosystem` (BTCfi-only — BTC TVL across 5 lending protocols and DEX pools), `sui_daily.stats` (chain activity), `sui_walrus.base_table` (Walrus storage), `cex.addresses` (cross-chain, includes Sui). For multi-asset Sui lending (Navi, Suilend, Scallop, Bucket, AlphaLend at the full-portfolio level — not just BTC), LP positions, protocol internals, and most other granular work — you still query `sui.events` directly.

That makes **package-identity verification a critical skill**. Without it, a single hex mismatch can sit unchallenged in widely-cited dashboards. Concrete example: the most-cited "Navi Protocol" reference on Dune ([Prudentia Labs' dashboard](https://dune.com/mementomori7777/navi-protocol-full-dashboard), 19 charts) queries `0xf95b06141...::reserve::ReserveAssetDataEvent` — which is **Suilend's** package, not Navi's. Triple-confirmed against Suilend's [SDK](https://docs.suilend.fi/), [GitHub](https://github.com/suilend/suilend), and DefiLlama. Not a criticism of the team — a reminder that on Sui, you have to verify the bytes.

This skill packages the methodology — when to use curated tables, when to drop down to raw events.

## Proof of value

Built using this skill in a single weekend:

**[Sui Lending: Navi vs Suilend — Two Paths to ~$150M TVL](https://dune.com/0x_vcharles/sui-lending-navi-vs-suilend)**

- 15 visualizations, both protocols, fully on-chain
- 100% asset coverage on Navi's lending protocol — no third-party indexer
- The on-chain pipeline below — pure SQL + Sui RPC + Navi's on-chain oracle (V0.3: all 4 markets, 48 reserves), refreshes every execution
- Suilend liquidations priced with protocol-native cToken USD (98,081 events at the example run on 2026-06-19, an illustrative snapshot rather than a live count), and the IKA bad-debt episode reconstructed on-chain (V0.4: the two `examples/suilend-*.sql`)

**[Navi protocol: A verified approach](https://dune.com/0x_vcharles/navi-protocol-a-verified-approach)**

- All four isolated Navi markets and every reserve, priced on Navi's own on-chain oracle, no third-party indexer
- Tracks the migration from the old shared pool into the isolated markets, day by day
- Pure SQL plus Sui RPC, refreshes on every execution

**[Suilend Liquidations and Bad Debt: the historical record](https://dune.com/0x_vcharles/suilend-liquidations-and-bad-debt-the-historical-record)**

- Every Suilend liquidation since launch, priced with protocol-native cToken USD
- The one bad-debt episode in its history (IKA, September 2025) reconstructed on-chain from ForgiveEvent and DEX prices
- Reads from a materialized view, with the methodology and a verification record on the dashboard itself

## Architecture: the on-chain pipeline (V9 — multi-market)

When a protocol's events don't embed USD values (Navi-style — most pre-2026 Sui lending), historical replay is hard. This pipeline solves *current* state from on-chain primitives alone — across **all of Navi's markets** (Main + 3 isolated) since V0.3:

```mermaid
flowchart LR
    Q[Dune Query<br/>Execution] --> S0

    subgraph S0[Stage 0: Market Discovery]
        direction TB
        M[suix_queryEvents<br/>MarketCreated] --> M2[4 markets: Main + Ember<br/>+ Matrixdock + Sui Eco<br/>discovered dynamically]
    end

    subgraph S1[Stage 1: Reserve Discovery]
        direction TB
        A[suix_getDynamicFields<br/>per market table] --> A2[48 ReserveData<br/>object IDs]
    end

    subgraph S2[Stage 2: State Fetch]
        direction TB
        B[sui_multiGetObjects<br/>per market] --> B2[48 reserves<br/>supplies, borrows, rates<br/>re-keyed on object_id]
    end

    subgraph S3[Stage 3: Symbols]
        direction TB
        C[static coin_type→symbol map<br/>+ struct-name fallback] --> C2[canonical symbols<br/>solves ::coin::COIN<br/>zero RPC]
    end

    subgraph S4[Stage 4: Pricing]
        direction TB
        D[Navi on-chain PriceOracle<br/>oracle_id → value/10^dec] --> D2[primary price<br/>incl. metals/RWA<br/>prices.hour fallback]
    end

    S0 --> S1 --> S2 --> S3 --> S4 --> R[all markets · 48 reserves · oracle-priced<br/>no indexer, no hardcoded data]
```

Runs entirely from Dune SQL + Sui RPC via `http_post` LiveFetch, priced from **Navi's own on-chain oracle** (the exact source the protocol uses for liquidations; `prices.hour` as a free fallback). No separate indexer, no hardcoded asset list, no hardcoded prices. Refreshes on every query execution. (V8 priced via Pyth Hermes and covered the Main market only — preserved in `examples/legacy/`.)

Full annotated SQL: [`examples/navi-v9-multimarket.sql`](./examples/navi-v9-multimarket.sql) (live) · [`examples/navi-v9-multimarket-historical.sql`](./examples/navi-v9-multimarket-historical.sql) (90-day historical) · Reference doc: [`references/protocol-patterns.md`](./references/protocol-patterns.md)

## Which Dune source for what?

Sui's data model is fundamentally different from EVM (curated tables for most DeFi) and Solana (object-centric state). Sui has 5 curated spell tables for specific domains; everything else drops to raw event/object archaeology:

```mermaid
flowchart TD
    Start[What kind of Sui<br/>analytics question?] --> Curated{Covered by a<br/>curated spell table?}

    Curated -->|DEX swaps and volume| C1[dex_sui.trades<br/>9 protocols since May 2023]
    Curated -->|BTCfi: BTC on Sui| C2[sui_tvl.btc_ecosystem<br/>BTC-only at gold layer]
    Curated -->|Daily chain stats:<br/>PTBs, zkLogin, gas| C3[sui_daily.stats]
    Curated -->|Walrus storage| C4[sui_walrus.base_table]
    Curated -->|CEX flows on Sui| C5[cex.addresses<br/>+ sui.transactions]
    Curated -->|None of those| A{Drop to raw:<br/>type of question}

    A -->|Flows: deposits,<br/>borrows, swaps| E1[sui.events<br/>filter by event_type]
    A -->|State at historical time T| E2[sui.objects<br/>latest version per object_id]
    A -->|Just function call counts| E3[sui.move_call<br/>cheapest option]
    A -->|Per-tx detail: gas,<br/>success, signers| E4[sui.transactions]
    A -->|Current TVL / rates /<br/>asset list| Live{Protocol embeds<br/>USD in events?}

    Live -->|Yes, Suilend style| E5[sui.events on<br/>ReserveAssetDataEvent]
    Live -->|No, Navi style| E6[LiveFetch: http_post<br/>to Sui RPC]

    E6 --> O{Protocol runs its<br/>own on-chain oracle?}
    O -->|Yes, Navi V9| E9[Read protocol PriceOracle<br/>oracle_id → value/10^dec<br/>covers metals/RWA]
    O -->|No| P{Token covered by<br/>prices.hour?}
    P -->|Yes, major tokens| E7[prices.hour<br/>watch double-hex encoding]
    P -->|No, long-tail| E8[Pyth Hermes / Benchmarks<br/>same oracle protocols use]
```

For a thin token with no oracle feed, a `dex_sui.trades` daily VWAP sits between protocol-emitted USD and Pyth as the long-tail price source (the Suilend IKA reconstruction uses exactly this).

This decision tree, the schema breakdowns, and the anti-patterns are encoded in [`references/sui-data-model.md`](./references/sui-data-model.md); the curated-table branch is fully documented in [`references/sui-curated-tables.md`](./references/sui-curated-tables.md).

## What's in the box

```
dune-sui-query-builder/
├── SKILL.md                       Task router: Build / Debug / Optimize / Investigate
├── references/
│   ├── sui-data-model.md          Dune Sui table catalog · 13 edge cases / anti-patterns ·
│   │                              LiveFetch · pricing decision tree · matview serving layer
│   ├── sui-curated-tables.md      Curated Sui spell tables · dex_sui.trades schema + VWAP ·
│   │                              BTCfi, daily stats, Walrus · when to use curated vs raw
│   ├── protocol-patterns.md       Navi 3-package archaeology · isolated markets · V8 + V9
│   │                              pipelines · Suilend pack: liquidations, cToken pricing, IKA
│   └── verification-toolkit.md    Raw-events recount · stablecoin cross-check · cToken penalty
└── examples/
    ├── navi-v9-multimarket.sql            Live multi-market TVL (4 markets, 48 reserves) — primary
    ├── navi-v9-multimarket-historical.sql 90-day historical replay (scoped on-chain oracle)
    ├── suilend-liquidations-priced.sql    Suilend liquidations priced per event (matview source, q7756564)
    ├── suilend-ika-bad-debt.sql           IKA bad debt: dex_sui.trades VWAP vs liquidations (q7757951)
    └── legacy/
        └── navi-v8-pipeline.sql           V8.1 Main-only, Pyth-priced — superseded by V9
```

The four `references/` files are written to **stand alone as documentation** — you don't need to be a Claude user to get value from them. Read them like a technical handbook for analysts working on Sui.

## How this fits with Dune's tooling

Dune ships its own [agent skill](https://github.com/duneanalytics/skills), [MCP server](https://docs.dune.com/api-reference/agents/mcp), and [CLI](https://docs.dune.com/api-reference/agents/cli-and-skills) — they teach agents how to discover datasets, write DuneSQL, execute queries, and manage costs. That's the *execution layer*. This is a *Sui domain layer* on top — when to reach for which Sui table, what's curated vs. what needs raw event work:

| Domain | Dune coverage (verified May 2026) | What this skill adds |
|---|---|---|
| Sui DEX swaps (Cetus, Bluefin, DeepBook, Aftermath, Kriya, FlowX, Momentum, BlueMove, Obric) | ✅ `dex_sui.trades` — 9 projects, since May 2023 | Schema reference, partition pruning, worked examples, when to drop to raw events |
| Sui BTCfi (BTC on Sui across DEX + lending) | ✅ `sui_tvl.btc_ecosystem` + `_gold` intermediates | Schema documentation (intermediates aren't in Dune's data hub search) |
| Sui chain stats (PTBs, zkLogin, gas, success rate) | ✅ `sui_daily.stats` | Pointer + worked example |
| Walrus storage | ✅ `sui_walrus.base_table` | Pointer |
| Sui CEX flows | ⚠️ Partial — `cex.addresses` includes Sui labels, but no `cex_flows_sui.*` table — join with `sui.transactions` yourself | DIY pattern |
| Sui lending (Navi, Suilend, Scallop, Bucket, AlphaLend) | ⚠️ Partial — `sui_tvl.lending_pools_gold` publishes **BTC-only TVL** across these 5 protocols; spellbook source has bronze models for full multi-asset data but isn't published as a gold table | Package archaeology, event schemas, V8 LiveFetch pipeline (the practical path for multi-asset, granular, real-time lending data) |
| Sui DEX *internals* (LP positions, fee tiers, pool depth) | ❌ Only swap-level via `dex_sui.trades` | Raw `sui.events` / `sui.objects` patterns |
| Sui base chain data | ✅ 8 chain tables, [well-documented](https://docs.dune.com/data-catalog/sui/overview) | Sui edge cases: binary types, JSON parsing, double-hex `prices.hour`, the `::coin::COIN` problem |

Recommended stack: **Dune MCP/Skill/CLI for execution + this skill for Sui domain knowledge + your agent of choice** (Claude, Cursor, Codex, Gemini CLI — anything agent-skill-compatible).

The `references/` markdown files are also usable as plain documentation by humans — no agent required.

## Companion: building the dashboard

Putting these queries on a public Dune dashboard is mostly not Sui-specific, so the skill body stays SQL-focused and the generic mechanics route to [Dune's official skill](https://github.com/duneanalytics/skills). Notes worth carrying:

- Mermaid does render inside Dune text widgets.
- `updateDashboard` is all-or-nothing, so always `getDashboard` first and send the full state back.
- The layout grid is 6 columns. An Ilemi-style left explainer beside each chart, with numbered full-width section separators, reads well.
- Only promoted (non-temp) queries render on a public dashboard.
- Duplicate-x aggregation (Sum vs Pick first) is not settable via the API and has caused a TVL undercount; set it in the Dune UI.

The one presentation detail that is Sui-specific lives in the skill, not here: clickable account cells via `get_href('https://suiscan.xyz/mainnet/account/' || addr || '/portfolio', addr)` (see `references/protocol-patterns.md`).

## Installation

### As an agent skill

Agent skills are an [open standard](https://agentskills.io/) supported by Claude (Code, Desktop, .ai), Cursor, OpenCode, Codex, Gemini CLI, Goose, and more.

**Claude.ai (web/desktop):**
1. Clone or download this repo
2. ZIP the folder: `zip -r dune-sui-query-builder.zip dune-sui-query-builder/`
3. Upload via Claude → Settings → Capabilities → Skills

**Claude Code, Cursor, and most other agents** (skill auto-loaded from `~/.claude/skills/` or equivalent):
```bash
git clone https://github.com/vchrl/dune-sui-query-builder.git \
  ~/.claude/skills/dune-sui-query-builder
```

Adjust the destination path per your agent's skill directory convention. The skill auto-triggers on prompts mentioning Dune, DuneSQL, Sui queries, Move events, LiveFetch, Navi, Suilend, Pyth, etc. See the full trigger list in [`SKILL.md`](./SKILL.md).

### As reference documentation (no agent needed)

Just read `references/sui-data-model.md`, `references/sui-curated-tables.md`, `references/protocol-patterns.md`, and `references/verification-toolkit.md` directly. They were written to be skimmable for someone debugging at 2am — schema breakdowns, full SQL examples, anti-patterns observed in real production dashboards.

## Quick start

Three prompts that demonstrate what the skill enables:

> *"Build me a Dune query for Suilend's 90-day daily TVL by tier."*
> → Returns a partition-pruned query against `ReserveAssetDataEvent`, with the `1e18` decimal scaling and the FUD-token filter pre-applied.

> *"Here's a Dune query [link]. Debug it — the TVL chart cuts off at Feb 2026."*
> → Identifies missing package coverage, suggests the multi-package UNION ALL pattern with per-branch date filters.

> *"The mementomori 'Navi Protocol' dashboard — is it accurate?"*
> → Pulls the SQL, decodes the package hexes, confirms it's actually Suilend, outputs an audit.

## What's new in V0.4

- **Suilend protocol pack.** `references/protocol-patterns.md` now carries Suilend the same way it carries Navi: multi-market identity (`reserve_id` as the join key), the `event_json` conventions, the liquidation/obligation/forgive event catalog, and protocol-native pricing. Two standalone queries ship as examples: [`examples/suilend-liquidations-priced.sql`](./examples/suilend-liquidations-priced.sql) (Dune query 7756564, the matview source) and [`examples/suilend-ika-bad-debt.sql`](./examples/suilend-ika-bad-debt.sql) (Dune query 7757951).
- **cToken pricing as the correctness core.** Suilend emits seized collateral, protocol fee, and liquidator bonus in cTokens, not underlying. The pack states the USD-per-cTOKEN derivation (`supply_amount_usd_estimate / ctoken_supply`) and generalizes it to a cross-protocol share-token rule alongside Navi's supply-index.
- **`dex_sui.trades` as the long-tail price source.** A daily VWAP recipe with address-LIKE matching, documented in `references/sui-curated-tables.md` and worked through in the IKA bad-debt case (the only `ForgiveEvent` episode in Suilend history).
- **Materialized-view serving layer.** One expensive priced pass writes a `result_*` matview; downstreams read it cheaply. Documented with honest tier/cost/refresh notes and the `createMaterializedView` gate in `references/sui-data-model.md`.
- **Verification toolkit.** New `references/verification-toolkit.md`: raw-events recount, stablecoin face-value cross-check, and the price-independent cToken penalty ratio, substituting for the price-table cross-check Sui cannot provide.
- **Anti-patterns expanded and pricing reordered.** Five new anti-patterns; Sui pricing guidance now leads with protocol-emitted USD and `dex_sui.trades`. A new dashboard companion note routes generic Dune mechanics to the official Dune skill.

## What's new in V0.3

- **Multi-market coverage.** The Navi pipeline now spans all 4 markets — Main + the 3 isolated markets (Ember, Matrixdock, Sui Eco) — discovered dynamically from `MarketCreated` events. **48 reserves** total (was 35, Main-only). See `references/protocol-patterns.md` § "Navi isolated markets".
- **On-chain oracle pricing (primary).** Prices now come from Navi's own on-chain `PriceOracle` (`oracle_id → value / 10^decimal`) — the exact source the protocol uses for liquidations. Covers metals/RWA (XAUM, XAGM, eACRED) that Pyth Benchmarks returns null for. Pyth Hermes is removed from the live query; `prices.hour` stays as a free fallback. See § "Navi on-chain PriceOracle".
- **Historical replay extended** to all markets, with a cost-scoped on-chain-oracle replay for the 3 metals/RWA Price objects (170 credits, under baseline); fed assets stay on `prices.hour → Pyth Benchmarks`. **Fail-loud** on any unpriced (date, reserve) — never zero-filled.
- **`object_id` re-key + anti-pattern #9.** Per-market `asset_id` collides across markets, so every reserve join is keyed on the globally-unique `object_id`. New anti-pattern documented: DuneSQL re-fires `http_post` in any CTE referenced more than once → linearize to single-reference.
- **Validated** vs Navi's live figures: supply ≤0.05%, borrow 0.054%, net-TVL 0.008% (live snapshot); 170 credits / 3,569 rows (90-day historical). Example SQL: [`examples/navi-v9-multimarket.sql`](./examples/navi-v9-multimarket.sql), [`examples/navi-v9-multimarket-historical.sql`](./examples/navi-v9-multimarket-historical.sql).

## What's solid in V0.1

- Dune Sui table catalog: `sui.events`, `sui.objects`, `sui.move_call`, `sui.transactions`, `sui.move_package`
- **5 curated Sui spell tables documented** (V0.1.1): `dex_sui.trades` (9 DEXs since May 2023), `sui_tvl.btc_ecosystem` + `_gold` intermediates, `sui_daily.stats`, `sui_walrus.base_table`, `cex.addresses`
- Binary type decoding, JSON-string parsing, partition pruning patterns
- LiveFetch patterns: single-call, multi-stage CTE chains, parallel per-row
- Pyth Hermes integration with verified feed IDs (April 2026)
- Navi 3-package archaeology + complete event_type strings
- Suilend `ReserveAssetDataEvent` schema (the USD-in-events trick)
- The V8 4-stage pipeline (validated, 100% coverage on $235M)
- 8 anti-patterns from real production dashboards, with corrections
- Decision tree: curated spell tables vs. raw `sui.events`

## V0.1 limitations — read before relying

This is a V0.1 release. Be aware of:

- **Pyth feed IDs are point-in-time** (verified April 2026). Feed IDs are usually stable but verify before production use.
- **`sui_tvl.*_gold` intermediates are undocumented in Dune's data hub** — they're queryable and used in production dashboards, but schemas can change without notice. Always sample before relying. Spellbook commits ~8 months old.
- **`sui_tvl.lending_pools_gold` is BTC-only at the public gold layer.** Schema verified May 2026: 10 columns, all BTC. Spellbook source has bronze tables for 5 protocols (navi, suilend, scallop, bucket, alphalend) — but only the BTC slice is published. Full multi-asset Sui lending still requires the raw-events approach.
- **Per-DEX deep analytics not yet covered.** Cetus concentrated liquidity, DeepBook orderbook state, Bluefin perps internals — flagged for V0.2. Use `dex_sui.trades` for swap-level work today.
- **Liquidation event paths for Navi** flagged in the skill but not yet sampled — you'll need to discover them via the included discovery query before relying.
- **Some `event_json` field paths are best-guesses** from SDK code and explicitly flagged with uncertainty disclaimers. The skill instructs Claude to verify by sampling before using.
- **Historical Navi TVL ships in V0.2.** Daily Navi TVL reconstruction via indexed `sui.objects` replay + Pyth Benchmarks historical pricing — live in query `7528506` (the originally-proposed `sui_tryGetPastObject` route was superseded; see `references/protocol-patterns.md` § V0.2).
- **LiveFetch caveats apply:** 5s timeout per call, ~80 req/s rate limit, no caching across executions. Queries with hundreds of parallel RPC calls may hit limits.
- **No automated eval suite yet.** Skill quality is validated by the production dashboard it shipped — but there's no automated regression test corpus. V0.2 target.

## Roadmap

### V0.2
- **Per-DEX protocol patterns** — Cetus concentrated liquidity, DeepBook orderbook state, Bluefin perps. Hybrid approach: `dex_sui.trades` for volume + raw `sui.events` / `sui.objects` for internals.
- **On-chain oracle pricing** — ✅ delivered in V0.3, but **not** via the originally-planned pure-Pyth route: Navi's own `PriceOracle` is now the primary price source (covers metals/RWA like XAU/XAG that Pyth can't). See § "What's new in V0.3".
- **Historical Navi TVL** — ✅ delivered in V0.2 via indexed `sui.objects` replay + Pyth Benchmarks (originally proposed via `sui_tryGetPastObject`, superseded). See `references/protocol-patterns.md` § V0.2 and query `7528506`.
- **Multi-asset Sui lending TVL** — extend beyond BTCfi using a hybrid of `sui_tvl.lending_pools_gold` + raw events.
- **Eval suite:** corpus of prompts + expected behaviors, run on every skill update.

### Future
- Scallop, DeepBook, Aftermath, Volo, Haedal protocol patterns
- Walrus / Seal references if Mysten ecosystem analytics use cases emerge
- Generalized "discover all events emitted by a package" workflow

## Why this exists

Sui's DeFi data on Dune is uneven — strong curated coverage for DEX swaps, BTCfi, and chain stats, but lending and most protocol internals still require raw `sui.events` archaeology. Every analyst rediscovers the same edge cases — binary type handling, the `::coin::COIN` problem, package upgrades that silently truncate history, the double-hex encoding in `prices.hour`. This skill packages a weekend's worth of comparative-lending-protocol work into something portable.

Public because the methodology is useful for anyone analyzing Sui on Dune, and the work belongs somewhere the next person can find it.

Built by [Vincent Charles](https://github.com/vchrl) — independent blockchain data analyst ([Unchain Data](https://unchaindata.xyz/dune-dashboards); previously: Binance, Morpho Labs, Orca). Built with [Claude](https://www.anthropic.com/claude) + [Dune MCP](https://docs.dune.com/api-reference/agents/mcp).

## Contributing

PRs welcome, especially:
- **New protocol patterns** in `references/protocol-patterns.md`
- **Newly-verified Pyth feed IDs** (with timestamp of verification)
- **New anti-patterns** observed in production
- **Eval prompts** — prompts + expected behaviors for skill quality regression

Please match the existing markdown style: code blocks with full SQL, explicit uncertainty disclaimers, anti-patterns labeled as such.

## Credits & references

- [Dune Analytics](https://dune.com) — query engine, LiveFetch (`http_post` / `http_get`), the [MCP server](https://docs.dune.com/api-reference/agents/mcp) that made the workflow possible
- [Pyth Network](https://pyth.network) — on-chain oracle, [Hermes API](https://hermes.pyth.network/docs)
- [Mysten Labs](https://mystenlabs.com) and the [Sui Foundation](https://sui.io) — Sui blockchain and developer docs
- [Anthropic](https://anthropic.com) — Claude and the [skills framework](https://www.anthropic.com/news/skills)
- **Suilend team** (formerly Solend) — `ReserveAssetDataEvent` schema reverse-engineered from their [open-source Move code](https://github.com/suilend/suilend)
- **Navi team** — SDK code referenced for `event_json` field path inference
- **Prudentia Labs** — operates the most-cited Sui lending dashboard; the mislabel investigation is not a criticism of them, but a reminder of how easily one package hex can propagate as canonical truth

## License

MIT — see [LICENSE](./LICENSE)

---

*Found a bug? Open an issue. Built something with it? Tag [@0x_vcharles](https://x.com/0x_vcharles) — would love to see.*

---

Built by Vincent Charles, Unchain Data. I build reconciled, defensible on-chain dashboards for Sui and EVM protocols, the kind this skill is designed to produce. Need one for your protocol? [unchaindata.xyz/dune-dashboards](https://unchaindata.xyz/dune-dashboards)
