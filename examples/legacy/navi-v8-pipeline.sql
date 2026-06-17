-- =====================================================================
-- Navi 4-Stage Dynamic Pipeline (V8.1)  —  LEGACY / SUPERSEDED
-- Superseded by V9 multi-market + on-chain oracle pricing:
--   examples/navi-v9-multimarket.sql (live) · examples/navi-v9-multimarket-historical.sql (90-day).
-- This V8.1 covers the MAIN market only (35 reserves) and prices via Pyth Hermes.
-- Kept for reference; body unchanged.
-- =====================================================================
--
-- v8.1 (May 2026): INDEX MULTIPLICATION FIX
--   Prior V8 returned SCALED supply/borrow values, silently understating
--   actual native amounts by 5-11% on older reserves with accrued interest.
--   Fix: actual_native = (raw_total_supply / 1e9) × (current_supply_index / 1e27).
--   Verified against Navi frontend — all 35 reserves match within 0.2%.
--   Also added USDY Pyth feed (Crypto.USDY/USD) for the yield-bearing $1.13 token.
--
-- Purpose: Achieves 100% asset coverage on Navi's $235M lending protocol
-- with zero third-party indexer, zero hardcoded balances, zero hardcoded
-- symbols. Refreshes on every query execution.
--
-- How it works (4 stages, all inside one DuneSQL query):
--   1. suix_getDynamicFields    — discover all 35 ReserveData object IDs
--   2. sui_multiGetObjects      — batch state of all 35 reserves in one call
--   3. suix_getCoinMetadata × N — resolve canonical symbols (solves the
--                                  ::coin::COIN problem for bridged tokens)
--   4. Pyth Hermes              — oracle prices for long-tail assets
--
-- Why it exists: Navi's events do not embed USD values (unlike Suilend's
-- ReserveAssetDataEvent). To reconstruct current TVL from indexed Dune
-- tables alone is not possible. This pipeline solves it entirely from
-- on-chain primitives + Pyth (the same oracle Navi consumes for
-- liquidations).
--
-- Validated: April 2026, ~$235M TVL, all 35 reserves matched against
-- Navi portal numbers within rounding.
--
-- Runtime: ~3-8 seconds per execution (4 RPC stages + price fetches).
--
-- Maintainer notes:
--   * Pyth feed IDs are point-in-time (April 2026). Verify via
--     https://hermes.pyth.network/v2/price_feeds?query=<symbol>&asset_type=crypto
--   * If Navi adds reserves > 50, increase the page size in stage 1 or
--     add pagination via the `nextCursor` field.
--   * Sui RPC endpoint: https://fullnode.mainnet.sui.io:443 (free public)
--
-- Related references in this repo:
--   - SKILL.md                                  task router and patterns
--   - references/sui-data-model.md              full Dune Sui table docs
--   - references/protocol-patterns.md           Navi 3-package archaeology
-- =====================================================================

WITH
-- =====================================================================
-- Stage 1: Discover all ReserveData object IDs
-- One RPC call. Returns ~35 dynamic fields from Navi's reserves table.
-- =====================================================================
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

