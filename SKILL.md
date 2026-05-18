---
name: dune-sui-query-builder
description: Build, debug, and optimize DuneSQL queries for Sui blockchain analytics, including pure-SQL pipelines that pull live state directly from Sui RPC nodes. Use this skill whenever the user mentions Dune Analytics, DuneSQL, Sui queries, Move events, on-chain data analysis for Sui, the Pyth oracle, Sui RPC inside SQL, or wants to pull live blockchain state into a Dune query. Also trigger when the user references specific Sui protocols (Navi, Suilend, Cetus, Bluefin, Scallop, Aftermath, DeepBook, Volo, Haedal, etc.), asks about Move packages, object-centric data, event_json parsing, http_post / http_get / LiveFetch, dynamic field discovery, multi-stage RPC pipelines, or wants to analyze Sui blockchain data in any way using Dune.
---

# Dune Sui Query Builder

Build, debug, and optimize DuneSQL (Trino-based) queries for Sui blockchain analytics. This skill covers Dune's Sui data model, Sui-specific quirks (object-centric architecture, binary types, event JSON parsing, package upgrades), and a class of patterns that goes beyond what the indexed tables alone can do — **chained Sui RPC calls inside SQL via Dune's LiveFetch**, plus oracle-grade pricing via the **Pyth Hermes API** for tokens that aren't in `prices.hour`.

Before writing any query, read `references/sui-data-model.md` for the table catalog and Sui-specific edge cases. For Sui DEX queries (Cetus, Bluefin, DeepBook, Aftermath, Kriya, FlowX, Momentum, BlueMove, Obric), BTCfi work, Walrus storage, or Sui chain stats — read `references/sui-curated-tables.md` first; these often have curated spell tables that bypass raw event archaeology. For Navi or Suilend protocol queries, read `references/protocol-patterns.md` — it covers package archaeology, mislabel investigations, and a fully-validated 4-stage dynamic pipeline that achieves 100% asset coverage on a $235M lending protocol with no third-party indexer.

## Task Router

Determine which mode applies based on the user's request:

1. **Build** — User describes what data they want in natural language → construct a query from scratch
2. **Debug/Review** — User provides an existing query → analyze correctness, find issues, suggest fixes
3. **Optimize** — User has a working but slow/expensive query → improve performance
4. **Investigate** — User mentions a public Dune dashboard or query and wants to understand or differentiate from it → reverse-engineer + audit

Mode 4 deserves special attention. The most-cited "Navi Protocol" reference dashboard on Dune (Prudentia Labs / mementomori7777, 19 charts) queries **Suilend's** event package, not Navi's — a useful pedagogical example of why package-identity verification matters on Sui. Always reverse-engineer cited reference dashboards before competing with or building on top of them; the package hexes will tell you which protocol the queries actually cover.

## Build Mode

When the user asks for a new query:

1. **Clarify the goal** if ambiguous (e.g., "Do you mean unique depositors or deposit events? Cumulative supply or net flow? Snapshot today or time-series?"). Restate the goal before writing SQL.
2. **Pick the right data source.** Check `references/sui-curated-tables.md` first — 5 curated Sui spell tables exist (`dex_sui.trades`, `sui_tvl.btc_ecosystem`, `sui_daily.stats`, `sui_walrus.base_table`, `cex.addresses`). If a curated table covers the question, use it. For Sui lending and most other protocol-specific Sui analytics, no curated tables exist — decide between:
   - `sui.events` — flows and actions emitted by `event::emit`
   - `sui.objects` — historical state changes per object-version
   - `sui.move_call` — cheap function-call counting
   - `sui.transactions` — gas/success analysis
   - **Live Sui RPC via `http_post`** — when state-as-of-now matters more than historical replay (TVL today, current rates, current asset list)
   - **Pyth Hermes via `http_get`** — when you need oracle prices for tokens not in Dune's `prices.hour`

   Check `references/sui-data-model.md` for the table hierarchy and the LiveFetch section.

3. **Identify all relevant packages.** Sui protocols frequently upgrade and redeploy. A query filtered on only one package ID will silently miss history. Always check for known package upgrades. For Navi and Suilend, see `references/protocol-patterns.md`.

4. **Construct step-by-step:**
   - Start with the base table or the LiveFetch source
   - Apply WHERE filters first: **always include `WHERE date >= ...`** (Sui tables are partitioned by `date`)
   - Filter by `event_type IN (...)` for specific protocol events
   - Decode binary columns (`sender`, `package`, `owner_address`, `object_id`) with `concat('0x', lower(to_hex(col)))`
   - Parse event payloads with `json_extract_scalar(event_json, '$.field_name')`
   - Aggregate and format results
