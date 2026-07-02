-- ============================================================================
-- Suilend liquidations, priced per event (materialized-view source)
-- ----------------------------------------------------------------------------
-- Source:   Dune query 7756564 (public, owner 0x_vcharles). Validated 2026-06-19.
-- Feeds:    materialized view  dune."0x_vcharles".result_suilend_liquidations
--           (98,081 rows, full history from 2024-03-13).
-- Verified: independent raw-events recount matched exactly
--           (98,081 liquidations / 15,710 obligations / 204 liquidators, zero diff);
--           stablecoins (~81% of debt repaid) matched raw token face value within 0.05%.
-- Pattern:  protocol-native pricing with the cToken-vs-underlying distinction.
--           This is the correctness core for Suilend; see protocol-patterns.md.
-- ============================================================================

-- Suilend realized liquidations, one row per LiquidateEvent, priced in USD.
-- Package 0xf95b06141ed4a174f239417323bde3f209b972f5930d8521ea38a52aff3a6ddf
-- Pricing is protocol-native and priced at the SAME-TRANSACTION reserve mark (not the day's
-- last snapshot): Suilend refreshes both the repay and withdraw reserve inside every liquidate()
-- tx, so each reserve's own supply_amount_usd_estimate from that same transaction_digest gives
--   USD per underlying base unit  = supply_amount_usd_estimate / supply_amount   (debt side)
--   USD per cTOKEN base unit      = (supply_amount_usd_estimate / 1e18) / ctoken_supply  (collateral/fee/bonus side)
-- repay_amount is underlying base units; withdraw/fee/bonus are cTOKEN base units (Suilend liquidate() carves
-- protocol fee + liquidator bonus out of the seized cTokens), so the cTOKEN unit price is the correct one.
WITH
liq AS (
  SELECT
    date AS day,
    transaction_digest,
    concat('0x', lower(to_hex(sender))) AS liquidator,
    json_extract_scalar(event_json, '$.lending_market_id')        AS lending_market_id,
    json_extract_scalar(event_json, '$.obligation_id')            AS obligation_id,
    json_extract_scalar(event_json, '$.repay_reserve_id')         AS repay_reserve_id,
    json_extract_scalar(event_json, '$.withdraw_reserve_id')      AS withdraw_reserve_id,
    json_extract_scalar(event_json, '$.repay_coin_type.name')     AS repay_coin_type,
    json_extract_scalar(event_json, '$.withdraw_coin_type.name')  AS withdraw_coin_type,
    try_cast(json_extract_scalar(event_json, '$.repay_amount') AS double)            AS repay_amount,
    try_cast(json_extract_scalar(event_json, '$.withdraw_amount') AS double)         AS withdraw_amount,
    try_cast(json_extract_scalar(event_json, '$.protocol_fee_amount') AS double)     AS protocol_fee_amount,
    try_cast(json_extract_scalar(event_json, '$.liquidator_bonus_amount') AS double) AS liquidator_bonus_amount
  FROM sui.events
  WHERE date >= DATE '2024-03-01'
    AND event_type = '0xf95b06141ed4a174f239417323bde3f209b972f5930d8521ea38a52aff3a6ddf::lending_market::LiquidateEvent'
),
reserve_snap AS (
  SELECT transaction_digest, reserve_id, usd_per_underlying_base, usd_per_ctoken_base FROM (
    SELECT
      transaction_digest,
      json_extract_scalar(event_json, '$.reserve_id') AS reserve_id,
      try_cast(json_extract_scalar(event_json, '$.supply_amount_usd_estimate.value') AS double)
        / nullif(try_cast(json_extract_scalar(event_json, '$.supply_amount.value') AS double), 0) AS usd_per_underlying_base,
      (try_cast(json_extract_scalar(event_json, '$.supply_amount_usd_estimate.value') AS double) / 1e18)
        / nullif(try_cast(json_extract_scalar(event_json, '$.ctoken_supply') AS double), 0) AS usd_per_ctoken_base,
      ROW_NUMBER() OVER (PARTITION BY transaction_digest, json_extract_scalar(event_json, '$.reserve_id')
                         ORDER BY event_index ASC) AS rn
    FROM sui.events
    WHERE date >= DATE '2024-03-01'
      AND event_type = '0xf95b06141ed4a174f239417323bde3f209b972f5930d8521ea38a52aff3a6ddf::reserve::ReserveAssetDataEvent'
  ) WHERE rn = 1
),
symbol_map (coin_type, symbol) AS (
  VALUES
    ('5d4b302506645c37ff133b98c4b50a5ae14841659738d6d733d59d0d217a93bf::coin::COIN', 'wUSDC'),
    ('c060006111016b8a020ad5b33834984a437aaa7d3c74c18e09a95d48aceab08c::coin::COIN', 'wUSDT'),
    ('af8cd5edc19c4512f4259f0bee101a40d41ebed738ade5874359610ef8eeced5::coin::COIN', 'WETH'),
    ('b7844e289a8410e50fb3ca48d69eb9cf29e27d223ef90353fe1bd8e27ff8f3f8::coin::COIN', 'SOL')
),
priced AS (
  SELECT
    l.day,
    l.lending_market_id,
    COALESCE(smw.symbol, upper(split_part(l.withdraw_coin_type, '::', 3))) AS collateral_symbol,
    COALESCE(smr.symbol, upper(split_part(l.repay_coin_type, '::', 3)))    AS debt_symbol,
    l.liquidator,
    l.obligation_id,
    l.transaction_digest,
    l.repay_amount            * rr.usd_per_underlying_base AS debt_repaid_usd,
    l.withdraw_amount         * rw.usd_per_ctoken_base     AS collateral_seized_usd,
    l.protocol_fee_amount     * rw.usd_per_ctoken_base     AS protocol_fee_usd,
    l.liquidator_bonus_amount * rw.usd_per_ctoken_base     AS liquidator_bonus_usd
  FROM liq l
  LEFT JOIN reserve_snap rr ON rr.transaction_digest = l.transaction_digest AND rr.reserve_id = l.repay_reserve_id
  LEFT JOIN reserve_snap rw ON rw.transaction_digest = l.transaction_digest AND rw.reserve_id = l.withdraw_reserve_id
  LEFT JOIN symbol_map  smw ON smw.coin_type = l.withdraw_coin_type
  LEFT JOIN symbol_map  smr ON smr.coin_type = l.repay_coin_type
)
SELECT * FROM priced
