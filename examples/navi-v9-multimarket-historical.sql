-- =====================================================================
-- Navi V9 Multi-Market Historical TVL (90-day)  —  validated example
-- Extends 7528506 to all 4 markets; scoped on-chain-oracle replay for metals/RWA.
-- Mirrors validated query 7739975; the production historical query is 7528506
-- (promotion pending).
-- =====================================================================
--
-- Extends 7528506 (V9.6, Main-only) to ALL markets via the same proven
-- multi-market discovery as the live example (navi-v9-multimarket.sql).
--
-- VALIDATION (r2, run 2026-06-17):
--   * cost 170.261 credits (UNDER the ~230 baseline) | 3,569 rows | 4 markets (0/1/2/3)
--   * earliest date per market = first on-chain reserve state (matches MarketCreated):
--       Main 2026-03-20 (window start) | Ember 2026-04-14 | Matrixdock 2026-05-20 | Sui Eco 2026-05-26
--   * spot-check vs live (06-16 EOD vs live now): Ember 0.05% · Matrixdock 1.13% · Sui Eco 1.83%
--       (1-day price drift on volatile components; Ember stable-heavy → 0.05% proves methodology match)
--   * fail-loud: exactly 1 unpriced row of 3,569 — Ember eACRED 2026-04-15 (a genuine 1-day gap in
--       eACRED's oracle update stream; its Price object covers 64/65 days since launch). NOT zero-filled.
--
-- PRICING:
--   * SCOPED oracle replay from sui.objects for metals/RWA ONLY — XAUM(31)+eACRED(35)+XAGM(36),
--     selected by `WHERE object_id IN (3 Price object_ids)` (NOT by type_). These three are the
--     assets Pyth Benchmarks cannot price (XAU/XAG null; eACRED has no feed).
--     COST NOTE: oracle Price objects are version-heavy (XAUM 313K, eACRED 232K versions in 90d).
--     3 objects = 170 credits; replaying ALL ~37 oracle objects would blow the ~230 baseline —
--     hence the scope. (The LIVE snapshot reads the oracle table directly, which is cheap.)
--   * Every FED asset (all of Main + Sui Eco's 7) stays on the proven prices.hour → Pyth Benchmarks
--     cascade, unchanged from 7528506.
--   * NEVER zero-fill: a missing price leaves price_usd/tvl_usd NULL and unpriced=true (fail-loud).
--
-- DISCOVERY + RE-KEY: identical to the live draft. Each market is a separate shared
--   `0xd899cf7d…::storage::Storage` object; reserve objects are byte-identical
--   `0x2::dynamic_field::Field<u8, 0xd899cf7d…::storage::ReserveData>`. asset_id (u8) collides
--   across markets, so everything is keyed on the reserve object_id (here: from_hex(substr(id,3))
--   to join sui.objects.object_id varbinary). market_id rides each row from discovery.
-- =====================================================================

WITH
market_events AS (
  SELECT cast(json_extract_scalar(ev,'$.parsedJson.market_id') AS INTEGER) AS market_id,
         json_extract_scalar(ev,'$.id.txDigest') AS tx_digest
  FROM (SELECT http_post('https://fullnode.mainnet.sui.io:443',
      '{"jsonrpc":"2.0","id":1,"method":"suix_queryEvents","params":[{"MoveEventType":"0x1e4a13a0494d5facdbe8473e74127b838c2d446ecec0ce262e2eddafa77259cb::event::MarketCreated"},null,50,false]}',
      ARRAY['Content-Type: application/json']) AS resp) e,
  UNNEST(CAST(json_extract(resp,'$.result.data') AS array(json))) t(ev)
),
market_txs AS (
  SELECT market_id, http_post('https://fullnode.mainnet.sui.io:443',
      '{"jsonrpc":"2.0","id":1,"method":"sui_getTransactionBlock","params":["' || tx_digest || '",{"showObjectChanges":true}]}',
      ARRAY['Content-Type: application/json']) AS resp
  FROM market_events
),
isolated_storages AS (
  SELECT market_id, json_extract_scalar(chg,'$.objectId') AS storage_id
  FROM market_txs, UNNEST(CAST(json_extract(resp,'$.result.objectChanges') AS array(json))) t(chg)
  WHERE json_extract_scalar(chg,'$.type')='created' AND json_extract_scalar(chg,'$.objectType') LIKE '%::storage::Storage'
),
all_storages AS (
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
  SELECT market_id, json_extract_scalar(resp,'$.result.data.content.fields.reserves.fields.id.id') AS reserves_table_id
  FROM storage_objects
),
df0 AS (
  SELECT market_id, reserves_table_id, http_post('https://fullnode.mainnet.sui.io:443',
      '{"jsonrpc":"2.0","id":1,"method":"suix_getDynamicFields","params":["' || reserves_table_id || '",null,50]}',
      ARRAY['Content-Type: application/json']) AS resp
  FROM reserve_tables
),
df0_meta AS (
  SELECT market_id, reserves_table_id,
    json_extract(resp,'$.result.data') AS data_json,
    json_extract_scalar(resp,'$.result.hasNextPage') AS has_next,
    json_extract_scalar(resp,'$.result.nextCursor') AS cursor
  FROM df0
),
df1_in AS ( SELECT market_id, reserves_table_id, cursor FROM df0_meta WHERE has_next='true' ),
df1 AS (
  SELECT market_id, http_post('https://fullnode.mainnet.sui.io:443',
      '{"jsonrpc":"2.0","id":1,"method":"suix_getDynamicFields","params":["' || reserves_table_id || '","' || cursor || '",50]}',
      ARRAY['Content-Type: application/json']) AS resp
  FROM df1_in
),
field_objects AS (
  SELECT market_id, from_hex(substr(object_id, 3)) AS object_id_binary FROM (
    SELECT market_id, json_extract_scalar(fj,'$.objectId') AS object_id FROM df0_meta, UNNEST(CAST(data_json AS array(json))) t(fj)
    UNION ALL
    SELECT market_id, json_extract_scalar(fj,'$.objectId') FROM df1, UNNEST(CAST(json_extract(resp,'$.result.data') AS array(json))) t(fj)
  )
),
historical_state_raw AS (
  SELECT o.date, o.object_id, o.version, o.object_json, f.market_id,
    ROW_NUMBER() OVER (PARTITION BY o.date, o.object_id ORDER BY o.version DESC) AS rn
  FROM sui.objects o
  INNER JOIN field_objects f ON o.object_id = f.object_id_binary
  WHERE o.date >= CURRENT_DATE - INTERVAL '89' DAY
),
parsed_state AS (
  SELECT h.date, h.market_id,
    cast(json_extract_scalar(h.object_json,'$.value.id') AS INTEGER) AS asset_id,
    cast(json_extract_scalar(h.object_json,'$.value.oracle_id') AS INTEGER) AS oracle_id,
    json_extract_scalar(h.object_json,'$.value.coin_type') AS coin_type_full,
    try_cast(json_extract_scalar(h.object_json,'$.value.supply_balance.total_supply') AS DOUBLE)/1e9 AS supply_scaled,
    try_cast(json_extract_scalar(h.object_json,'$.value.borrow_balance.total_supply') AS DOUBLE)/1e9 AS borrow_scaled,
    try_cast(json_extract_scalar(h.object_json,'$.value.current_supply_index') AS DOUBLE)/1e27 AS supply_index,
    try_cast(json_extract_scalar(h.object_json,'$.value.current_borrow_index') AS DOUBLE)/1e27 AS borrow_index,
    try_cast(json_extract_scalar(h.object_json,'$.value.current_supply_rate') AS DOUBLE)/1e25 AS supply_apr_pct,
    try_cast(json_extract_scalar(h.object_json,'$.value.current_borrow_rate') AS DOUBLE)/1e25 AS borrow_apr_pct
  FROM historical_state_raw h WHERE h.rn=1
),
parsed_with_addr AS (
  SELECT date, market_id, asset_id, oracle_id, coin_type_full,
    supply_scaled*supply_index AS supply_native,
    borrow_scaled*borrow_index AS borrow_native,
    supply_apr_pct, borrow_apr_pct,
    split_part(coin_type_full,'::',3) AS symbol_raw,
    CASE WHEN length(ltrim(split_part(coin_type_full,'::',1),'0')) <= 3
         THEN '0x'||COALESCE(NULLIF(ltrim(split_part(coin_type_full,'::',1),'0'),''),'0')
         ELSE '0x'||split_part(coin_type_full,'::',1) END AS coin_address_canonical
  FROM parsed_state
),
-- Scoped oracle replay: XAUM(31)+eACRED(35)+XAGM(36) Price objects ONLY (WHERE object_id IN ...; no type_ filter)
oracle_state_raw AS (
  SELECT o.date, o.object_id, o.version, o.object_json,
    ROW_NUMBER() OVER (PARTITION BY o.date, o.object_id ORDER BY o.version DESC) AS rn
  FROM sui.objects o
  WHERE o.object_id IN (
      from_hex('74f5a7897fbb664bf9e37c76fe1ccb663d39184d9a8487c8ab716160d25ab23c'),  -- XAUM  oracle 31
      from_hex('089ff8cc084a74fbc1309944e671da9ce658c4a9999aebf519371a5351c9942a'),  -- eACRED oracle 35
      from_hex('c9d6a0f4bd6a6e880eee6c334e8c46bceacced637476f9e1ea7e305b66df97a0')   -- XAGM  oracle 36
    ) AND o.date >= CURRENT_DATE - INTERVAL '89' DAY
),
oracle_prices_daily AS (
  SELECT date,
    CASE WHEN object_id = from_hex('74f5a7897fbb664bf9e37c76fe1ccb663d39184d9a8487c8ab716160d25ab23c') THEN 31
         WHEN object_id = from_hex('089ff8cc084a74fbc1309944e671da9ce658c4a9999aebf519371a5351c9942a') THEN 35
         WHEN object_id = from_hex('c9d6a0f4bd6a6e880eee6c334e8c46bceacced637476f9e1ea7e305b66df97a0') THEN 36 END AS oracle_id,
    try_cast(json_extract_scalar(object_json,'$.value.value') AS DOUBLE)
      / power(10.0, try_cast(json_extract_scalar(object_json,'$.value.decimal') AS INTEGER)) AS oracle_price
  FROM oracle_state_raw WHERE rn=1
),
prices_hour_ranked AS (
  SELECT DATE(timestamp) AS price_date, contract_address_varchar, price,
    ROW_NUMBER() OVER (PARTITION BY DATE(timestamp), contract_address_varchar ORDER BY timestamp DESC) AS rn
  FROM prices.hour WHERE blockchain='sui' AND timestamp >= CURRENT_TIMESTAMP - INTERVAL '91' DAY
),
prices_sui_daily AS ( SELECT price_date, contract_address_varchar, price FROM prices_hour_ranked WHERE rn=1 ),
pyth_btc_resp AS (SELECT http_get('https://benchmarks.pyth.network/v1/shims/tradingview/history?symbol=Crypto.BTC%2FUSD&resolution=1D&from='||cast(cast(to_unixtime(cast(CURRENT_DATE - INTERVAL '91' DAY AS timestamp)) AS bigint) AS varchar)||'&to='||cast(cast(to_unixtime(CURRENT_TIMESTAMP) AS bigint) AS varchar), ARRAY['Content-Type: application/json']) AS resp),
pyth_eth_resp AS (SELECT http_get('https://benchmarks.pyth.network/v1/shims/tradingview/history?symbol=Crypto.ETH%2FUSD&resolution=1D&from='||cast(cast(to_unixtime(cast(CURRENT_DATE - INTERVAL '91' DAY AS timestamp)) AS bigint) AS varchar)||'&to='||cast(cast(to_unixtime(CURRENT_TIMESTAMP) AS bigint) AS varchar), ARRAY['Content-Type: application/json']) AS resp),
pyth_sui_resp AS (SELECT http_get('https://benchmarks.pyth.network/v1/shims/tradingview/history?symbol=Crypto.SUI%2FUSD&resolution=1D&from='||cast(cast(to_unixtime(cast(CURRENT_DATE - INTERVAL '91' DAY AS timestamp)) AS bigint) AS varchar)||'&to='||cast(cast(to_unixtime(CURRENT_TIMESTAMP) AS bigint) AS varchar), ARRAY['Content-Type: application/json']) AS resp),
pyth_sol_resp AS (SELECT http_get('https://benchmarks.pyth.network/v1/shims/tradingview/history?symbol=Crypto.SOL%2FUSD&resolution=1D&from='||cast(cast(to_unixtime(cast(CURRENT_DATE - INTERVAL '91' DAY AS timestamp)) AS bigint) AS varchar)||'&to='||cast(cast(to_unixtime(CURRENT_TIMESTAMP) AS bigint) AS varchar), ARRAY['Content-Type: application/json']) AS resp),
pyth_navx_resp AS (SELECT http_get('https://benchmarks.pyth.network/v1/shims/tradingview/history?symbol=Crypto.NAVX%2FUSD&resolution=1D&from='||cast(cast(to_unixtime(cast(CURRENT_DATE - INTERVAL '91' DAY AS timestamp)) AS bigint) AS varchar)||'&to='||cast(cast(to_unixtime(CURRENT_TIMESTAMP) AS bigint) AS varchar), ARRAY['Content-Type: application/json']) AS resp),
pyth_xau_resp AS (SELECT http_get('https://benchmarks.pyth.network/v1/shims/tradingview/history?symbol=Metal.XAU%2FUSD&resolution=1D&from='||cast(cast(to_unixtime(cast(CURRENT_DATE - INTERVAL '91' DAY AS timestamp)) AS bigint) AS varchar)||'&to='||cast(cast(to_unixtime(CURRENT_TIMESTAMP) AS bigint) AS varchar), ARRAY['Content-Type: application/json']) AS resp),
pyth_usdy_resp AS (SELECT http_get('https://benchmarks.pyth.network/v1/shims/tradingview/history?symbol=Crypto.USDY%2FUSD&resolution=1D&from='||cast(cast(to_unixtime(cast(CURRENT_DATE - INTERVAL '91' DAY AS timestamp)) AS bigint) AS varchar)||'&to='||cast(cast(to_unixtime(CURRENT_TIMESTAMP) AS bigint) AS varchar), ARRAY['Content-Type: application/json']) AS resp),
pyth_unioned AS (
  SELECT DATE(from_unixtime(t_val)) AS price_date, c_val AS price, 'BTC' AS feed FROM pyth_btc_resp, UNNEST(CAST(json_extract(resp,'$.t') AS array(bigint)), CAST(json_extract(resp,'$.c') AS array(double))) AS t(t_val,c_val)
  UNION ALL SELECT DATE(from_unixtime(t_val)), c_val, 'ETH' FROM pyth_eth_resp, UNNEST(CAST(json_extract(resp,'$.t') AS array(bigint)), CAST(json_extract(resp,'$.c') AS array(double))) AS t(t_val,c_val)
  UNION ALL SELECT DATE(from_unixtime(t_val)), c_val, 'SUI' FROM pyth_sui_resp, UNNEST(CAST(json_extract(resp,'$.t') AS array(bigint)), CAST(json_extract(resp,'$.c') AS array(double))) AS t(t_val,c_val)
  UNION ALL SELECT DATE(from_unixtime(t_val)), c_val, 'SOL' FROM pyth_sol_resp, UNNEST(CAST(json_extract(resp,'$.t') AS array(bigint)), CAST(json_extract(resp,'$.c') AS array(double))) AS t(t_val,c_val)
  UNION ALL SELECT DATE(from_unixtime(t_val)), c_val, 'NAVX' FROM pyth_navx_resp, UNNEST(CAST(json_extract(resp,'$.t') AS array(bigint)), CAST(json_extract(resp,'$.c') AS array(double))) AS t(t_val,c_val)
  UNION ALL SELECT DATE(from_unixtime(t_val)), c_val, 'XAU' FROM pyth_xau_resp, UNNEST(CAST(json_extract(resp,'$.t') AS array(bigint)), CAST(json_extract(resp,'$.c') AS array(double))) AS t(t_val,c_val)
  UNION ALL SELECT DATE(from_unixtime(t_val)), c_val, 'USDY' FROM pyth_usdy_resp, UNNEST(CAST(json_extract(resp,'$.t') AS array(bigint)), CAST(json_extract(resp,'$.c') AS array(double))) AS t(t_val,c_val)
),
pyth_pivoted AS (
  SELECT price_date,
    MAX(CASE WHEN feed='BTC' THEN price END) AS btc_pyth, MAX(CASE WHEN feed='ETH' THEN price END) AS eth_pyth,
    MAX(CASE WHEN feed='SUI' THEN price END) AS sui_pyth, MAX(CASE WHEN feed='SOL' THEN price END) AS sol_pyth,
    MAX(CASE WHEN feed='NAVX' THEN price END) AS navx_pyth, MAX(CASE WHEN feed='XAU' THEN price END) AS xau_pyth,
    MAX(CASE WHEN feed='USDY' THEN price END) AS usdy_pyth
  FROM pyth_unioned GROUP BY price_date
),
-- Static ::coin::COIN symbol map (from getCoinMetadata; zero RPC), fallback = struct name.
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
joined AS (
  SELECT p.date, p.market_id, p.asset_id, p.oracle_id, p.coin_type_full,
    COALESCE(sm.symbol, p.symbol_raw) AS symbol,
    p.supply_native, p.borrow_native, p.supply_apr_pct, p.borrow_apr_pct,
    orp.oracle_price, ph.price AS prices_hour_price,
    COALESCE(
      CASE WHEN p.oracle_id IN (31,35,36) THEN orp.oracle_price END,
      ph.price,
      CASE WHEN upper(COALESCE(sm.symbol,p.symbol_raw)) LIKE '%BTC%' THEN py.btc_pyth END,
      CASE WHEN upper(COALESCE(sm.symbol,p.symbol_raw)) IN ('ETH','WETH','SUIETH') THEN py.eth_pyth END,
      CASE WHEN upper(COALESCE(sm.symbol,p.symbol_raw)) IN ('SOL','WSOL') THEN py.sol_pyth END,
      CASE WHEN upper(COALESCE(sm.symbol,p.symbol_raw))='NAVX' THEN py.navx_pyth END,
      CASE WHEN upper(COALESCE(sm.symbol,p.symbol_raw)) IN ('XAUM','XAU') THEN py.xau_pyth END,
      CASE WHEN upper(COALESCE(sm.symbol,p.symbol_raw))='USDY' THEN py.usdy_pyth END,
      CASE WHEN upper(COALESCE(sm.symbol,p.symbol_raw)) IN ('VSUI','HASUI','STSUI','CERT','SPRING_SUI') THEN py.sui_pyth END,
      CASE WHEN upper(COALESCE(sm.symbol,p.symbol_raw)) LIKE '%USD%' OR upper(COALESCE(sm.symbol,p.symbol_raw)) IN ('AUSD','BUCK') THEN 1.0 END
    ) AS price_effective,
    CASE
      WHEN p.oracle_id IN (31,35,36) AND orp.oracle_price IS NOT NULL THEN 'navi_oracle:'||cast(p.oracle_id AS varchar)
      WHEN ph.price IS NOT NULL THEN 'prices.hour:sui'
      WHEN upper(COALESCE(sm.symbol,p.symbol_raw)) LIKE '%BTC%' AND py.btc_pyth IS NOT NULL THEN 'pyth:BTC'
      WHEN upper(COALESCE(sm.symbol,p.symbol_raw)) IN ('ETH','WETH','SUIETH') AND py.eth_pyth IS NOT NULL THEN 'pyth:ETH'
      WHEN upper(COALESCE(sm.symbol,p.symbol_raw)) IN ('SOL','WSOL') AND py.sol_pyth IS NOT NULL THEN 'pyth:SOL'
      WHEN upper(COALESCE(sm.symbol,p.symbol_raw))='NAVX' AND py.navx_pyth IS NOT NULL THEN 'pyth:NAVX'
      WHEN upper(COALESCE(sm.symbol,p.symbol_raw)) IN ('XAUM','XAU') AND py.xau_pyth IS NOT NULL THEN 'pyth:XAU'
      WHEN upper(COALESCE(sm.symbol,p.symbol_raw))='USDY' AND py.usdy_pyth IS NOT NULL THEN 'pyth:USDY'
      WHEN upper(COALESCE(sm.symbol,p.symbol_raw)) IN ('VSUI','HASUI','STSUI','CERT','SPRING_SUI') AND py.sui_pyth IS NOT NULL THEN 'pyth:SUI(LST)'
      WHEN upper(COALESCE(sm.symbol,p.symbol_raw)) LIKE '%USD%' OR upper(COALESCE(sm.symbol,p.symbol_raw)) IN ('AUSD','BUCK') THEN 'fallback:$1'
      ELSE 'unmatched'
    END AS price_source
  FROM parsed_with_addr p
  LEFT JOIN symbol_map sm ON sm.coin_type = p.coin_type_full
  LEFT JOIN oracle_prices_daily orp ON orp.oracle_id = p.oracle_id AND orp.date = p.date
  LEFT JOIN prices_sui_daily ph ON ph.price_date = p.date AND ph.contract_address_varchar = '0x'||to_hex(to_utf8(p.coin_address_canonical))
  LEFT JOIN pyth_pivoted py ON py.price_date = p.date
),
market_names AS ( SELECT * FROM (VALUES (0,'Main'),(1,'Ember'),(2,'Matrixdock'),(3,'Sui Eco')) AS t(market_id, market_name) ),
final AS (
  SELECT j.date, j.market_id, COALESCE(mn.market_name,'market '||cast(j.market_id AS varchar)) AS market_name,
    j.asset_id, j.symbol,
    ROUND(j.supply_native,2) AS supply_native, ROUND(j.borrow_native,2) AS borrow_native,
    ROUND(j.price_effective,6) AS price_usd,
    ROUND(j.supply_native*j.price_effective,0) AS supply_usd,
    ROUND(j.borrow_native*j.price_effective,0) AS borrow_usd,
    ROUND((j.supply_native-j.borrow_native)*j.price_effective,0) AS tvl_usd,   -- NULL (never 0) when price missing
    j.price_source,
    (j.price_effective IS NULL) AS unpriced
  FROM joined j LEFT JOIN market_names mn ON mn.market_id = j.market_id
)
SELECT * FROM final ORDER BY date DESC, market_id, supply_usd DESC NULLS LAST