5. **Output the query** using the response format below.

## Debug/Review Mode

When the user provides a query to check:

1. **Verify table choice** — Is `sui.events` the best source, or do they actually need `sui.objects` (state) or `sui.move_call` (function counts) or LiveFetch (current state)?
2. **Check partition filter** — Does the query filter by `date`? Missing date filter = full history scan. This is the #1 cost/timeout issue on Sui queries.
3. **Check binary handling** — A query like `WHERE sender = '0x...'` fails silently (string vs binary). Correct: `WHERE sender = from_hex('...')` (no `0x` prefix inside `from_hex`) or `WHERE concat('0x', lower(to_hex(sender))) = '0x...'`.
4. **Check JSON parsing** — `event_json` is a STRING containing JSON, not native JSON. Must use `json_extract_scalar(event_json, '$.field')`.
5. **Check package coverage** — Does the query account for package upgrades? For multi-package protocols (Navi: 3 packages, Suilend: 1 package but with subtle event/lending_market split), missing packages = missing data eras.
6. **Check decimal handling** — Sui amounts in events are raw integers in native token decimals. SUI = 9, USDC = 6, BTC variants = 8. Some protocols (like Navi) **normalize all amounts to 9 decimals internally regardless of token decimals** — the `total_supply` field in Navi reserves divides by `1e9` for all assets. Verify per protocol; never assume.
7. **Verify the protocol identity.** If the query references public package hexes, cross-check them. The famous mementomori7777 "Navi" dashboard is actually Suilend (`0xf95b06141...::reserve::ReserveAssetDataEvent` is Suilend's, not Navi's). Wrong-protocol queries are surprisingly common.
8. **Output analysis** using the response format below.

## Optimize Mode

When the user has a working but slow query:

1. **Add or tighten date partition filter.** `WHERE date >= CURRENT_DATE - INTERVAL '90' DAY` prunes partitions dramatically.
2. **Replace `event_json` parsing with `event_type` filtering where possible.** String IN lists are pruned at plan time; JSON extraction happens per row.
3. **Use CTEs to pre-filter multi-package unions.** Each branch of a UNION ALL must apply its own date filter and event_type filter, not rely on an outer WHERE.
4. **Avoid `SELECT *` on `sui.transactions` and `sui.objects`** — both have multi-KB string columns (`raw_transaction`, `transaction_json`, `effects_json`, `object_json`, `bcs`).
5. **Use `APPROX_DISTINCT` for high-cardinality counts** when exact precision isn't required.
6. **Group by `date` directly**, not `DATE_TRUNC('day', from_unixtime(timestamp_ms/1000))` — the former is a column read, the latter is two function calls per row.
7. **For LiveFetch pipelines, batch RPC calls** — prefer `sui_multiGetObjects` over 35 separate `sui_getObject` calls. One http_post with 35 IDs in the params is dramatically cheaper than 35 round-trips.

## Investigate Mode

When the user references a public dashboard, query, or claim about a protocol:

1. **Pull the SQL.** Use the Dune MCP `getDuneQuery` to fetch the source. Don't trust the dashboard title.
2. **Decode the package hexes.** A query labeled "Navi" filtering on `0xf95b06141...::reserve::ReserveAssetDataEvent` is actually Suilend. Match each package hex back to the protocol it belongs to via:
   - The protocol's docs / SDK repo
   - DefiLlama protocol pages
   - Searching `sui.move_package` for the deployer
3. **Check date-range coverage.** A "Navi historical" dashboard that only shows data after Feb 2026 is missing the pre-migration package — flag this.
4. **Look for partition discipline.** Production dashboards often skip `WHERE date >= ...` filters; this is a cost bug, not a correctness bug, but it's a differentiation target.
5. **Output an audit** that names the actual protocol(s) covered, the time-coverage gaps, and any methodology weaknesses — don't politely defer to the original.

## DuneSQL + Sui-Specific Syntax

DuneSQL is a Trino fork. Sui-specific quirks on top of standard Trino:

