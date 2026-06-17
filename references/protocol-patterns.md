# Sui Protocol Patterns — Navi & Suilend on Dune

Protocol-specific reference for building Dune queries against the two largest Sui lending protocols. Covers package archaeology, validated event schemas, the mementomori7777 "Navi" mislabel, and a fully-validated 4-stage dynamic pipeline that achieves 100% asset coverage on Navi without any third-party indexer.

## Table of Contents

1. [The mementomori mislabel investigation](#the-mementomori-mislabel-investigation)
2. [Suilend overview & patterns](#suilend-overview--patterns)
3. [Navi overview & the three-package problem](#navi-overview--the-three-package-problem)
4. [Navi event type strings](#navi-event-type-strings)
5. [Navi 4-stage dynamic pipeline (V8)](#navi-4-stage-dynamic-pipeline-v8)
6. [Comparing Suilend vs Navi](#comparing-suilend-vs-navi)
7. [Useful public Dune query references](#useful-public-dune-query-references)

## The mementomori Mislabel Investigation

Before doing any Navi or Suilend work on Dune, **be aware of this**: the most-cited "Navi Protocol" reference dashboard on Dune ([Prudentia Labs' dashboard](https://dune.com/mementomori7777/navi-protocol-full-dashboard), 19 charts) queries **Suilend's** event package, not Navi's.

Evidence: the core query points at `0xf95b06141ed4a174f239417323bde3f209b972f5930d8521ea38a52aff3a6ddf::reserve::ReserveAssetDataEvent`. Triple-confirmed:
- Suilend SDK docs reference this exact package as Suilend's main pool
- Suilend GitHub repo (`github.com/suilend/suilend`) confirms the modules `lending_market`, `reserve`, `obligation` under this package
- DefiLlama, Bybit Learn, and the Suilend documentation all match
- Mysten Labs is a Suilend investor (Dec 2024 $6M round)

Real Navi packages are `0x1e4a13a0...` (events) and `0xd899cf7d...` (legacy storage type). The `0xf95b06141...` package has nothing to do with Navi.

This isn't a criticism of the Prudentia team — it's a reminder of how easily one wrong package hex can propagate as a canonical reference on Sui, where there are no curated protocol tables to anchor identity.

**Practical implications:**
- When asked to "build a Navi dashboard," verify the package hexes before using any reference SQL
- When asked to "improve / clone / fix" the mementomori dashboard, the right answer is often "rebuild it correctly because it's a different protocol"
- This finding is a useful pedagogical example of why package-identity verification matters on Sui

## Suilend Overview & Patterns

Suilend is a lending protocol on Sui (~$190M TVL April 2026), backed by Mysten Labs. Key technical fact: Suilend's `ReserveAssetDataEvent` includes **Pyth-computed USD estimates inside the event itself**, making historical TVL replay trivial from on-chain events alone — no separate price table needed.

### Suilend canonical package & event types

```
Package: 0xf95b06141ed4a174f239417323bde3f209b972f5930d8521ea38a52aff3a6ddf
Modules: lending_market, reserve, obligation
Main pool ID: 0x84030d26d85eaa7035084a057f2f11f701b7e2e4eda87551becbc7c97505ece1
```

State events (TVL, rates, available liquidity):
- `<pkg>::reserve::ReserveAssetDataEvent` — emitted ~hourly per asset, contains pre-computed USD estimates

Activity events (deposit, borrow, withdraw, repay, liquidate):
- `<pkg>::lending_market::DepositEvent`
- `<pkg>::lending_market::WithdrawEvent`
- `<pkg>::lending_market::BorrowEvent`
- `<pkg>::lending_market::RepayEvent`
- `<pkg>::lending_market::LiquidateEvent`
- `<pkg>::lending_market::ClaimRewardEvent`

### Suilend `ReserveAssetDataEvent` field layout

The killer feature: Pyth USD estimates pre-computed in the event payload. Verified field paths:

```
$.coin_type.name                      → full Move type string (e.g. "0x2::sui::SUI")
$.available_amount.value              → raw available, scaled by 1e18 in Suilend's internal Decimal
$.supply_amount.value                 → raw supply, scaled by 1e18
$.borrowed_amount.value               → raw borrow, scaled by 1e18
$.available_amount_usd_estimate.value → USD estimate, also scaled by 1e18
$.supply_amount_usd_estimate.value    → USD estimate, scaled by 1e18
$.borrowed_amount_usd_estimate.value  → USD estimate, scaled by 1e18
$.supply_apr.value                    → APR, scaled by 1e18
$.borrow_apr.value                    → APR, scaled by 1e18
```

**Important:** Suilend uses an internal `Decimal` type that scales everything by `1e18`. Native amounts also need division by token decimals on top:
```sql
-- Native token amount:
(supply_amount / 1e18) / pow(10, token_decimals) AS native_balance

-- USD value (pre-computed by Pyth):
supply_amount_usd_estimate / 1e18 AS supply_usd
```

Some assets in Suilend's main pool include junk/test tokens (e.g. `76cb819b...::fud::FUD`). Filter explicitly:
```sql
AND json_extract_scalar(event_json, '$.coin_type.name') !=
    '76cb819b01abed502bee8a702b4c2d547532c12f25001c9dea795a5e631c26f1::fud::FUD'
```

### Suilend daily TVL by asset (validated pattern)

```sql
WITH ranked AS (
  SELECT
    date AS day,
    json_extract_scalar(event_json, '$.coin_type.name') AS token,
    upper(split_part(json_extract_scalar(event_json, '$.coin_type.name'), '::', 3)) AS symbol,
    try_cast(json_extract_scalar(event_json, '$.supply_amount_usd_estimate.value') AS DOUBLE) / 1e18 AS supply_usd,
    try_cast(json_extract_scalar(event_json, '$.borrowed_amount_usd_estimate.value') AS DOUBLE) / 1e18 AS borrow_usd,
    timestamp_ms,
    event_index,
    ROW_NUMBER() OVER (PARTITION BY date, json_extract_scalar(event_json, '$.coin_type.name')
                       ORDER BY timestamp_ms DESC, event_index DESC) AS rn
  FROM sui.events
  WHERE date >= CURRENT_DATE - INTERVAL '90' DAY
    AND event_type = '0xf95b06141ed4a174f239417323bde3f209b972f5930d8521ea38a52aff3a6ddf::reserve::ReserveAssetDataEvent'
    AND json_extract_scalar(event_json, '$.coin_type.name') !=
        '76cb819b01abed502bee8a702b4c2d547532c12f25001c9dea795a5e631c26f1::fud::FUD'
)
SELECT day, token, symbol, supply_usd, borrow_usd
FROM ranked WHERE rn = 1
ORDER BY day DESC, supply_usd DESC
```

### Suilend activity (correct event package — common mistake)

A common bug: using **Navi's** event package for Suilend's activity counts. The correct Suilend events are under `lending_market::*Event`:

```sql
SELECT
  COUNT(DISTINCT sender) AS active_wallets_14d,
  COUNT(DISTINCT json_extract_scalar(event_json, '$.obligation_id')) AS active_obligations_14d
FROM sui.events
WHERE date >= CURRENT_DATE - INTERVAL '14' DAY
  AND event_type IN (
    '0xf95b06141ed4a174f239417323bde3f209b972f5930d8521ea38a52aff3a6ddf::lending_market::DepositEvent',
    '0xf95b06141ed4a174f239417323bde3f209b972f5930d8521ea38a52aff3a6ddf::lending_market::WithdrawEvent',
    '0xf95b06141ed4a174f239417323bde3f209b972f5930d8521ea38a52aff3a6ddf::lending_market::BorrowEvent',
    '0xf95b06141ed4a174f239417323bde3f209b972f5930d8521ea38a52aff3a6ddf::lending_market::RepayEvent',
    '0xf95b06141ed4a174f239417323bde3f209b972f5930d8521ea38a52aff3a6ddf::lending_market::LiquidateEvent',
    '0xf95b06141ed4a174f239417323bde3f209b972f5930d8521ea38a52aff3a6ddf::lending_market::ClaimRewardEvent'
  )
```

Note: Suilend's `obligation_id` is the equivalent of an account/position, and one wallet can hold multiple obligations (e.g. ~10 per wallet via STEAMM AMM and LST loops). Use `obligation_id` for "positions," `sender` for "wallets."

## Navi Overview & the Three-Package Problem

Navi is the largest lending protocol on Sui (~$235M TVL April 2026), Aave-style shared-pool lending across ~35 assets, with isolation markets, flash loans, and NAVX token incentives. Backed by Mysten Labs, Coin98 Ventures, Galxe.

**The hard part:** Navi's events do NOT include pre-computed USD values (unlike Suilend). Historical TVL reconstruction requires either flow accounting (events) or RPC snapshots (LiveFetch via `sui_tryGetPastObject`). For *current* TVL, the canonical approach is the 4-stage dynamic pipeline below.

### The three packages

| Era | Package ID | Module | Status |
|-----|-----------|--------|--------|
| Original direct lending | `0xd899cf7d2b5db716bd2cf55599fb0d5ee38a3061e7b6bb6eebf73fa5bc4c81ca` | `lending` | Storage types still live here |
| On-behalf-of lending | `0x7c9b90b3fda0fa4aa8ee88ae6c4a0b83c773f74936b5354448cb94662e94442d` | `lending` | Separate package for on-behalf flows (keepers, leverage vaults) |
| Current event package | `0x1e4a13a0494d5facdbe8473e74127b838c2d446ecec0ce262e2eddafa77259cb` | `event` | Where all current event emissions live |

There was also an intermediate package upgrade Nov 17, 2025 (`0xee0041239b89564ce870a7dec5ddc5d114367ab94a1137e90aa0633cb76518e0`) — short-lived, treat as secondary if 2025-11 → 2026-02 data looks thin.

### Live protocol parameters

```
GET https://open-api.naviprotocol.io/contractconfigs
```

Returns the live asset list with supply/borrow caps, utilization, LTV, liquidation thresholds. Useful for cross-validation of LiveFetch results.

### Storage object: the reserves table

Navi's lending storage object (currently shared) holds a dynamic field collection of all reserves:
```
Storage object: 0xe6d4c6610b86ce7735ea754596d71d72d10c7980b5052fc3c8cdf8d09fea9b4b
```

This is the entry point for LiveFetch pipelines — call `suix_getDynamicFields` on it to discover all 35 ReserveData child objects. (This is the **Main market** table; isolated markets each have their own — see below.)

### Navi isolated markets (V9, June 2026)

Navi launched **isolated markets** (April–May 2026). Each market is a **separate shared `Storage` object** of the same type `0xd899cf7d…::storage::Storage`, each with its own `reserves: Table<u8, ReserveData>`. Reserve objects are byte-identical across markets — `0x2::dynamic_field::Field<u8, 0xd899cf7d…::storage::ReserveData>` — so one discovery + replay handles all markets; only the parent table differs.

Markets (verified on-chain from the creation transactions, 2026-06-17):

| Market | market_id | Storage object | reserves-table (df parent) | reserves | assets |
|---|---|---|---|---|---|
| Main | 0 | `0xbb4e2f4b…442fe` | `0xe6d4c661…9b4b` | 35 | all majors (XAUM #31, suiUSDe #33 live here too) |
| Ember | 1 | `0xc2b6a52f…cdd90` | `0xb49d02df…eef3c` | 3 | USDC, suiUSDe, eACRED |
| Matrixdock | 2 | `0x199c1d5c…3ed9f` | `0xb1dc26b8…4894` | 3 | USDC, XAUM (gold), XAGM (silver) |
| Sui Eco | 3 | `0xdf18372b…7c558` | `0x376c2ee4…3b42` | 7 | SUI, USDC, CETUS, BLUE, HAEDAL, IKA, NS |

Full object IDs:
- Main — Storage `0xbb4e2f4b6205c2e2a2db47aeb4f830796ec7c005f88537ee775986639bc442fe` / reserves `0xe6d4c6610b86ce7735ea754596d71d72d10c7980b5052fc3c8cdf8d09fea9b4b`
- Ember — Storage `0xc2b6a52f0da7f91389eaffe4f68f4cacee43aa616bb8a4371118eafaf07cdd90` / reserves `0xb49d02df33f75665aff72ae37195d17f9298e064c7ed62fd0640533be79eef3c`
- Matrixdock — Storage `0x199c1d5c2d58a4b05bbfa2338d02ad2676572a8a59ac148a5475b5c0fc53ed9f` / reserves `0xb1dc26b806a0a1e45a586e83d7a389040d1368a7e78f2f0debd59be973104894`
- Sui Eco — Storage `0xdf18372bc9c588b96c7553bc811467a9166ed9be472b40cb45c226175377c558` / reserves `0x376c2ee403d41d327eee462abb97b56cb155ee0cd1ced39598a83b26d19a3b42`

**Discovery (dynamic):** markets are created by `create_new_market()`, which emits `0x1e4a13a0494d5facdbe8473e74127b838c2d446ecec0ce262e2eddafa77259cb::event::MarketCreated { market_id }`. Querying that event type returns the isolated set (currently 3; Main = market_id 0 is created in module `init` and emits **no** event → add it explicitly). The created `Storage` id is in the creation tx's `objectChanges`; its `reserves.id.id` is the reserves table. Full chain (events → `sui_getTransactionBlock` → `sui_getObject` → `suix_getDynamicFields`) is in `examples/navi-v9-multimarket.sql`.

**Re-key requirement (critical):** the `u8` `asset_id` (dynamic-field key) **restarts at 0 in every market** — asset 0 is SUI in Main but USDC in Ember. Key every join on the globally-unique reserve **`object_id`**, never `asset_id`. Live: `market_id` rides on each per-market `sui_multiGetObjects` row (no join-back). Historical: reserves are tagged via a discovery dim joined on `object_id` (decoded `from_hex(substr(id,3))` for `sui.objects.object_id` varbinary). `asset_id` survives only as an informational per-market column. (Interacts with "Key technical discoveries" #9 — the LiveFetch single-reference rule.)

**Coverage:** Main + isolated = 48 reserves; validated vs Navi live figures to ≤0.05% supply, 0.054% borrow, 0.008% net-TVL (live snapshot), and 170 credits / 3,569 rows (90-day historical). Examples: `examples/navi-v9-multimarket.sql` (live), `examples/navi-v9-multimarket-historical.sql` (historical).

## Navi Event Type Strings

Use these as the IN list for `event_type` filters in historical queries.

```sql
-- Current event package (post-Feb-2026, where most live emissions go)
'0x1e4a13a0494d5facdbe8473e74127b838c2d446ecec0ce262e2eddafa77259cb::event::DepositEvent'
'0x1e4a13a0494d5facdbe8473e74127b838c2d446ecec0ce262e2eddafa77259cb::event::WithdrawEvent'
'0x1e4a13a0494d5facdbe8473e74127b838c2d446ecec0ce262e2eddafa77259cb::event::BorrowEvent'
'0x1e4a13a0494d5facdbe8473e74127b838c2d446ecec0ce262e2eddafa77259cb::event::RepayEvent'
'0x1e4a13a0494d5facdbe8473e74127b838c2d446ecec0ce262e2eddafa77259cb::event::LiquidationEvent'
'0x1e4a13a0494d5facdbe8473e74127b838c2d446ecec0ce262e2eddafa77259cb::event::FlashLoan'
'0x1e4a13a0494d5facdbe8473e74127b838c2d446ecec0ce262e2eddafa77259cb::event::RewardClaimed'

-- Original direct lending (legacy)
'0xd899cf7d2b5db716bd2cf55599fb0d5ee38a3061e7b6bb6eebf73fa5bc4c81ca::lending::DepositEvent'
'0xd899cf7d2b5db716bd2cf55599fb0d5ee38a3061e7b6bb6eebf73fa5bc4c81ca::lending::WithdrawEvent'
'0xd899cf7d2b5db716bd2cf55599fb0d5ee38a3061e7b6bb6eebf73fa5bc4c81ca::lending::BorrowEvent'
'0xd899cf7d2b5db716bd2cf55599fb0d5ee38a3061e7b6bb6eebf73fa5bc4c81ca::lending::RepayEvent'

-- On-behalf-of (sender = keeper, real user in event_json.user)
'0x7c9b90b3fda0fa4aa8ee88ae6c4a0b83c773f74936b5354448cb94662e94442d::lending::DepositOnBehalfOfEvent'
'0x7c9b90b3fda0fa4aa8ee88ae6c4a0b83c773f74936b5354448cb94662e94442d::lending::RepayOnBehalfOfEvent'
```

### Sender vs user — OnBehalfOf distinction

For Era 1 and current-package events, `sender` = acting user. Standard:
```sql
concat('0x', lower(to_hex(sender))) AS wallet
```

For on-behalf events, `sender` is a keeper/vault and the real user is in `event_json.user`:
```sql
lower(json_extract_scalar(event_json, '$.user')) AS wallet
```

Merge carefully when unioning — different extraction per branch.

## Navi 4-Stage Dynamic Pipeline (V8)

This is the validated production pipeline that achieves 100% asset coverage on a $235M protocol with no third-party indexer, no hardcoded balances, no hardcoded symbols. Refreshes on every query execution.

> **V9 (June 2026) extends this** to all of Navi's markets (Main + 3 isolated → 48 reserves) and switches pricing to Navi's on-chain `PriceOracle`. See § "Navi isolated markets" (above) and § "Navi on-chain PriceOracle" (below); worked queries `examples/navi-v9-multimarket.sql` (live) and `examples/navi-v9-multimarket-historical.sql` (90-day). The V8 description below is Main-only and Pyth-priced (preserved in `examples/legacy/navi-v8-pipeline.sql`).

**Why dynamic:** Navi pre-Feb-2026 events don't include USD values. Without LiveFetch, you can't reconstruct current TVL from indexed tables alone. The 4-stage pipeline solves this entirely from on-chain primitives.

### The four stages

1. **`suix_getDynamicFields`** → discovers all 35 ReserveData object IDs from the reserves table object [1 RPC call]
2. **`sui_multiGetObjects`** → batches state of all 35 reserves in one RPC call (supply, borrow, rates, LTV, supplier counts) [1 RPC call]
3. **`suix_getCoinMetadata` × 35 parallel** → resolves canonical symbols (solves the `::coin::COIN` problem where bridged tokens like enzoBTC, wUSDC, WETH all share a generic module name) [35 parallel calls]
4. **Pyth Hermes API** → oracle prices for long-tail assets (NAVX, XAUM gold, broader ETH) using the same Pyth feeds Navi consumes internally [1 HTTP call with multiple feed IDs]

### Full SQL

```sql
WITH
-- ===== Stage 1: Discover all ReserveData object IDs =====
field_response AS (
  SELECT http_post(
    'https://fullnode.mainnet.sui.io:443',
    '{"jsonrpc":"2.0","id":1,"method":"suix_getDynamicFields","params":["0xe6d4c6610b86ce7735ea754596d71d72d10c7980b5052fc3c8cdf8d09fea9b4b",null,50]}',
    ARRAY['Content-Type: application/json']
  ) AS resp
),
field_objects AS (
  SELECT
    cast(json_extract_scalar(field_json, '$.name.value') AS INTEGER) AS asset_id,
    json_extract_scalar(field_json, '$.objectId') AS object_id
  FROM field_response,
       UNNEST(CAST(json_extract(resp, '$.result.data') AS array(json))) t(field_json)
),

-- ===== Stage 2: Batch-fetch all reserves' state =====
ids_payload AS (
  SELECT '[' || array_join(array_agg('"' || object_id || '"'), ',') || ']' AS ids_json
  FROM field_objects
),
all_reserves_response AS (
  SELECT http_post(
    'https://fullnode.mainnet.sui.io:443',
    '{"jsonrpc":"2.0","id":1,"method":"sui_multiGetObjects","params":['
      || (SELECT ids_json FROM ids_payload)
      || ',{"showType":true,"showContent":true}]}',
    ARRAY['Content-Type: application/json']
  ) AS resp
),
parsed AS (
  SELECT
    cast(json_extract_scalar(obj_json, '$.data.content.fields.value.fields.id') AS INTEGER) AS asset_id,
    json_extract_scalar(obj_json, '$.data.content.fields.value.fields.coin_type') AS coin_type_full,
    split_part(json_extract_scalar(obj_json, '$.data.content.fields.value.fields.coin_type'), '::', 1) AS addr_raw,
    -- Navi-9 normalization: total_supply is SCALED by 1e9 internally regardless of token decimals.
    -- True native amount = (raw / 1e9) × (index / 1e27). The index is a ray-encoded interest
    -- accumulator that starts at 1.0 and grows as interest accrues. Skipping the index multiplication
    -- silently under-reports older reserves by 5-11%.
    try_cast(json_extract_scalar(obj_json, '$.data.content.fields.value.fields.supply_balance.fields.total_supply') AS DOUBLE) / 1e9
      * try_cast(json_extract_scalar(obj_json, '$.data.content.fields.value.fields.current_supply_index') AS DOUBLE) / 1e27 AS supply_native,
    try_cast(json_extract_scalar(obj_json, '$.data.content.fields.value.fields.borrow_balance.fields.total_supply') AS DOUBLE) / 1e9
      * try_cast(json_extract_scalar(obj_json, '$.data.content.fields.value.fields.current_borrow_index') AS DOUBLE) / 1e27 AS borrow_native,
    -- Rate ray-encoding: divide by 1e25 to get APR percent
    try_cast(json_extract_scalar(obj_json, '$.data.content.fields.value.fields.current_supply_rate') AS DOUBLE) / 1e25 AS supply_apr_pct,
    try_cast(json_extract_scalar(obj_json, '$.data.content.fields.value.fields.current_borrow_rate') AS DOUBLE) / 1e25 AS borrow_apr_pct,
    try_cast(json_extract_scalar(obj_json, '$.data.content.fields.value.fields.ltv') AS DOUBLE) / 1e25 AS ltv_pct,
    -- Bonus dimension: per-asset supplier/borrower counts (data Navi's API doesn't expose)
    try_cast(json_extract_scalar(obj_json, '$.data.content.fields.value.fields.supply_balance.fields.user_state.fields.size') AS BIGINT) AS supplier_count,
    try_cast(json_extract_scalar(obj_json, '$.data.content.fields.value.fields.borrow_balance.fields.user_state.fields.size') AS BIGINT) AS borrower_count
  FROM all_reserves_response,
       UNNEST(CAST(json_extract(resp, '$.result') AS array(json))) t(obj_json)
),
-- Sui address normalization: short-form for system addresses, full-length for normal
parsed_with_addr AS (
  SELECT *,
    CASE WHEN length(ltrim(addr_raw, '0')) <= 3
         THEN '0x' || COALESCE(NULLIF(ltrim(addr_raw, '0'), ''), '0')
         ELSE '0x' || addr_raw END AS coin_address_canonical
  FROM parsed
),

-- ===== Stage 3: Coin metadata for canonical symbols =====
metadata_raw AS (
  SELECT
    asset_id,
    coin_type_full,
    coin_address_canonical,
    http_post(
      'https://fullnode.mainnet.sui.io:443',
      '{"jsonrpc":"2.0","id":1,"method":"suix_getCoinMetadata","params":["'
        || coin_address_canonical
        || '::' || split_part(coin_type_full, '::', 2)
        || '::' || split_part(coin_type_full, '::', 3)
        || '"]}',
      ARRAY['Content-Type: application/json']
    ) AS meta_resp
  FROM parsed_with_addr
),
metadata AS (
  SELECT
    asset_id,
    json_extract_scalar(meta_resp, '$.result.symbol') AS true_symbol,
    json_extract_scalar(meta_resp, '$.result.name') AS true_name
  FROM metadata_raw
),

-- ===== Stage 4: Pyth Hermes oracle prices for long-tail =====
hermes_response AS (
  SELECT http_get(
    'https://hermes.pyth.network/v2/updates/price/latest'
      || '?ids[]=88250f854c019ef4f88a5c073d52a18bb1c6ac437033f5932cd017d24917ab46'  -- NAVX/USD
      || '&ids[]=d7db067954e28f51a96fd50c6d51775094025ced2d60af61ec9803e553471c88' -- XAU/USD
      || '&ids[]=e62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43' -- BTC/USD
      || '&ids[]=ff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace' -- ETH/USD
      || '&parsed=true',
    ARRAY['Content-Type: application/json']
  ) AS resp
),
pyth_prices AS (
  SELECT
    json_extract_scalar(item, '$.id') AS feed_id,
    try_cast(json_extract_scalar(item, '$.price.price') AS DOUBLE)
      * power(10.0, try_cast(json_extract_scalar(item, '$.price.expo') AS INTEGER)) AS price
  FROM hermes_response,
       UNNEST(CAST(json_extract(resp, '$.parsed') AS array(json))) t(item)
),
pyth_pivoted AS (
  SELECT
    MAX(CASE WHEN feed_id = '88250f854c019ef4f88a5c073d52a18bb1c6ac437033f5932cd017d24917ab46' THEN price END) AS navx_pyth,
    MAX(CASE WHEN feed_id = 'd7db067954e28f51a96fd50c6d51775094025ced2d60af61ec9803e553471c88' THEN price END) AS xaum_pyth,
    MAX(CASE WHEN feed_id = 'e62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43' THEN price END) AS btc_pyth,
    MAX(CASE WHEN feed_id = 'ff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace' THEN price END) AS eth_pyth
  FROM pyth_prices
),

-- ===== Sui-token prices from prices.hour (primary) =====
prices_sui AS (
  SELECT contract_address_hex, price_usd
  FROM (
    SELECT
      contract_address_varchar AS contract_address_hex,
      price AS price_usd, timestamp,
      ROW_NUMBER() OVER (PARTITION BY contract_address_varchar ORDER BY timestamp DESC) AS rn
    FROM prices.hour
    WHERE blockchain = 'sui' AND timestamp >= CURRENT_TIMESTAMP - INTERVAL '24' HOUR
  )
  WHERE rn = 1
),

-- Cross-chain benchmark prices (with Pyth fallback for staleness)
benchmarks AS (
  SELECT
    AVG(CASE WHEN symbol = 'BTC' AND blockchain = 'bitcoin' THEN price END) AS btc_price_dune,
    AVG(CASE WHEN symbol = 'SOL' AND blockchain = 'solana' THEN price END) AS sol_price,
    AVG(CASE WHEN symbol = 'SUI' AND blockchain = 'sui' THEN price END) AS sui_price
  FROM prices.hour
  WHERE timestamp >= CURRENT_TIMESTAMP - INTERVAL '6' HOUR
    AND symbol IN ('BTC','SOL','SUI')
),

joined AS (
  SELECT
    p.*,
    m.true_symbol,
    pl.price_usd AS sui_match_price,
    -- Cascading fallbacks: prices.hour → Pyth → benchmark
    COALESCE(
      pl.price_usd,
      CASE WHEN upper(m.true_symbol) IN ('VSUI','HASUI','STSUI','CERT','SPRING_SUI','SPSUI','MSUI','KSUI','AFSUI','TRSUI') THEN b.sui_price END,
      CASE WHEN upper(m.true_symbol) LIKE '%BTC%' THEN COALESCE(py.btc_pyth, b.btc_price_dune) END,
      CASE WHEN upper(m.true_symbol) IN ('ETH','WETH','SUIETH','LZETH','LZWETH') THEN py.eth_pyth END,
      CASE WHEN upper(m.true_symbol) LIKE '%USD%' OR upper(m.true_symbol) IN ('AUSD','BUCK','DAI','FRAX','USDB','USDC','USDT','SUSDE') THEN 1.0 END,
      CASE WHEN upper(m.true_symbol) IN ('SOL','WSOL','LZSOL') THEN b.sol_price END,
      CASE WHEN upper(m.true_symbol) = 'NAVX' THEN py.navx_pyth END,
      CASE WHEN upper(m.true_symbol) IN ('XAUM','XAU') THEN py.xaum_pyth END
    ) AS price_effective,
    -- Audit trail: where did each price come from?
    CASE
      WHEN pl.price_usd IS NOT NULL THEN 'prices.hour:sui'
      WHEN upper(m.true_symbol) IN ('VSUI','HASUI','STSUI','CERT','SPRING_SUI') THEN 'fallback:SUI'
      WHEN upper(m.true_symbol) LIKE '%BTC%' THEN 'pyth:BTC'
      WHEN upper(m.true_symbol) IN ('ETH','WETH','SUIETH') THEN 'pyth:ETH'
      WHEN upper(m.true_symbol) LIKE '%USD%' THEN 'fallback:$1'
      WHEN upper(m.true_symbol) = 'NAVX' THEN 'pyth:NAVX'
      WHEN upper(m.true_symbol) IN ('XAUM','XAU') THEN 'pyth:XAU'
      ELSE 'unmatched'
    END AS price_source
  FROM parsed_with_addr p
  LEFT JOIN metadata m ON m.asset_id = p.asset_id
  LEFT JOIN prices_sui pl ON pl.contract_address_hex = '0x' || to_hex(to_utf8(p.coin_address_canonical))
  CROSS JOIN benchmarks b
  CROSS JOIN pyth_pivoted py
)

SELECT
  asset_id,
  COALESCE(true_symbol, split_part(coin_type_full, '::', 3)) AS symbol,
  ROUND(supply_native, 2) AS supply_native,
  ROUND(borrow_native, 2) AS borrow_native,
  ROUND(price_effective, 4) AS price_usd,
  ROUND(supply_native * price_effective, 0) AS supply_usd,
  ROUND(borrow_native * price_effective, 0) AS borrow_usd,
  ROUND(supply_apr_pct, 2) AS supply_apr_pct,
  ROUND(borrow_apr_pct, 2) AS borrow_apr_pct,
  CASE WHEN supply_native > 0 THEN ROUND(borrow_native * 100.0 / supply_native, 2) ELSE 0 END AS utilization_pct,
  supplier_count,
  borrower_count,
  price_source
FROM joined
ORDER BY supply_usd DESC NULLS LAST
```

### Key technical discoveries (validated April 2026)

1. **Navi-9 normalization + index multiplication.** Navi stores `total_supply` as a SCALED value, normalized to 9-decimal precision regardless of token decimals. To get the actual underlying native amount, two operations are required:

   ```
   actual_native = (raw_total_supply / 1e9) × (current_supply_index / 1e27)
   ```

   The `current_supply_index` and `current_borrow_index` fields are ray-encoded interest accumulators (start at 1.0 at reserve genesis, grow over time as interest accrues — same convention as Aave's `liquidityIndex`/`variableBorrowIndex`). Without the index multiplication, supply/borrow for older reserves are silently under-reported by 5–11%: SUI's supply index reached ~1.09 after 3 years at ~2.3% APR; DEEP and WAL drift ~9%.

   The bug hides on recent BTC reserves: enzoBTC, MBTC, xBTC, WBTC (sui_bridge) all have index ≈ 1.00 (low rate × short history), so they appear correct even when the index is skipped. Older + higher-rate reserves are where the discrepancy compounds. Verification approach: sum `supply_usd × ... ` across all reserves and compare to Navi's portal "Total Supply" headline. Pre-fix totals were ~$215M against frontend $243M; post-fix totals match within 0.2%.

2. **Ray-encoded rates.** Rates use 1e27 scaling: `rate / 1e25 = APR percent` (the `/1e25` is `/1e27 * 100`). Same for LTV.

3. **`prices.hour` double-encodes addresses.** Stored as `'0x' || to_hex(to_utf8('0x' || canonical_addr))`. SUI's `0x2` becomes `0x307832`. Join via `'0x' || to_hex(to_utf8(canonical_addr))`.

4. **Sui address normalization.** Short-form ONLY for system addresses (≤3 chars after stripping leading zeros). Full-length addresses preserve leading zeros.

5. **Bonus dimension: supplier/borrower counts.** `supply_balance.user_state.size` and `borrow_balance.user_state.size` give per-asset cumulative counts that Navi's public API doesn't expose. SUI shows 862K suppliers / 88K borrowers; BUCK shows 695 / 1,417.

6. **The `::coin::COIN` problem.** Bridged tokens (wUSDC, wUSDT, WETH, enzoBTC, SOL on Sui) all use a generic `coin` package with module `COIN`. You can't identify them from `coin_type` alone — you must call `suix_getCoinMetadata` to get the canonical symbol. This is why Stage 3 is required.

7. **`sui.objects.object_json` JSON paths differ from RPC.** Critical when porting V8-style parsing to historical replay. `sui.objects` strips both the RPC's `$.data.content` wrapper AND all `.fields` indirection — paths become much shorter:

   | Field | RPC path (V8) | `sui.objects` path (V9.5+) |
   |-------|---------------|----------------------------|
   | Supply total | `$.data.content.fields.value.fields.supply_balance.fields.total_supply` | `$.value.supply_balance.total_supply` |
   | Borrow total | `$.data.content.fields.value.fields.borrow_balance.fields.total_supply` | `$.value.borrow_balance.total_supply` |
   | Supply index | `$.data.content.fields.value.fields.current_supply_index` | `$.value.current_supply_index` |
   | Borrow index | `$.data.content.fields.value.fields.current_borrow_index` | `$.value.current_borrow_index` |
   | Supply rate | `$.data.content.fields.value.fields.current_supply_rate` | `$.value.current_supply_rate` |
   | Supplier count | `$.data.content.fields.value.fields.supply_balance.fields.user_state.fields.size` | `$.value.supply_balance.user_state.size` |
   | Coin type | `$.data.content.fields.value.fields.coin_type` | `$.value.coin_type` |
   | LTV | `$.data.content.fields.value.fields.ltv` | `$.value.ltv` |

   Divisors (`/1e9`, `/1e25`, `/1e27`) carry over identically — only the JSON paths change.

   **`coin_type` formatting also differs:** `sui.objects.object_json` returns `coin_type` without the `0x` prefix (e.g., `"0000...0002::sui::SUI"`), while the RPC response includes `0x`. Apply the same address-canonicalization CASE block from V8 (short-form for system addresses, full-length for normal) on top.

8. **3-package union is events-only.** Navi's 3-package history (pre-Feb-2026, on-behalf-of, post-migration) applies to *events* — the EmitEventCommand source changes when Navi deploys new packages. **Reserve objects are stable across the migration:** all 35 reserves still carry the legacy struct type `0x2::dynamic_field::Field<u8, 0xd899cf7d::storage::ReserveData>` even after the package upgrades. In-place upgrades change event emission, not existing object types. This means historical state replay via `sui.objects` needs **zero** era-handling logic — only event-based queries (activity, flows, liquidations) require the 3-package union.

9. **Anti-pattern: DuneSQL re-fires `http_post` in any CTE referenced more than once.** DuneSQL/Trino *inlines* CTEs instead of materializing them, and it does **not** de-duplicate identical LiveFetch calls. So if a CTE whose subtree contains `http_post` is consumed by two downstream branches, every `http_post` in that subtree fires *again* — once per reference, multiplied along each inlining path. The V9 multi-market draft hit this: referencing `reserve_fields` (discovery → `getDynamicFields`) and `parsed_with_addr` (`multiGetObjects`) from two branches each multiplied the discovery fan-out past the per-query LiveFetch cap, even though the logical call count was only ~20.
   - **Symptom:** `"Your query issued too many HTTP requests"` on a query whose hand-counted calls are well under the cap (or credits/runtime far above the call count).
   - **Fix:** **Linearize to single-reference** — each `http_post`-bearing CTE consumed exactly once. Carry the join key *on the request row* (per-market `sui_multiGetObjects` fanned out over markets returns rows already tagged with `market_id`) instead of re-joining a discovery CTE downstream; pull any other downstream key (e.g. `asset_id` from `value.fields.id`) out of the response you already fetched, never by re-referencing the fetch.
   - **The one unavoidable doubling:** `nextCursor` pagination must read page-0's response for BOTH its data rows AND its `hasNextPage`/cursor → 2 references → page-0 (and its discovery ancestors) fire twice. Budget for it: cap the page chain (2 pages today) and keep discovery cheap so even doubled it stays under the cap.

### V0.2 — Historical replay (DONE, May 2026)

Historical Navi TVL is now solved via **indexed `sui.objects` replay**, not the originally proposed `sui_tryGetPastObject` approach. The pivot was forced by Mysten's public RPC rejecting JSON-RPC 2.0 batching (error `-32005`, verified May 18 2026) — a naive `N days × 35 reserves` parallel-call pipeline would flake at scale.

**Architecture (live in `query_7528506`):**

| Stage | What it does | Cost |
|-------|--------------|------|
| 0 | Date dimension via `UNNEST(SEQUENCE(...))` | 0 |
| 1 | Reserve ID discovery via `suix_getDynamicFields` (same as V8 stage 1) | 1 RPC |
| 2 | Per-(date, reserve) end-of-day state from `sui.objects` with `ROW_NUMBER() OVER (PARTITION BY date, object_id ORDER BY version DESC)` filtered to `rn = 1` | 0 RPC, ~50–200 credits depending on window |
| 3 | `suix_getCoinMetadata` for `::coin::COIN` reserves only (~7 calls instead of 35; native-named reserves use the struct name directly) | 7 RPC |
| 4a | `prices.hour` historical via `DATE(timestamp)` + window function for per-date last-hour price | 0 RPC |
| 4b | Pyth Benchmarks TradingView shim (one call per feed, returns full window in single response) | 7 HTTP |
| 5 | Cascade: `prices.hour` → Pyth Benchmarks per-asset → benchmark fallback → `$1` stable → unmatched audit flag | 0 |

**Key constraint reminder:** Mysten's public RPC does NOT support JSON-RPC 2.0 batching. Any pipeline doing `N parallel http_post` calls into `fullnode.mainnet.sui.io` will fail at scale. Indexed `sui.objects` replay sidesteps this completely.

Verified at 90-day scale (3,150 rows) in May 2026; cost ~210 credits per run, matches Navi frontend Total Supply to 0.2%.

- **Pure-Pyth pricing** (superseded by V9 on-chain oracle, below): Read all Pyth feed IDs from Navi's oracle registry on-chain, batch in one Hermes call. Gives confidence intervals (`conf`) and EMA prices.

### Navi on-chain PriceOracle (V9 primary pricing)

V8 priced via Pyth Hermes + Dune `prices.hour`. V9 makes Navi's **own on-chain oracle the primary source** — it's the exact price Navi uses for accounting/liquidations, so reconciliation against Navi's portal/API is near-exact, and it has **no null** for metals/RWA where Pyth Benchmarks fails (XAU/XAG).

- Object `0x1568865ed9a0b5ec414220e8f79b3d04c77acc82358f6e5ae4635687392ffbef`, type `0xca441b44…::oracle::PriceOracle`. Field `price_oracles: Table<u8, Price>` (inner table `0xc0601facd3b98d1e82905e660bf9f5998097dedcf86ed802cf485865e3e3667c`) keyed by each reserve's `oracle_id`. Each `Price` = `{ value, decimal, timestamp }`; **USD price = `value / 10^decimal`**.
- Verified (2026-06): XAUM(31)≈$4,347, XAGM(36)≈$73, eACRED(35)≈$1,100, suiUSDe(33)≈$1 — matches open-api's per-pool `oracle.price` exactly.
- **Live snapshot (V9):** read the `price_oracles` table directly (getObject → getDynamicFields → one `sui_multiGetObjects`) → `oracle_id → price`. Cheap. The Pyth Hermes CTE is **deleted** (a "fallback" `http_post` still fires every run + carries ~4% flake); `prices.hour` retained as a *free* table-read fallback; `'unmatched'` is the safety tag.
- **Historical replay (V9):** the oracle's `Price` entries are dynamic-field objects, so daily history is recoverable from `sui.objects`. **But the oracle updates every tick — 90-day version counts are huge (XAUM 313K, eACRED 232K rows).** So the replay is **scoped to the 3 metals/RWA objects Benchmarks can't price**, selected by `WHERE object_id IN (…)` (**not** by `type_`):

  | asset | oracle_id | Price object_id |
  |---|---|---|
  | XAUM (gold) | 31 | `0x74f5a7897fbb664bf9e37c76fe1ccb663d39184d9a8487c8ab716160d25ab23c` |
  | eACRED | 35 | `0x089ff8cc084a74fbc1309944e671da9ce658c4a9999aebf519371a5351c9942a` |
  | XAGM (silver) | 36 | `0xc9d6a0f4bd6a6e880eee6c334e8c46bceacced637476f9e1ea7e305b66df97a0` |

  Cost: **3 objects = 170 credits** (under the ~230 baseline); replaying all ~37 oracle objects would blow it. Every fed asset stays on `prices.hour → Pyth Benchmarks`. **Maintainer note:** this historical oracle scope is **hardcoded to these three Price object_ids**. A new metals/RWA asset **without a Benchmarks feed** will surface as `unmatched` in the historical replay (fail-loud) until its Price object_id is added to this list.
- **Never zero-fill:** a missing price (e.g. eACRED 2026-04-15 — a one-day gap in the oracle's own update stream) leaves `price_usd`/`tvl_usd` NULL and `unpriced=true` — surfaced, not silently filled.

### Asset list (Navi mid-2026)

**Stablecoins (10):** USDC, wUSDC (Wormhole), USDT, suiUSDT (native), USDSUI (Sui-native stable), BUCK (Bucket CDP), USDY (Ondo yield-bearing), suiUSDe (Ethena), FDUSD, AUSD

**SUI family (4):** SUI, vSUI (Volo LST), haSUI (Haedal LST), stSUI

**BTC variants (9):** WBTC, wBTC, xBTC, stBTC, LBTC, enzoBTC, MBTC, YBTC, YBTC.B

**Other (12):** WETH, ETH (Sui Bridge), NAVX, CETUS, DEEP, NS, BLUE, WAL, IKA, SOL (Wormhole), XAUM (gold), HAEDAL

## Comparing Suilend vs Navi

When building comparative dashboards, internalize the asymmetry:

| Dimension | Suilend | Navi |
|-----------|---------|------|
| TVL (Apr 2026) | ~$192M | ~$235M |
| USD pre-computed in events? | **Yes** (Pyth in `ReserveAssetDataEvent`) | **No** (raw amounts only) |
| Historical TVL replay | Trivial via events (USD pre-computed) | Tractable via `sui.objects` indexed replay + Pyth Benchmarks historical (V0.2 of this skill) |
| Activity model | `obligation_id` (one wallet → many positions) | One wallet ≈ one position |
| Active positions / wallet | ~10 (LST loops, STEAMM AMM) | ~1 |
| BTC variant share | ~9% | ~38% (multi-BTC hub) |
| SUI family share | ~55% (SUI maximalist) | ~27% |
| Stablecoin yield-bearing share | ~0% | ~40% (BUCK / USDY / suiUSDe) |
| Stablecoin native share | ~100% | ~55% |
| Asset count | ~30 | ~35 |
| Mysten Labs investor? | Yes (Dec 2024 round) | Yes |

The narrative for a comparative dashboard:
- **Suilend = SUI maximalists / power-user platform** — LST yield loops, multi-position obligations, native stables only
- **Navi = BTC holders + yield seekers / broader retail** — multi-BTC hub, isolated markets, yield-bearing stables
- Both ~$200M TVL, similar wallet counts, very different user archetypes

## Useful Public Dune Query References

- `7377142` — Navi V8.1 4-stage dynamic pipeline (current snapshot, validated against Navi portal to 0.2%; **v8.1 May 2026** added index multiplication fix + USDY Pyth feed)
- `7528506` — **Navi V9.5.2 historical TVL replay** (90-day daily, end-of-day per reserve, via `sui.objects` + Pyth Benchmarks; matches Navi portal Total Supply within 0.2%)
- `6852115` — Navi daily new vs returning wallets (legitimate Navi query, demonstrates 3-package union)
- `6852920` — mementomori "Navi daily TVL by asset" (actually Suilend — see investigation note above)
