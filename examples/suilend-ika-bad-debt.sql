-- ============================================================================
-- Suilend IKA bad debt: DEX price/VWAP vs IKA-debt liquidations (Aug-Oct 2025)
-- ----------------------------------------------------------------------------
-- Source:   Dune query 7757951 (public, owner 0x_vcharles). Validated 2026-06-19.
-- Finding:  on 2025-09-08 IKA roughly doubled in a day (~$0.038 -> ~$0.0799 VWAP)
--           on a ~10x DEX-volume spike (~$22.4M). That day 851 IKA-debt liquidations
--           across 84 obligations cleared ~$794K; the residual ~$395K across 53
--           obligations was written off via ForgiveEvent. Only write-off in Suilend history.
-- Pattern:  dex_sui.trades VWAP for a token with no oracle feed, joined to the
--           priced liquidation matview. Match the token by address LIKE on both
--           side-address columns; always filter block_month to prune. See sui-data-model.md.
-- IKA token 0x7262fb2f7a3a14c888c438a3cd9b912469a58cf60f367352c46584262e8299aa::ika::IKA
-- ============================================================================

WITH ika_dex AS (
  SELECT
    block_date AS day,
    sum(amount_usd) AS ika_dex_volume_usd,
    sum(CASE WHEN token_sold_address LIKE '%7262fb2f7a3a14c888c438a3cd9b912469a58cf60f367352c46584262e8299aa%'
             THEN token_sold_usd ELSE token_bought_usd END) AS ika_side_usd,
    sum(CASE WHEN token_sold_address LIKE '%7262fb2f7a3a14c888c438a3cd9b912469a58cf60f367352c46584262e8299aa%'
             THEN token_sold_amount ELSE token_bought_amount END) AS ika_amount
  FROM dex_sui.trades
  WHERE block_month >= timestamp '2025-08-01' AND block_month < timestamp '2025-11-01'
    AND block_date BETWEEN date '2025-08-01' AND date '2025-10-15'
    AND (token_sold_address   LIKE '%7262fb2f7a3a14c888c438a3cd9b912469a58cf60f367352c46584262e8299aa%'
      OR token_bought_address LIKE '%7262fb2f7a3a14c888c438a3cd9b912469a58cf60f367352c46584262e8299aa%')
  GROUP BY 1
),
ika_liq AS (
  SELECT
    day,
    count(*)                      AS ika_liquidation_txs,
    count(DISTINCT obligation_id) AS ika_obligations_liquidated,
    round(sum(debt_repaid_usd))   AS ika_debt_repaid_usd
  FROM dune."0x_vcharles".result_suilend_liquidations
  WHERE debt_symbol = 'IKA'
    AND day BETWEEN date '2025-08-01' AND date '2025-10-15'
  GROUP BY 1
)
SELECT
  coalesce(d.day, l.day)                              AS day,
  round(d.ika_side_usd / nullif(d.ika_amount, 0), 5)  AS ika_price_usd,
  round(d.ika_dex_volume_usd)                         AS ika_dex_volume_usd,
  coalesce(l.ika_debt_repaid_usd, 0)                  AS ika_debt_repaid_usd,
  coalesce(l.ika_liquidation_txs, 0)                  AS ika_liquidation_txs,
  coalesce(l.ika_obligations_liquidated, 0)           AS ika_obligations_liquidated
FROM ika_dex d
FULL OUTER JOIN ika_liq l ON d.day = l.day
ORDER BY 1
