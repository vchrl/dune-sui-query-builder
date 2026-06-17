-- =====================================================================
-- Navi V9 Multi-Market Pipeline  —  DRAFT (finalized r3)
-- branch: v0.3.0-isolated-markets   |   is_temp clone of query 7377142
-- Dune draft query: 7739371   (https://dune.com/queries/7739371)
-- =====================================================================
--
-- Extends V8.1 (Main-only, 35 reserves) to ALL markets discovered on-chain:
--   market 0 Main, 1 Ember, 2 Matrixdock, 3 Sui Eco  → 48 reserves total.
--
-- VALIDATION (r3, run 2026-06-17):
--   §V1 reconciliation vs Navi open-api, SAME MOMENT:
--        Main 0.000% | Ember 0.000% | Matrixdock 0.000% | Sui Eco 0.011% | TOTAL 0.000%  (gate ≤0.5% PASS)
--        isolated-only total = $1,143,549 (≈ $1.14M)
--   §V2 re-key: 48 rows / 48 distinct object_ids; asset_id=0 → 4 separate rows
--        (Main/SUI, Ember/USDC, Matrixdock/USDC, Sui Eco/SUI). PASS.
--   §V3 oracle vs prices.hour (Main): median 1.219%, max 2.097% (DEEP). 12/17 >0.5%, all
--        small/volatile — expected DEX-spot-vs-oracle spread; §V1=0.000% vs Navi's own oracle
--        API confirms the oracle is the correct TVL basis. Oracle-primary stands (C-validation).
--   cost: 0.362 credits (medium engine).
--
-- DESIGN — single-reference / linear (see protocol-patterns.md "Key technical discoveries" #9):
--   DuneSQL re-fires http_post in any CTE referenced >1×. market_id rides on each per-market
--   multiGetObjects row (no join-back); asset_id comes from the response. ~31 calls (pagination
--   reads page-0 twice → discovery fires twice; still well under the LiveFetch cap).
--
-- Pricing PRIMARY = Navi on-chain PriceOracle keyed by oracle_id. Pyth Hermes CTE DELETED.
--   prices.hour kept as a FREE (table-read) fallback only. 'unmatched' = safety tag.
-- Symbols: static coin_type→symbol map for ::coin::COIN bridged tokens (zero RPC), fallback to
--   struct name; new bridged asset → struct name ("COIN"), never breaks.
--
-- DRAFT-ONLY: oracle_price_check / prices_hour_check / oracle_vs_phour_pct are the §V3
--   cross-validation columns — REMOVE before production promotion.
-- =====================================================================

WITH
-- Stage 0: dynamic market discovery (MarketCreated events → tx objectChanges → Storage → reserves table)
market_events AS (
  SELECT cast(json_extract_scalar(ev, '$.parsedJson.market_id') AS INTEGER) AS market_id,
         json_extract_scalar(ev, '$.id.txDigest') AS tx_digest
  FROM (SELECT http_post('https://fullnode.mainnet.sui.io:443',
      '{"jsonrpc":"2.0","id":1,"method":"suix_queryEvents","params":[{"MoveEventType":"0x1e4a13a0494d5facdbe8473e74127b838c2d446ecec0ce262e2eddafa77259cb::event::MarketCreated"},null,50,false]}',
      ARRAY['Content-Type: application/json']) AS resp) e,
  UNNEST(CAST(json_extract(resp, '$.result.data') AS array(json))) t(ev)
),
market_txs AS (
  SELECT market_id, http_post('https://fullnode.mainnet.sui.io:443',
      '{"jsonrpc":"2.0","id":1,"method":"sui_getTransactionBlock","params":["' || tx_digest || '",{"showObjectChanges":true}]}',
      ARRAY['Content-Type: application/json']) AS resp
  FROM market_events
),
isolated_storages AS (
  SELECT market_id, json_extract_scalar(chg, '$.objectId') AS storage_id
  FROM market_txs, UNNEST(CAST(json_extract(resp, '$.result.objectChanges') AS array(json))) t(chg)
  WHERE json_extract_scalar(chg, '$.type') = 'created'
    AND json_extract_scalar(chg, '$.objectType') LIKE '%::storage::Storage'
),
all_storages AS (   -- Main (market 0) is module-init, emits NO event: add explicitly
  SELECT 0 AS market_id, '0xbb4e2f4b6205c2e2a2db47aeb4f830796ec7c005f88537ee775986639bc442fe' AS storage_id
  UNION ALL SELECT market_id, storage_id FROM isolated_storages
),
storage_objects AS (
  SELECT market_id, http_post('https://fullnode.mainnet.sui.io:443',
      '{"jsonrpc":"2.0","id":1,"method":"sui_getObject","params":["' || storage_id || '",{"showContent":true}]}',
      ARRAY['Content-Type: application/json']) AS resp
  FROM all_storages
),
reserve_tables AS (
  SELECT market_id, json_extract_scalar(resp, '$.result.data.content.fields.reserves.fields.id.id') AS reserves_table_id
  FROM storage_objects
),
-- Stage 1: reserve object ids per table, with GATED nextCursor pagination.
-- df1 fires only for tables with hasNextPage=true (none today; prevents silent overflow when a market >50).
-- df0_meta is read by both reserve_fields and df1_in (2 refs) → page-0 + discovery fire twice (~31 calls total).
df0 AS (
  SELECT market_id, reserves_table_id, http_post('https://fullnode.mainnet.sui.io:443',
      '{"jsonrpc":"2.0","id":1,"method":"suix_getDynamicFields","params":["' || reserves_table_id || '",null,50]}',
      ARRAY['Content-Type: application/json']) AS resp
  FROM reserve_tables
),
df0_meta AS (
  SELECT market_id, reserves_table_id,
    json_extract(resp, '$.result.data') AS data_json,
    json_extract_scalar(resp, '$.result.hasNextPage') AS has_next,
    json_extract_scalar(resp, '$.result.nextCursor') AS cursor
  FROM df0
),
df1_in AS (
  SELECT market_id, reserves_table_id, cursor FROM df0_meta WHERE has_next = 'true'
),
df1 AS (
  SELECT market_id, http_post('https://fullnode.mainnet.sui.io:443',
      '{"jsonrpc":"2.0","id":1,"method":"suix_getDynamicFields","params":["' || reserves_table_id || '","' || cursor || '",50]}',
      ARRAY['Content-Type: application/json']) AS resp
  FROM df1_in   -- cursor format (objectId string) to confirm on Dune the first time a market exceeds 50
),
reserve_fields AS (
  SELECT market_id, json_extract_scalar(fj, '$.objectId') AS object_id
  FROM df0_meta, UNNEST(CAST(data_json AS array(json))) t(fj)
  UNION ALL
  SELECT market_id, json_extract_scalar(fj, '$.objectId')
  FROM df1, UNNEST(CAST(json_extract(resp, '$.result.data') AS array(json))) t(fj)
),
-- Stage 2: per-market multiGetObjects (market_id rides on the row → single-reference)
mkt_payloads AS (
  SELECT market_id, '[' || array_join(array_agg('"' || object_id || '"'), ',') || ']' AS ids_json
  FROM reserve_fields GROUP BY market_id
),
reserves_response AS (
  SELECT market_id, http_post('https://fullnode.mainnet.sui.io:443',
    '{"jsonrpc":"2.0","id":1,"method":"sui_multiGetObjects","params":[' || ids_json || ',{"showType":true,"showContent":true}]}',
    ARRAY['Content-Type: application/json']) AS resp
  FROM mkt_payloads
),
parsed AS (
  SELECT
    market_id,
    json_extract_scalar(o, '$.data.objectId') AS object_id,
    cast(json_extract_scalar(o, '$.data.content.fields.value.fields.id') AS INTEGER) AS asset_id,
    cast(json_extract_scalar(o, '$.data.content.fields.value.fields.oracle_id') AS INTEGER) AS oracle_id,
    json_extract_scalar(o, '$.data.content.fields.value.fields.coin_type') AS coin_type_full,
    split_part(json_extract_scalar(o, '$.data.content.fields.value.fields.coin_type'), '::', 3) AS symbol_raw,
    -- Navi-9 normalization + index multiplication (PRESERVED)
    try_cast(json_extract_scalar(o, '$.data.content.fields.value.fields.supply_balance.fields.total_supply') AS DOUBLE) / 1e9
      * try_cast(json_extract_scalar(o, '$.data.content.fields.value.fields.current_supply_index') AS DOUBLE) / 1e27 AS supply_native,
    try_cast(json_extract_scalar(o, '$.data.content.fields.value.fields.borrow_balance.fields.total_supply') AS DOUBLE) / 1e9
      * try_cast(json_extract_scalar(o, '$.data.content.fields.value.fields.current_borrow_index') AS DOUBLE) / 1e27 AS borrow_native,
    try_cast(json_extract_scalar(o, '$.data.content.fields.value.fields.current_supply_rate') AS DOUBLE) / 1e25 AS supply_apr_pct,
    try_cast(json_extract_scalar(o, '$.data.content.fields.value.fields.current_borrow_rate') AS DOUBLE) / 1e25 AS borrow_apr_pct,
    try_cast(json_extract_scalar(o, '$.data.content.fields.value.fields.supply_balance.fields.user_state.fields.size') AS BIGINT) AS supplier_count,
    try_cast(json_extract_scalar(o, '$.data.content.fields.value.fields.borrow_balance.fields.user_state.fields.size') AS BIGINT) AS borrower_count
  FROM reserves_response, UNNEST(CAST(json_extract(resp, '$.result') AS array(json))) t(o)
),
parsed_with_addr AS (
  SELECT p.*,
    CASE WHEN length(ltrim(split_part(p.coin_type_full, '::', 1), '0')) <= 3
         THEN '0x' || COALESCE(NULLIF(ltrim(split_part(p.coin_type_full, '::', 1), '0'), ''), '0')
         ELSE '0x' || split_part(p.coin_type_full, '::', 1) END AS coin_address_canonical
  FROM parsed p
),
-- Static ::coin::COIN symbol map (sourced from getCoinMetadata; zero RPC). Fallback = struct name.
symbol_map AS (
  SELECT * FROM (VALUES
    ('8f2b5eb696ed88b71fea398d330bccfa52f6e2a5a8e1ac6180fcb25c6de42ebc::coin::COIN','enzoBTC'),
    ('5d4b302506645c37ff133b98c4b50a5ae14841659738d6d733d59d0d217a93bf::coin::COIN','wUSDC'),
    ('c060006111016b8a020ad5b33834984a437aaa7d3c74c18e09a95d48aceab08c::coin::COIN','wUSDT'),
    ('af8cd5edc19c4512f4259f0bee101a40d41ebed738ade5874359610ef8eeced5::coin::COIN','WETH'),
    ('5f496ed5d9d045c5b788dc1bb85f54100f2ede11e46f6a232c29daada4c5bdb6::coin::COIN','stBTC'),
    ('027792d9fed7f9844eb4839566001bb6f6cb4804f66aa2da6fe1ee242d896881::coin::COIN','WBTC'),
    ('b7844e289a8410e50fb3ca48d69eb9cf29e27d223ef90353fe1bd8e27ff8f3f8::coin::COIN','SOL')
  ) AS t(coin_type, symbol)
),
-- Stage 4: Navi on-chain PriceOracle — PRIMARY, keyed by oracle_id (value / 10^decimal)
oracle_root AS (
  SELECT http_post('https://fullnode.mainnet.sui.io:443',
    '{"jsonrpc":"2.0","id":1,"method":"sui_getObject","params":["0x1568865ed9a0b5ec414220e8f79b3d04c77acc82358f6e5ae4635687392ffbef",{"showContent":true}]}',
    ARRAY['Content-Type: application/json']) AS resp
),
oracle_table AS (
  SELECT json_extract_scalar(resp, '$.result.data.content.fields.price_oracles.fields.id.id') AS oracle_table_id FROM oracle_root
),
oracle_fields AS (
  SELECT cast(json_extract_scalar(f, '$.name.value') AS INTEGER) AS oracle_id,
         json_extract_scalar(f, '$.objectId') AS price_object_id
  FROM (SELECT http_post('https://fullnode.mainnet.sui.io:443',
      '{"jsonrpc":"2.0","id":1,"method":"suix_getDynamicFields","params":["' || (SELECT oracle_table_id FROM oracle_table) || '",null,50]}',
      ARRAY['Content-Type: application/json']) AS resp) r,
  UNNEST(CAST(json_extract(resp, '$.result.data') AS array(json))) t(f)
),
oracle_ids_payload AS (
  SELECT '[' || array_join(array_agg('"' || price_object_id || '"'), ',') || ']' AS ids_json FROM oracle_fields
),
oracle_prices_resp AS (
  SELECT http_post('https://fullnode.mainnet.sui.io:443',
    '{"jsonrpc":"2.0","id":1,"method":"sui_multiGetObjects","params":[' || (SELECT ids_json FROM oracle_ids_payload) || ',{"showContent":true}]}',
    ARRAY['Content-Type: application/json']) AS resp
),
oracle_prices AS (
  SELECT cast(json_extract_scalar(o, '$.data.content.fields.name') AS INTEGER) AS oracle_id,
    try_cast(json_extract_scalar(o, '$.data.content.fields.value.fields.value') AS DOUBLE)
      / power(10.0, try_cast(json_extract_scalar(o, '$.data.content.fields.value.fields.decimal') AS INTEGER)) AS oracle_price,
    try_cast(json_extract_scalar(o, '$.data.content.fields.value.fields.timestamp') AS BIGINT) AS oracle_ts
  FROM oracle_prices_resp, UNNEST(CAST(json_extract(resp, '$.result') AS array(json))) t(o)
),
prices_sui AS (
  SELECT contract_address_hex, price_usd FROM (
    SELECT contract_address_varchar AS contract_address_hex, price AS price_usd,
           ROW_NUMBER() OVER (PARTITION BY contract_address_varchar ORDER BY timestamp DESC) AS rn
    FROM prices.hour WHERE blockchain = 'sui' AND timestamp >= CURRENT_TIMESTAMP - INTERVAL '24' HOUR
  ) WHERE rn = 1
),
joined AS (
  SELECT p.*,
    COALESCE(sm.symbol, p.symbol_raw) AS symbol,
    op.oracle_price, op.oracle_ts, pl.price_usd AS prices_hour_price,
    COALESCE(
      op.oracle_price, pl.price_usd,
      CASE WHEN upper(COALESCE(sm.symbol, p.symbol_raw)) LIKE '%USD%' OR upper(COALESCE(sm.symbol, p.symbol_raw)) IN ('AUSD','BUCK') THEN 1.0 END
    ) AS price_effective,
    CASE WHEN op.oracle_price IS NOT NULL THEN 'navi_oracle:' || cast(p.oracle_id AS varchar)
         WHEN pl.price_usd IS NOT NULL THEN 'prices.hour:sui'
         WHEN upper(COALESCE(sm.symbol, p.symbol_raw)) LIKE '%USD%' THEN 'fallback:$1'
         ELSE 'unmatched' END AS price_source
  FROM parsed_with_addr p
  LEFT JOIN symbol_map sm ON sm.coin_type = p.coin_type_full
  LEFT JOIN oracle_prices op ON op.oracle_id = p.oracle_id
  LEFT JOIN prices_sui pl ON pl.contract_address_hex = '0x' || to_hex(to_utf8(p.coin_address_canonical))
),
market_names AS (
  SELECT * FROM (VALUES (0,'Main'),(1,'Ember'),(2,'Matrixdock'),(3,'Sui Eco')) AS t(market_id, market_name)
)
SELECT
  j.market_id,
  COALESCE(mn.market_name, 'market ' || cast(j.market_id AS varchar)) AS market_name,
  j.asset_id, j.symbol,
  ROUND(j.supply_native, 2) AS supply_native,
  ROUND(j.price_effective, 4) AS price_usd,
  ROUND(j.supply_native * j.price_effective, 0) AS supply_usd,
  ROUND(j.borrow_native * j.price_effective, 0) AS borrow_usd,
  -- DRAFT-ONLY §V3 cross-validation (remove before production):
  ROUND(j.oracle_price, 4) AS oracle_price_check,
  ROUND(j.prices_hour_price, 4) AS prices_hour_check,
  CASE WHEN j.oracle_price IS NOT NULL AND j.prices_hour_price IS NOT NULL AND j.prices_hour_price <> 0
       THEN ROUND(abs(j.oracle_price - j.prices_hour_price) / j.prices_hour_price * 100, 3) END AS oracle_vs_phour_pct,
  j.price_source, j.object_id
FROM joined j
LEFT JOIN market_names mn ON mn.market_id = j.market_id
ORDER BY j.market_id, supply_usd DESC NULLS LAST
