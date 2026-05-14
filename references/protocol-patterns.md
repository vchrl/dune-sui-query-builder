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

Before doing any Navi or Suilend work on Dune, **be aware of this**: the most-cited "Navi Protocol" dashboard on Dune ([dune.com/mementomori7777/navi-protocol-full-dashboard](https://dune.com/mementomori7777/navi-protocol-full-dashboard), ~50K views, 19 charts, maintained by Prudentia Labs) is actually querying **Suilend's** event package the entire time.

Evidence: the core query points at `0xf95b06141ed4a174f239417323bde3f209b972f5930d8521ea38a52aff3a6ddf::reserve::ReserveAssetDataEvent`. Triple-confirmed:
- Suilend SDK docs reference this exact package as Suilend's main pool
- Suilend GitHub repo (`github.com/suilend/suilend`) confirms the modules `lending_market`, `reserve`, `obligation` under this package
- DefiLlama, Bybit Learn, and the Suilend documentation all match
- Mysten Labs is a Suilend investor (Dec 2024 $6M round)

Real Navi packages are `0x1e4a13a0...` (events) and `0xd899cf7d...` (legacy storage type). The `0xf95b06141...` package has nothing to do with Navi.

**Practical implications:**
- When asked to "build a Navi dashboard," verify the package hexes before using any reference SQL
- When asked to "improve / clone / fix" the mementomori dashboard, the right answer is often "rebuild it correctly because it's a different protocol"
- This mislabel is a strong differentiation hook — calling it out demonstrates investigative rigor

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

This is the entry point for LiveFetch pipelines — call `suix_getDynamicFields` on it to discover all 35 ReserveData child objects.

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
    -- Navi-9 normalization: total_supply scaled by 1e9 internally regardless of token decimals
    try_cast(json_extract_scalar(obj_json, '$.data.content.fields.value.fields.supply_balance.fields.total_supply') AS DOUBLE) / 1e9 AS supply_native,
    try_cast(json_extract_scalar(obj_json, '$.data.content.fields.value.fields.borrow_balance.fields.total_supply') AS DOUBLE) / 1e9 AS borrow_native,
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

1. **Navi-9 normalization.** Navi normalizes all `total_supply` values to 9-decimal precision regardless of token decimals. Raw / 1e9 = native amount for all assets — SUI, USDC, xBTC, DEEP all match Navi portal after this divisor.

2. **Ray-encoded rates.** Rates use 1e27 scaling: `rate / 1e25 = APR percent` (the `/1e25` is `/1e27 * 100`). Same for LTV.

3. **`prices.hour` double-encodes addresses.** Stored as `'0x' || to_hex(to_utf8('0x' || canonical_addr))`. SUI's `0x2` becomes `0x307832`. Join via `'0x' || to_hex(to_utf8(canonical_addr))`.

4. **Sui address normalization.** Short-form ONLY for system addresses (≤3 chars after stripping leading zeros). Full-length addresses preserve leading zeros.

5. **Bonus dimension: supplier/borrower counts.** `supply_balance.user_state.size` and `borrow_balance.user_state.size` give per-asset cumulative counts that Navi's public API doesn't expose. SUI shows 862K suppliers / 88K borrowers; BUCK shows 695 / 1,417.

6. **The `::coin::COIN` problem.** Bridged tokens (wUSDC, wUSDT, WETH, enzoBTC, SOL on Sui) all use a generic `coin` package with module `COIN`. You can't identify them from `coin_type` alone — you must call `suix_getCoinMetadata` to get the canonical symbol. This is why Stage 3 is required.

### What v2 would do (next iteration, not yet built)

- **Pure-Pyth pricing** instead of `prices.hour` + Pyth hybrid. Read all Pyth feed IDs from Navi's oracle registry on-chain (one extra RPC stage), batch them all in one Hermes call. Gives you confidence intervals (`conf`) and EMA prices.
- **Historical Navi TVL** via `sui_tryGetPastObject` snapshots. Map dates → checkpoints → object versions, snapshot each reserve once per day. Same 4-stage architecture with a date dimension.

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
| Historical TVL replay | Trivial via events | Hard — needs `sui_tryGetPastObject` or flow accounting |
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

- `7377142` — Navi V8 4-stage dynamic pipeline (validated, 100% asset coverage on $235M)
- `6852115` — Navi daily new vs returning wallets (legitimate Navi query, demonstrates 3-package union)
- `6852920` — mementomori "Navi daily TVL by asset" (actually Suilend — see investigation note above)
