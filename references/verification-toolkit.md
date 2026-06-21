# Verification Toolkit for Sui Queries

How to prove a priced Sui query (or the materialized view it feeds) is correct when Sui has no curated per-protocol tables and no reliable price table to cross-check against. These three checks are protocol-agnostic; the worked numbers come from the validated Suilend liquidation work (`examples/suilend-liquidations-priced.sql`, Dune query 7756564).

## 1. Independent raw-events recount

Re-count the underlying events straight from `sui.events`, with no pricing and no joins, and compare the counts to the priced output or the matview. The counts must match exactly, not approximately. A mismatch means the priced pass dropped or duplicated rows somewhere in its joins.

As of the example run (2026-06-19), the recount matched exactly: 98,081 liquidations, 15,710 obligations, 204 liquidators, zero difference against `result_suilend_liquidations`. Those counts are an illustrative snapshot from that run, not Suilend's standing totals; what carries forward is the zero-diff procedure. Run the recount as its own query so it cannot share a bug with the thing it checks.

## 2. Stablecoin face-value cross-check

Sui cannot give you a reliable price-table cross-check (see the pricing notes in `sui-data-model.md`). For stable-priced assets you can substitute one: the protocol's own USD figure should match the raw token amount within a tight band, because a dollar stablecoin is worth about a dollar.

In the example run (2026-06-19), stablecoins were about 81% of debt repaid, and the protocol-native USD matched raw token face value within about 0.05%. The 81% is an illustrative snapshot from that run; the ~0.05% band is the practical bound on the protocol-native pricing path that you re-assert on each run. If stablecoin USD drifts further than that, the decimal or share-unit handling is wrong before you even look at the volatile assets.

## 3. Realized penalty from price-independent quantity ratios

Do not read the liquidation penalty off the aggregate seized-USD / repaid-USD ratio. Collateral is oracle-valued on daily snapshots that lag intraday cascade prices, so in the example run (2026-06-19) that aggregate ratio runs near 1.2 all-time (about 1.197) and overstates the penalty badly.

Compute the realized penalty from price-independent cToken quantity proportions instead (seized cToken quantity versus repaid quantity at the reserve level), which the same run put at about 6%. Both figures are illustrative of that run, not standing values. The quantity ratio does not depend on any price, so it survives the oracle-snapshot lag that distorts the USD ratio. Any window-scoped USD ratio belongs only to the example query that produced it, not to this general rule. This is anti-pattern "seized_usd / repaid_usd as the penalty" in `sui-data-model.md`.

## Where this fits

These checks gate the materialized-view build: validate against them before calling `createMaterializedView` (see `sui-data-model.md` § "Materialized views as a serving layer"). They are the substitute for the regression corpus this skill does not yet ship.