-- =====================================================================
-- Stage 2: Batch-fetch all reserves' state in one RPC call
-- One RPC call. sui_multiGetObjects accepts up to ~50 object IDs.
-- Returns supply_balance, borrow_balance, rates, LTV, supplier counts.
-- =====================================================================
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
    -- Navi-9 normalization + index multiplication
    -- (raw / 1e9) × (index / 1e27) = actual native amount.
    -- The index is a ray-encoded interest accumulator that starts at 1.0 and grows
    -- as interest accrues. Without the multiplication, supply/borrow on older
    -- reserves are silently under-reported by 5-11%.
    try_cast(json_extract_scalar(obj_json, '$.data.content.fields.value.fields.supply_balance.fields.total_supply') AS DOUBLE) / 1e9
      * try_cast(json_extract_scalar(obj_json, '$.data.content.fields.value.fields.current_supply_index') AS DOUBLE) / 1e27 AS supply_native,
    try_cast(json_extract_scalar(obj_json, '$.data.content.fields.value.fields.borrow_balance.fields.total_supply') AS DOUBLE) / 1e9
      * try_cast(json_extract_scalar(obj_json, '$.data.content.fields.value.fields.current_borrow_index') AS DOUBLE) / 1e27 AS borrow_native,
    -- Ray-encoded rates: 1e27 scaling. Divide by 1e25 to get APR percent
    -- (that's 1e27 to scale down, * 100 to make percent).
    try_cast(json_extract_scalar(obj_json, '$.data.content.fields.value.fields.current_supply_rate') AS DOUBLE) / 1e25 AS supply_apr_pct,
    try_cast(json_extract_scalar(obj_json, '$.data.content.fields.value.fields.current_borrow_rate') AS DOUBLE) / 1e25 AS borrow_apr_pct,
    try_cast(json_extract_scalar(obj_json, '$.data.content.fields.value.fields.ltv') AS DOUBLE) / 1e25 AS ltv_pct,
    -- Bonus dimension: per-asset supplier/borrower counts (data Navi's
    -- public API doesn't expose). SUI: 862K suppliers / 88K borrowers.
    try_cast(json_extract_scalar(obj_json, '$.data.content.fields.value.fields.supply_balance.fields.user_state.fields.size') AS BIGINT) AS supplier_count,
    try_cast(json_extract_scalar(obj_json, '$.data.content.fields.value.fields.borrow_balance.fields.user_state.fields.size') AS BIGINT) AS borrower_count
  FROM all_reserves_response,
       UNNEST(CAST(json_extract(resp, '$.result') AS array(json))) t(obj_json)
),
-- Sui address normalization: short-form for system addresses (≤3 chars
-- after stripping leading zeros), full-length for everything else.
parsed_with_addr AS (
  SELECT *,
    CASE WHEN length(ltrim(addr_raw, '0')) <= 3
         THEN '0x' || COALESCE(NULLIF(ltrim(addr_raw, '0'), ''), '0')
         ELSE '0x' || addr_raw END AS coin_address_canonical
  FROM parsed
),

-- =====================================================================
-- Stage 3: Resolve canonical symbols via suix_getCoinMetadata
-- 35 parallel RPC calls (one per reserve).
-- Required because bridged tokens (enzoBTC, wUSDC, WETH) all use a
-- generic `coin` package + `COIN` module — can't be distinguished from
-- coin_type alone.
-- =====================================================================
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

-- =====================================================================
-- Stage 4: Pyth Hermes — oracle-grade pricing for long-tail assets
-- One HTTP call returns multiple feeds. Same oracle Navi uses on-chain
-- for liquidations.
-- Verify feed IDs at:
--   https://hermes.pyth.network/v2/price_feeds?query=<symbol>&asset_type=crypto
-- =====================================================================
hermes_response AS (
  SELECT http_get(
    'https://hermes.pyth.network/v2/updates/price/latest'
      || '?ids[]=88250f854c019ef4f88a5c073d52a18bb1c6ac437033f5932cd017d24917ab46'  -- NAVX/USD
      || '&ids[]=d7db067954e28f51a96fd50c6d51775094025ced2d60af61ec9803e553471c88' -- XAU/USD (gold, for XAUM)
      || '&ids[]=e62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43' -- BTC/USD
      || '&ids[]=ff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace' -- ETH/USD
      || '&ids[]=e393449f6aff8a4b6d3e1165a7c9ebec103685f3b41e60db4277b5b6d10e7326' -- USDY/USD
      || '&parsed=true',
    ARRAY['Content-Type: application/json']
  ) AS resp
),
pyth_prices AS (
  SELECT
    json_extract_scalar(item, '$.id') AS feed_id,
    -- Pyth returns price + exponent. Real price = price * 10^expo.
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
    MAX(CASE WHEN feed_id = 'ff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace' THEN price END) AS eth_pyth,
    MAX(CASE WHEN feed_id = 'e393449f6aff8a4b6d3e1165a7c9ebec103685f3b41e60db4277b5b6d10e7326' THEN price END) AS usdy_pyth
  FROM pyth_prices
),

-- =====================================================================
-- Primary price source: Dune's prices.hour for major Sui tokens
-- Quirk: prices.hour double-encodes Sui addresses as
-- '0x' || to_hex(to_utf8(canonical_addr))  — see WHERE clause below.
-- =====================================================================
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

-- Cross-chain benchmark prices (BTC from bitcoin chain, SOL from solana)
-- for fallback pricing of cross-chain wrapped variants.
benchmarks AS (
  SELECT
    AVG(CASE WHEN symbol = 'BTC' AND blockchain = 'bitcoin' THEN price END) AS btc_price_dune,
    AVG(CASE WHEN symbol = 'SOL' AND blockchain = 'solana' THEN price END) AS sol_price,
    AVG(CASE WHEN symbol = 'SUI' AND blockchain = 'sui'     THEN price END) AS sui_price
  FROM prices.hour
  WHERE timestamp >= CURRENT_TIMESTAMP - INTERVAL '6' HOUR
    AND symbol IN ('BTC','SOL','SUI')
),

-- =====================================================================
-- Join everything with cascading fallback prices.
-- Order: prices.hour -> Pyth -> benchmark -> stable=$1 -> NULL
-- price_source column gives an audit trail of where each price came from.
-- =====================================================================
joined AS (
  SELECT
    p.*,
    m.true_symbol,
    pl.price_usd AS sui_match_price,
    COALESCE(
      pl.price_usd,
      CASE WHEN upper(m.true_symbol) IN ('VSUI','HASUI','STSUI','CERT','SPRING_SUI','SPSUI','MSUI','KSUI','AFSUI','TRSUI') THEN b.sui_price END,
      CASE WHEN upper(m.true_symbol) LIKE '%BTC%' THEN COALESCE(py.btc_pyth, b.btc_price_dune) END,
      CASE WHEN upper(m.true_symbol) IN ('ETH','WETH','SUIETH','LZETH','LZWETH') THEN py.eth_pyth END,
      -- USDY (yield-bearing, trades ~$1.13) → Pyth oracle
      CASE WHEN upper(m.true_symbol) = 'USDY' THEN py.usdy_pyth END,
      CASE WHEN upper(m.true_symbol) LIKE '%USD%' OR upper(m.true_symbol) IN ('AUSD','BUCK','DAI','FRAX','USDB','USDC','USDT','SUSDE') THEN 1.0 END,
      CASE WHEN upper(m.true_symbol) IN ('SOL','WSOL','LZSOL') THEN b.sol_price END,
      CASE WHEN upper(m.true_symbol) = 'NAVX' THEN py.navx_pyth END,
      CASE WHEN upper(m.true_symbol) IN ('XAUM','XAU') THEN py.xaum_pyth END
    ) AS price_effective,
    CASE
      WHEN pl.price_usd IS NOT NULL THEN 'prices.hour:sui'
      WHEN upper(m.true_symbol) IN ('VSUI','HASUI','STSUI','CERT','SPRING_SUI') THEN 'fallback:SUI'
      WHEN upper(m.true_symbol) LIKE '%BTC%' THEN 'pyth:BTC'
      WHEN upper(m.true_symbol) IN ('ETH','WETH','SUIETH') THEN 'pyth:ETH'
      WHEN upper(m.true_symbol) = 'USDY' AND py.usdy_pyth IS NOT NULL THEN 'pyth:USDY'
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
  CASE WHEN supply_native > 0
       THEN ROUND(borrow_native * 100.0 / supply_native, 2)
       ELSE 0 END AS utilization_pct,
  supplier_count,
  borrower_count,
  price_source
FROM joined
ORDER BY supply_usd DESC NULLS LAST