- **Binary columns** (`sender`, `package`, `object_id`, `owner_address`, `gas_owner`, `gas_object_id`): use `to_hex()` and `from_hex()` for string conversion. Canonical Sui address: `concat('0x', lower(to_hex(sender)))`.
- **JSON columns** (`event_json`, `object_json`, `transaction_json`, `effects_json`) are STRINGS, not native JSON:
  - `json_extract_scalar(event_json, '$.field')` → string (most common)
  - `json_extract(event_json, '$.field')` → JSON value (use for arrays/nested objects you'll `UNNEST`)
  - `cast(json_extract_scalar(event_json, '$.amount') as decimal(38,0))` for numerics
  - For arrays: `UNNEST(CAST(json_extract(resp, '$.result.data') AS array(json))) t(item)`
- **`event_type` filtering** is the cleanest Sui pattern — full path `<pkg_hex>::<module>::<EventName>` is one string column, filter with `event_type IN (...)`.
- **Date truncation:** `DATE_TRUNC('week', cast(date as timestamp))` — `date` is DATE, not TIMESTAMP.
- **Timestamp from ms:** `from_unixtime(timestamp_ms / 1000)` when sub-daily resolution is needed.
- **Intervals:** `CURRENT_DATE - INTERVAL '90' DAY`.
- **Concatenation:** `||`.

### LiveFetch — pulling live data inside SQL

Dune supports `http_get` and `http_post` directly inside SQL. **This is a game-changer for Sui lending and most DeFi protocols because Dune's curated tables don't yet cover them.** When TVL, current rates, or current asset metadata matter more than historical replay, you can call Sui RPC nodes from within the query and refresh on every execution.

```sql
-- Single Sui RPC call inside SQL
SELECT http_post(
  'https://fullnode.mainnet.sui.io:443',
  '{"jsonrpc":"2.0","id":1,"method":"sui_getObject","params":["0x...",{"showContent":true}]}',
  ARRAY['Content-Type: application/json']
) AS resp
```

LiveFetch is free for all Dune users, has a 5s timeout per call, and is rate-limited at ~80 req/s per proxy. Practical implication: pipelines with 1-50 RPC calls run reliably; pipelines with hundreds of calls need batching via `sui_multiGetObjects` or splitting across multiple queries.

For a fully-worked 4-stage dynamic pipeline (`getDynamicFields` → `multiGetObjects` → `getCoinMetadata` × N → Pyth Hermes), see `references/protocol-patterns.md` § "Navi 4-stage pipeline".

### Pyth Hermes — oracle-grade pricing for any token

Tokens not in Dune's `prices.hour` (governance tokens like NAVX, niche assets like XAUM gold, brand-new launches) can be priced via Pyth's Hermes API:

```sql
SELECT http_get(
  'https://hermes.pyth.network/v2/updates/price/latest'
    || '?ids[]=88250f854c019ef4f88a5c073d52a18bb1c6ac437033f5932cd017d24917ab46' -- NAVX/USD
    || '&ids[]=e62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43' -- BTC/USD
    || '&parsed=true',
  ARRAY['Content-Type: application/json']
) AS resp
```

Discover feed IDs at `https://hermes.pyth.network/v2/price_feeds?query=<symbol>&asset_type=crypto`. Pyth prices come with `expo` (exponent) and require: `price * power(10.0, expo)`. See `references/protocol-patterns.md` for full parsing pattern.

**Why Pyth specifically for Sui?** Pyth IS the dominant Sui oracle. Navi, Suilend, Cetus, Bluefin all consume Pyth feeds on-chain. Reading the same source the protocol uses gives you oracle-grade pricing that mirrors what the protocol sees for liquidations.

**For bulk historical pricing** (e.g., 30/90/365 days × multiple feeds), use Pyth Benchmarks' TradingView shim instead — Hermes' `/v2/updates/price/<ts>` rate-limits under parallel load. See `references/sui-data-model.md` § "Bulk historical pricing — Pyth Benchmarks" for the pattern and a worked Navi example.

### `prices.hour` — Dune's curated price feed

Dune maintains an hourly price table (`prices.hour`) with coverage across most chains. Quirks worth knowing:

- **Filter by chain explicitly:** `WHERE blockchain = 'sui'`. The same symbol exists on multiple chains.
- **Address encoding is double-hex:** `prices.hour.contract_address_varchar` for Sui stores `'0x' || to_hex(to_utf8(canonical_address))`. SUI's `0x2` becomes `0x307832` (hex of ASCII '0','x','2'). To join from a Sui address: `pl.contract_address_hex = '0x' || to_hex(to_utf8(p.coin_address_canonical))`.
- **Coverage gaps:** smaller-cap tokens (NAVX, XAUM, niche LSTs) may be missing entirely. Always have a Pyth fallback.

## Response Format

### For Build Requests

```
**Goal:** [Restate user's request]

**Data Sources:**
- `sui.events` — [why this table]
- Sui RPC via http_post — [why live state vs indexed]
- Pyth Hermes via http_get — [why oracle vs prices.hour]

**Query:**
[Clean, executable SQL in a code block, with `date` filter always first in WHERE]

**Logic Breakdown:**
1. [Step explanation]
2. [Step explanation]

**⚠️ Sui-Specific Notes:**
- [Relevant pitfall: binary decoding, JSON parsing, package coverage, decimals, double-hex price encoding]

**💡 Optimization Tips:**
- [Partition pruning, CTE pre-filtering, batch RPC calls]

**❓ Uncertainties:**
- [Any disclaimers about unverified event_json field names, package IDs, or coin metadata layout — always flag]
```

### For Debug/Review Requests

```
**Analysis:**
✅ [What's correct]
⚠️ [Issues found — prioritize: missing date filter, wrong binary/JSON handling, missing packages, wrong protocol identity]

**Suggested Changes:**
[Corrected query if needed, with explanation of each change]

**Performance Notes:**
- [Partition pruning, column selection, etc.]

**❓ Uncertainties:**
- [Any disclaimers]
```

### For Investigate Requests

```
**Reference dashboard:** [URL/title]
**Query SQL fetched:** ✅

**Actual protocol covered:** [protocol name, with package hex evidence]
**Time-coverage gaps:** [which package eras are missing]
**Methodology weaknesses:** [partition filters, hardcoded values, mislabels...]
**Differentiation opportunities:** [what your dashboard should do better]
```

## Uncertainty Handling

If an `event_json` field name, package ID, coin metadata field, or protocol-specific event type cannot be confirmed, always include this disclaimer:

> ⚠️ I cannot confirm `event_json.$.field_name` exists for this event. Verify by running a small sample query first: `SELECT event_json FROM sui.events WHERE event_type = '...' AND date >= CURRENT_DATE - INTERVAL '7' DAY LIMIT 5`.

For LiveFetch pipelines, also probe the RPC response shape before parsing it at scale:

```sql
-- Probe a single RPC response, view the JSON structure, THEN write the parser
SELECT http_post(
  'https://fullnode.mainnet.sui.io:443',
  '{"jsonrpc":"2.0","id":1,"method":"sui_getObject","params":["<known_object_id>",{"showContent":true}]}',
  ARRAY['Content-Type: application/json']
) AS resp
```

Never guess field paths silently. A query that returns nulls because of a wrong JSON path looks correct but is wrong.

## Common Query Patterns

**Daily unique senders for a set of events (partition-pruned):**
```sql
SELECT
  date AS day,
  COUNT(DISTINCT concat('0x', lower(to_hex(sender)))) AS unique_users
FROM sui.events
WHERE date >= CURRENT_DATE - INTERVAL '90' DAY
  AND event_type IN (
    '<pkg>::<module>::<Event1>',
    '<pkg>::<module>::<Event2>'
  )
GROUP BY 1
ORDER BY 1 DESC
```

**Latest snapshot from a time-series event (one row per day per token):**
```sql
WITH ranked AS (
  SELECT
    date AS day,
    json_extract_scalar(event_json, '$.coin_type.name') AS token,
    try_cast(json_extract_scalar(event_json, '$.supply_amount_usd_estimate.value') AS DOUBLE) / 1e18 AS supply_usd,
    timestamp_ms,
    event_index,
    ROW_NUMBER() OVER (PARTITION BY date, json_extract_scalar(event_json, '$.coin_type.name')
                       ORDER BY timestamp_ms DESC, event_index DESC) AS rn
  FROM sui.events
  WHERE date >= CURRENT_DATE - INTERVAL '90' DAY
    AND event_type = '<pkg>::<module>::ReserveAssetDataEvent'
)
SELECT day, token, supply_usd FROM ranked WHERE rn = 1
```

Note the trick: divide pre-computed USD estimates by `1e18` — Suilend stores them as `Decimal` types scaled by `1e18`, not `1e9`.

**Multi-package union (for protocols that have upgraded):**
```sql
WITH unified_events AS (
  SELECT date, sender, event_json
  FROM sui.events
  WHERE date >= CURRENT_DATE - INTERVAL '90' DAY
    AND event_type IN ('<pkg_v1>::<module>::DepositEvent', ...)

  UNION ALL

  SELECT date, sender, event_json
  FROM sui.events
  WHERE date >= CURRENT_DATE - INTERVAL '90' DAY
    AND event_type IN ('<pkg_v2>::<module>::DepositEvent', ...)
)
SELECT ... FROM unified_events
```

Date filter inside *each* branch — enables partition pruning per branch.

**Two-stage Sui RPC pipeline (discover IDs, then fetch state):**
```sql
WITH
field_response AS (
  SELECT http_post(
    'https://fullnode.mainnet.sui.io:443',
    '{"jsonrpc":"2.0","id":1,"method":"suix_getDynamicFields","params":["<table_object_id>",null,50]}',
    ARRAY['Content-Type: application/json']
  ) AS resp
),
field_objects AS (
  SELECT json_extract_scalar(field_json, '$.objectId') AS object_id
  FROM field_response,
       UNNEST(CAST(json_extract(resp, '$.result.data') AS array(json))) t(field_json)
),
ids_payload AS (
  SELECT '[' || array_join(array_agg('"' || object_id || '"'), ',') || ']' AS ids_json
  FROM field_objects
),
state_response AS (
  SELECT http_post(
    'https://fullnode.mainnet.sui.io:443',
    '{"jsonrpc":"2.0","id":1,"method":"sui_multiGetObjects","params":['
      || (SELECT ids_json FROM ids_payload)
      || ',{"showContent":true}]}',
    ARRAY['Content-Type: application/json']
  ) AS resp
)
SELECT
  json_extract_scalar(obj_json, '$.data.content.fields.value.fields.id') AS asset_id,
  json_extract_scalar(obj_json, '$.data.content.fields.value.fields.coin_type') AS coin_type
FROM state_response,
     UNNEST(CAST(json_extract(resp, '$.result') AS array(json))) t(obj_json)
```

**Pyth Hermes price fetch (oracle-grade pricing for long-tail):**
```sql
WITH hermes_response AS (
  SELECT http_get(
    'https://hermes.pyth.network/v2/updates/price/latest'
      || '?ids[]=<feed_id_1>&ids[]=<feed_id_2>&parsed=true',
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
)
SELECT * FROM pyth_prices
```

**Joining `prices.hour` to a Sui token (handles double-hex encoding):**
```sql
SELECT t.symbol, p.price
FROM tokens t
LEFT JOIN (
  SELECT
    contract_address_varchar AS contract_address_hex,
    symbol,
    price,
    ROW_NUMBER() OVER (PARTITION BY contract_address_varchar ORDER BY timestamp DESC) AS rn
  FROM prices.hour
  WHERE blockchain = 'sui'
    AND timestamp >= CURRENT_TIMESTAMP - INTERVAL '24' HOUR
) p
  ON p.contract_address_hex = '0x' || to_hex(to_utf8(t.coin_address_canonical))
  AND p.rn = 1
```

**Function-call counts (use `sui.move_call` — cheaper than events):**
```sql
SELECT date, function, COUNT(*) AS calls
FROM sui.move_call
WHERE date >= CURRENT_DATE - INTERVAL '30' DAY
  AND package = from_hex('<pkg_hex_without_0x_prefix>')
  AND module = '<module_name>'
GROUP BY 1, 2
ORDER BY 1 DESC
```

## When to Reach for Each Tool

| Need | Best tool | Why |
|---|---|---|
| Daily user counts, action volume, historical trends | `sui.events` + date partition | Indexed and cheap |
| Function-call totals, no payload needed | `sui.move_call` | 6 columns vs 15, dramatically cheaper |
| Gas analysis, success/failure rates, zkLogin breakdown | `sui.transactions` | Tx-level only |
| Current TVL, current rates, current asset list | LiveFetch via `http_post` to Sui RPC | No indexed alternative on Sui |
| Historical TVL replay (when protocol pre-computes USD) | `sui.events` filtering on `*::ReserveAssetDataEvent` | Suilend/Sui-style USD-in-events |
| Historical TVL replay (when protocol does NOT pre-compute USD) | `sui.objects` snapshots × `prices.hour` (or LiveFetch's `sui_tryGetPastObject`) | Hard but possible |
| Oracle prices for tokens missing from `prices.hour` | Pyth Hermes via `http_get` | Same source the protocol uses |
| Discovering all events emitted by a protocol | `SELECT DISTINCT event_type FROM sui.events WHERE event_type LIKE '<pkg_prefix>%'` | Reverse-engineer schemas before parsing them |
