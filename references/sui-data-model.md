# Sui Data Model on Dune

Reference for Dune's Sui table catalog, Sui-specific edge cases, LiveFetch (Sui RPC inside SQL), and the price-data ecosystem (`prices.hour`, Pyth Hermes). Consult before writing or reviewing any Sui query.

Official docs: https://docs.dune.com/data-catalog/sui/overview (append `.md` for agent-readable version)

## Table of Contents

1. [Critical conceptual difference vs EVM and Solana](#critical-conceptual-difference-vs-evm-and-solana)
2. [Table hierarchy](#table-hierarchy)
3. [`sui.events` schema](#suievents--full-schema)
4. [`sui.objects` schema](#suiobjects--full-schema)
5. [`sui.transactions` schema](#suitransactions--full-schema)
6. [`sui.move_call` schema](#suimove_call--full-schema)
7. [Sui-specific edge cases](#sui-specific-edge-cases)
8. [LiveFetch — Sui RPC inside SQL](#livefetch--sui-rpc-inside-sql)
9. [Pricing — `prices.hour` and Pyth Hermes](#pricing--priceshour-and-pyth-hermes)
10. [Performance best practices](#performance-best-practices)
11. [Anti-patterns](#anti-patterns-observed-in-real-dashboards)

## Critical Conceptual Difference vs EVM and Solana

Sui is **object-centric**, not account-based. Everything is an object with a type. This changes how you model analytics:

- **5 curated Sui spell tables exist** (verified May 2026 via Dune MCP) — `dex_sui.trades` (9 DEXs since May 2023), `sui_tvl.btc_ecosystem` (BTCfi composite), `sui_daily.stats` (chain activity), `sui_walrus.base_table` (Walrus storage), `cex.addresses` (cross-chain, includes Sui). For these domains, check `sui-curated-tables.md` first — curated tables are dramatically simpler than raw events when they cover your need.
- **No decoded per-protocol tables for Sui lending.** Unlike EVM (`aave_v3_ethereum.pool_evt_borrow`) or Solana (`orca_whirlpool_solana.swap`), Sui Move events aren't decoded into per-protocol curated tables for lending or most DeFi domains beyond the 5 spell tables above. Dune's curated `lending.*` tables [cover 15 EVM chains](https://docs.dune.com/data-catalog/curated/lending/overview) — Sui isn't in scope. For Navi, Suilend, Scallop, and most other protocol-specific analytics, you query `sui.events` directly and filter by `event_type` string.
- **State lives in objects.** Aave/Morpho store balances in EVM mappings keyed by asset address. Navi/Suilend store the same data as *Sui objects*. To snapshot current TVL, you either query `sui.objects` (historical event-style) or call Sui RPC via LiveFetch (current state) — see § LiveFetch.
- **Package upgrades change the hex prefix.** When a protocol upgrades its Move package, the old package ID stays valid for reads but new deployments emit events under a new package hex. Any historical query must union old and new packages.
- **No decoded tables means no convenience APR/TVL columns.** You compute these yourself from raw events or objects, or via LiveFetch + Pyth.

## Table Hierarchy

| Table | Partition | Use Case |
|-------|-----------|----------|
| `sui.events` | `date` | **Primary workhorse for flows and actions.** Deposits, borrows, swaps, transfers — anything emitted by `event::emit`. |
| `sui.objects` | `date` | **State/TVL snapshots and replay.** Current balances, pool states, position health — at any historical version. |
| `sui.transactions` | `date` | Tx-level aggregates, gas analysis, success/failure, zkLogin/sponsored tx analysis. |
| `sui.move_call` | `date` | **Cheap function-call counting.** Use instead of `sui.events` when you only need "how many times was function X called." |
| `sui.move_package` | `date` | Package deployment tracking, upgrade discovery. |
| `sui.transaction_objects` | `date` | Which objects were read/written/deleted per tx. Rarely needed unless analyzing contention. |
| `sui.checkpoints` | `date` | Checkpoint metadata. Rarely needed for protocol analytics. |
| `sui.wrapped_object` | `date` | Parent-child object hierarchies (dynamic fields, nested storage). |

All tables partitioned by `date` (DATE type). **Every query must filter on `date`** — skipping this triggers a full history scan and is the #1 cost driver on Sui queries.

## sui.events — Full Schema

Contains all Move events emitted via `sui::event::emit`.

| Column | Type | Notes |
|--------|------|-------|
| `transaction_digest` | string | Sui tx hash |
| `event_index` | decimal(20,0) | Event seq within tx |
| `checkpoint` | decimal(20,0) | Checkpoint number |
| `epoch` | decimal(20,0) | Epoch number |
| `timestamp_ms` | decimal(20,0) | Unix ms. Use `from_unixtime(timestamp_ms/1000)` for sub-daily. |
| `date` | date | **Partition key. Always filter.** |
| `sender` | **binary** | Tx initiator address. Decode: `concat('0x', lower(to_hex(sender)))`. |
| `package` | **binary** | Emitter package ID. Decode same as sender, or compare with `from_hex(...)`. |
| `module` | string | Module name (`lending`, `pool`, etc.) |
| `event_type` | string | **Full path `<pkg_hex>::<module>::<EventName>`. Best filter.** |
| `bcs` | string | Raw BCS-encoded event data. Rarely needed. |
| `event_json` | **string (JSON text)** | Decoded payload. **Parse with `json_extract_scalar()`, not native JSON.** |
| `bcs_length` | decimal(20,0) | BCS payload size |
| `_updated_at`, `_ingested_at` | timestamp | Ingestion metadata |

### Usage notes

- **Don't filter by `package` + `module` separately when `event_type` gives you both.** `event_type` is one prunable string column; splitting costs an extra predicate and gives no benefit.
- **Sender ≠ acting user for on-behalf flows.** Some protocols emit events where `sender` is the router/keeper and the actual user is in `event_json.user`. Always verify on sample data before assuming `sender = user`.
- **Multiple events per tx are common.** A single Navi borrow tx typically emits BorrowEvent + InterestAccrual + CollateralCheck. Use `event_index` if you need intra-tx ordering.

## sui.objects — Full Schema

Contains object state changes (creations, mutations, deletions). One row per object-version.

| Column | Type | Notes |
|--------|------|-------|
| `object_id` | **binary** | Object's unique ID. Decode same as sender. |
| `version` | decimal(20,0) | Monotonic version per object. Latest version = current state. |
| `digest` | string | Content hash |
| `type_` | string | **Move type, e.g., `0x2::coin::Coin<0x2::sui::SUI>`. Best filter for "all objects of type X."** |
| `checkpoint`, `epoch`, `timestamp_ms`, `date` | — | Same semantics as events |
| `owner_type` | string | `AddressOwner` \| `ObjectOwner` \| `Shared` \| `Immutable` |
| `owner_address` | binary | Owner's address if `AddressOwner`, parent object if `ObjectOwner` |
| `object_status` | string | `Created` \| `Mutated` \| `Deleted` |
| `initial_shared_version` | decimal(20,0) | For shared objects, the version at shared creation |
| `previous_transaction` | string | Prior tx that modified this object |
| `has_public_transfer`, `is_consensus` | boolean | Object ability flags |
| `storage_rebate` | decimal(20,0) | Rebate on deletion |
| `bcs` | string | Raw BCS |
| `coin_type` | string | If object is a `Coin<T>`, the inner T type |
| `coin_balance` | decimal(20,0) | If object is a Coin, the raw balance |
| `struct_tag` | string | Fully qualified struct tag |
| `object_json` | **string (JSON text)** | Parsed struct fields. Same parsing rules as `event_json`. |
| `bcs_length` | — | |

### Usage notes

- **Latest version per object:** for TVL or state snapshots, get the max version per object_id within the recent partition.
- **`type_` wildcard matching:** generics like `Coin<T>` require `LIKE` with proper escaping. Example: `type_ LIKE '0x2::coin::Coin<%>'`.
- **`coin_balance` is raw.** SUI: divide by 1e9. USDC: 1e6. Verify per token.
- **`Deleted` objects still appear.** Filter `object_status != 'Deleted'` for live-state queries.
- **Historical state via `sui.objects` is event-driven**; for current-snapshot accuracy, prefer LiveFetch (see below) — `sui.objects` shows state changes per ingestion, but the freshest version per object is one query away.
- **`object_json` JSON path convention** (important when porting RPC-based parsers): `sui.objects.object_json` strips both the RPC `$.data.content` wrapper AND all `.fields` indirection that the RPC response uses for nested Move structs. A nested Move struct field that the RPC reports as `$.data.content.fields.value.fields.X.fields.Y` is accessible as `$.value.X.Y` in `object_json`. Divisors (`/1e9` for Navi-9 normalization, `/1e25` for ray rates, `/1e27` for indices) carry over identically — only the path traversal changes. See `references/protocol-patterns.md` § "Navi — `sui.objects.object_json` path convention" for a full table mapping V8 RPC paths to V9.5 `sui.objects` paths.
- **`coin_type` returned by `sui.objects` lacks the `0x` prefix** that the RPC response includes. `coin_type` here returns e.g. `"0000000000000000000000000000000000000000000000000000000000000002::sui::SUI"` (no `0x`). Apply the same short-form-for-system-addresses CASE block downstream.

## sui.transactions — Full Schema

Tx-level aggregate. 45+ columns. Use for gas/success analysis, not flow analysis.

Key columns: `transaction_digest`, `date`, `sender` (binary), `transaction_kind`, `is_system_txn`, `is_sponsored_tx`, `execution_success`, `total_gas_cost` (bigint), `computation_cost`, `storage_cost`, `storage_rebate`, `gas_price`, `move_calls` (count of move_calls in tx), `has_zklogin_sig`, `packages` (string — summary of packages touched).

Avoid selecting `raw_transaction`, `transaction_json`, `effects_json` unless specifically needed — they are large strings and dominate scan cost.

## sui.move_call — Full Schema

| Column | Type | Notes |
|--------|------|-------|
| `transaction_digest` | string | Tx hash |
| `checkpoint`, `epoch`, `timestamp_ms`, `date` | — | Standard |
| `package` | **binary** | Called package |
| `module` | string | Called module |
| `function` | string | Called function name |

### Usage notes

- **Cheaper than `sui.events` for action counts.** 6 columns vs 15.
- **Does NOT contain arguments or results.** For amounts, user addresses, or any payload, you need `sui.events`.
- **PTBs:** a single Sui tx can contain multiple move_calls. `sui.move_call` has one row per call.

## Sui-Specific Edge Cases

### 1. Binary type handling

`sender`, `package`, `object_id`, `owner_address`, `gas_owner`, `gas_object_id` are all `binary` type, not strings.

**Do:**
```sql
WHERE sender = from_hex('d899cf7d2b5db716bd2cf55599fb0d5ee38a3061e7b6bb6eebf73fa5bc4c81ca')
-- or
SELECT concat('0x', lower(to_hex(sender))) AS sender_hex
```

**Don't:**
```sql
WHERE sender = '0xd899cf...'  -- silently returns zero rows, binary ≠ string
```

### 2. Sui address normalization (system addresses are short-form)

Sui addresses are 32 bytes / 64 hex chars, but **system addresses ≤ 3 chars after stripping leading zeros use short-form** (`0x1`, `0x2`, `0x6`). Normal addresses preserve leading zeros. So:
- SUI native: `0x2` (system address) — short-form
- CETUS: `0x06864a6f921804860930db6ddbe2e16acdf8504495ea7481637a1c8b9a8fe54b` — full-length, leading `0x06...` preserved

This matters when joining to `prices.hour` or building canonical address strings. Pattern:
```sql
CASE WHEN length(ltrim(addr_raw, '0')) <= 3
     THEN '0x' || COALESCE(NULLIF(ltrim(addr_raw, '0'), ''), '0')
     ELSE '0x' || addr_raw END AS coin_address_canonical
```

### 3. JSON parsing

`event_json`, `object_json`, `transaction_json`, `effects_json` are **strings containing JSON**, not native JSON.

```sql
-- Get a scalar value (most common):
json_extract_scalar(event_json, '$.amount')

-- Get a nested JSON subtree (use with UNNEST for arrays):
json_extract(event_json, '$.collateral')

-- Cast to numeric:
cast(json_extract_scalar(event_json, '$.amount') as decimal(38,0))

-- Nested fields:
json_extract_scalar(event_json, '$.pool.reserve_id')
```

**Always verify field names exist** by sampling first:
```sql
SELECT event_json
FROM sui.events
WHERE date >= CURRENT_DATE - INTERVAL '7' DAY
  AND event_type = '<target_event_type>'
LIMIT 5
```

### 4. Package upgrades — multi-era unions

Sui Move supports package upgrades via two mechanisms:
- **In-place upgrade:** the package gets a new hex ID, and the old ID stays live but deprecated. Events from post-upgrade emissions carry the new hex.
- **Fresh redeploy:** a brand-new package at a new ID, usually with renamed modules.

**Practical consequence:** any protocol query covering more than a few months *probably* needs to union multiple package eras. This is one of the most common sources of "my chart cuts off unexpectedly" bugs.

Workflow for discovering full package history:
1. Start with the latest known package from docs / the protocol's app
2. Search `sui.move_package` for upgrade history
3. Search public Dune queries via MCP `getDuneQuery` to find what other analysts have discovered
4. For Navi specifically: see `references/protocol-patterns.md` — three packages required

### 5. Decimals — SUI vs USDC vs yield-bearing

Sui amounts are raw integers in coin-native decimals:

| Coin family | Decimals | Divisor |
|-------------|----------|---------|
| SUI, vSUI, haSUI, stSUI | 9 | `1e9` |
| USDC, wUSDC, USDT, suiUSDT, USDY, BUCK, FDUSD, USDSUI, AUSD, suiUSDe | 6 | `1e6` |
| WETH, suiETH | 8 | `1e8` |
| WBTC, wBTC, xBTC, LBTC, stBTC, enzoBTC, MBTC, YBTC | 8 | `1e8` |
| NAVX, CETUS, DEEP, NS, BLUE, WAL | 9 (usually) | `1e9` — **verify per token** |
| XAUM (gold) | 9 | `1e9` |
| IKA | 9 | `1e9` |

**Protocol-specific normalization:** Some protocols normalize all internal amounts to a single fixed scale regardless of token decimals. Navi's reserve `total_supply` field divides by `1e9` for all assets — even USDC (6) and WBTC (8). This is a Navi-internal normalization, not the on-chain wire decimals. Always verify against the protocol's portal/UI before assuming.

When in doubt, sample `coin_balance` in `sui.objects` for a known small holding and compare to a block explorer.

### 6. Shared vs owned vs immutable objects

`owner_type` matters for interpretation:
- **AddressOwner** — owned by a user wallet. User-owned positions, coins.
- **ObjectOwner** — owned by another object (parent-child). Dynamic fields, nested storage.
- **Shared** — consensus-shared mutable state. Pools, oracles, lending reserves.
- **Immutable** — frozen at creation. Package objects, some configs.

For lending protocol TVL: `Shared` (the pool/reserve) for total state, `AddressOwner` for user positions.

### 7. Gas accounting

Sui gas is split:
```
effective_gas = computation_cost + storage_cost - storage_rebate
```

Rebates can be ≥50% of storage cost when deleting objects. Use `total_gas_cost` for the net figure.

### 8. System transactions & zkLogin / sponsored tx

`sui.transactions` includes validator system transactions (`is_system_txn = true`). Always filter for user-facing metrics:
```sql
WHERE is_system_txn = false
```

`has_zklogin_sig` and `is_sponsored_tx` are high-signal flags for onboarding-flow analyses.

## LiveFetch — Sui RPC inside SQL

Dune's `http_get` and `http_post` functions let you call any HTTP endpoint directly inside SQL. **For Sui specifically, this unlocks current-state queries that no indexed table can deliver** — current TVL, current rates, current asset metadata, oracle prices.

Free for all Dune users since May 2024. 5s timeout per call. ~80 req/s per proxy. Docs: https://docs.dune.com/query-engine/Functions-and-operators/live-fetch.

### Sui RPC endpoint

Mainnet: `https://fullnode.mainnet.sui.io:443`. Standard JSON-RPC. Methods used most often for analytics:

| Method | Purpose | Cost |
|--------|---------|------|
| `sui_getObject` | Fetch one object's state | 1 RPC call |
| `sui_multiGetObjects` | Fetch up to ~50 objects in one call | 1 RPC call |
| `suix_getDynamicFields` | List dynamic fields (children) of a parent object — e.g. all reserves in a lending pool | 1 RPC call (paginated up to 50/call) |
| `suix_getCoinMetadata` | Resolve canonical symbol/decimals/name for a coin type | 1 RPC call per coin |
| `sui_tryGetPastObject` | Get object state at a specific historical version | 1 RPC call (used for historical snapshots) |
| `suix_getCheckpoint` | Map dates to checkpoints | 1 RPC call |

### Single-call pattern

```sql
SELECT http_post(
  'https://fullnode.mainnet.sui.io:443',
  '{"jsonrpc":"2.0","id":1,"method":"sui_getObject","params":["0x...",{"showContent":true}]}',
  ARRAY['Content-Type: application/json']
) AS resp
```

### Multi-stage pipeline pattern

When a single RPC call isn't enough — e.g. you need to discover IDs first, then fetch their state — chain CTEs:

```sql
WITH
stage1 AS (SELECT http_post(...) AS resp),  -- discover IDs
ids_payload AS (SELECT '[' || array_join(...) || ']' AS ids_json FROM stage1),
stage2 AS (SELECT http_post(... || (SELECT ids_json FROM ids_payload) || ...) AS resp),
parsed AS (SELECT json_extract_scalar(...) FROM stage2, UNNEST(...))
SELECT * FROM parsed
```

For a fully-worked example with 4 chained stages (`getDynamicFields` → `multiGetObjects` → `getCoinMetadata` × N → Pyth Hermes), see `references/protocol-patterns.md` § "Navi 4-stage dynamic pipeline".

### Probe before you parse

Always probe the response shape with a tiny test query before committing to the parsing logic:

```sql
SELECT http_post(
  'https://fullnode.mainnet.sui.io:443',
  '{"jsonrpc":"2.0","id":1,"method":"sui_getObject","params":["<known_object_id>",{"showContent":true}]}',
  ARRAY['Content-Type: application/json']
) AS resp
```

Then visually inspect `resp` and write the JSON-extraction logic against the actual structure.

### Parallel HTTP calls per row

If you put `http_get` or `http_post` inside the SELECT of a CTE that has N rows, **the call fires N times in parallel** (subject to rate limits). Useful for batched lookups (e.g. coin metadata for 35 reserves). But: be conscious of the 80 req/s cap — pipelines with hundreds of parallel calls per query may hit limits.

### Limitations to know

- 5s timeout per call — long-running endpoints will fail
- 80 req/s rate limit per proxy
- POST body length limits — for very long params, batch into multiple http_posts
- LiveFetch doesn't cache — every query execution re-fetches. Consider materialization if the source data is stable.

## Pricing — `prices.hour` and Pyth Hermes

Sui-token pricing has two main sources, used together for full coverage.

### `prices.hour` (Dune-curated)

Hourly price snapshots maintained by Dune across most chains. Usage:

```sql
SELECT contract_address_varchar, symbol, price, timestamp
FROM prices.hour
WHERE blockchain = 'sui'
  AND timestamp >= CURRENT_TIMESTAMP - INTERVAL '24' HOUR
  AND symbol = 'SUI'
ORDER BY timestamp DESC
LIMIT 1
```

**Critical quirk: `contract_address_varchar` is double-encoded.** It stores `'0x' || to_hex(to_utf8(canonical_address))`. SUI's `0x2` becomes `0x307832` (hex of ASCII '0','x','2'). To join from a Sui canonical address:

```sql
LEFT JOIN prices.hour pl
  ON pl.contract_address_varchar = '0x' || to_hex(to_utf8(canonical_addr))
```

Coverage is good for major tokens (SUI, USDC, USDT, BUCK, BTC variants on Sui) but missing for:
- Governance tokens (NAVX, CETUS sometimes)
- Niche assets (XAUM, very-low-cap tokens)
- Very recent launches
- Cross-chain wrapped variants where canonical price lives on a different chain

For these, fall back to **Pyth Hermes** (next section).

### Pyth Hermes API

Pyth is THE oracle on Sui. Navi, Suilend, Cetus, Bluefin all consume Pyth feeds on-chain. Pyth's HTTP API ("Hermes") returns the same prices the protocols see internally.

**Endpoint:** `https://hermes.pyth.network/v2/updates/price/latest`

**Discover feed IDs:** `https://hermes.pyth.network/v2/price_feeds?query=<symbol>&asset_type=crypto`

**Useful Pyth feed IDs (verified April 2026):**

| Symbol | Feed ID |
|--------|---------|
| BTC/USD | `e62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43` |
| ETH/USD | `ff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace` |
| SOL/USD | `ef0d8b6fda2ceba41da15d4095d1da392a0d2f8ed0c6c7bc0f4cfac8c280b56d` |
| SUI/USD | `23d7315113f5b1d3ba7a83604c44b94d79f4fd69af77f804fc7f920a6dc65744` |
| NAVX/USD | `88250f854c019ef4f88a5c073d52a18bb1c6ac437033f5932cd017d24917ab46` |
| XAU/USD (gold) | `d7db067954e28f51a96fd50c6d51775094025ced2d60af61ec9803e553471c88` |
| USDC/USD | `eaa020c61cc479712813461ce153894a96a6c00b21ed0cfc2798d1f9a9e9c94a` |
| USDY/USD | `e393449f6aff8a4b6d3e1165a7c9ebec103685f3b41e60db4277b5b6d10e7326` |

**Fetch pattern:**

```sql
WITH hermes_response AS (
  SELECT http_get(
    'https://hermes.pyth.network/v2/updates/price/latest'
      || '?ids[]=88250f854c019ef4f88a5c073d52a18bb1c6ac437033f5932cd017d24917ab46'
      || '&ids[]=e62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43'
      || '&parsed=true',
    ARRAY['Content-Type: application/json']
  ) AS resp
),
pyth_prices AS (
  SELECT
    json_extract_scalar(item, '$.id') AS feed_id,
    try_cast(json_extract_scalar(item, '$.price.price') AS DOUBLE)
      * power(10.0, try_cast(json_extract_scalar(item, '$.price.expo') AS INTEGER)) AS price,
    try_cast(json_extract_scalar(item, '$.price.conf') AS DOUBLE) AS conf
  FROM hermes_response,
       UNNEST(CAST(json_extract(resp, '$.parsed') AS array(json))) t(item)
)
SELECT * FROM pyth_prices
```

**Why Pyth specifically:**
- Same source the protocol uses → matches what gets liquidated
- Confidence intervals (`conf`) for stale-price detection
- EMA prices available (manipulation-resistant)
- Coverage extends well past `prices.hour` into long-tail Sui tokens

### Hybrid pricing strategy

For full asset coverage:
1. Try `prices.hour` (Sui chain) on the canonical address
2. If null, fall back to Pyth Hermes feed for the asset
3. If null, fall back to a benchmark price (e.g. BTC for any `*BTC*` variant, SUI for any LST)
4. Tag the source per row so you can audit coverage

See `references/protocol-patterns.md` for a worked Navi example with cascading fallbacks across all 35 assets.

### Bulk historical pricing — Pyth Benchmarks (not Hermes /v2/updates)

Pyth Hermes' `/v2/updates/price/<unix_timestamp>` works for single-snapshot historical lookups but **rate-limits hard under parallel calls** (HTTP 429 starts firing at roughly 20–30 concurrent calls into the same endpoint, verified May 18 2026). For bulk historical pricing (e.g., a 90-day backfill across multiple feeds), use **Pyth Benchmarks** instead. It returns full OHLCV history per feed in a single response, so N days × M feeds collapses to M HTTP calls.

**Endpoint:** `https://benchmarks.pyth.network/v1/shims/tradingview/history`

**Parameters:**
- `symbol` — Pyth symbol with URL-encoded slash, e.g., `Crypto.BTC%2FUSD`, `Crypto.SUI%2FUSD`, `Metal.XAU%2FUSD`
- `resolution` — `1D`, `1H`, `15`, etc.
- `from`, `to` — Unix timestamps (seconds)

**Response shape:** `{"s":"ok", "t":[...], "o":[...], "h":[...], "l":[...], "c":[...], "v":[...]}` where `t` is timestamp array, `c` is close-price array (use this for daily snapshot), etc.

**Verified symbols (May 2026):**

| Pyth Benchmarks symbol | Description |
|------------------------|-------------|
| `Crypto.BTC/USD` | BTC |
| `Crypto.ETH/USD` | ETH |
| `Crypto.SUI/USD` | SUI |
| `Crypto.SOL/USD` | SOL |
| `Crypto.NAVX/USD` | NAVX |
| `Crypto.USDY/USD` | Ondo USDY (yield-bearing) |
| `Metal.XAU/USD` | Gold (note: `Metal.` prefix, not `Crypto.`) |

**Fetch + parse pattern (one feed):**

```sql
WITH pyth_btc_resp AS (
  SELECT http_get(
    'https://benchmarks.pyth.network/v1/shims/tradingview/history'
      || '?symbol=Crypto.BTC%2FUSD&resolution=1D'
      || '&from=' || cast(cast(to_unixtime(cast(CURRENT_DATE - INTERVAL '91' DAY AS timestamp)) AS bigint) AS varchar)
      || '&to=' || cast(cast(to_unixtime(CURRENT_TIMESTAMP) AS bigint) AS varchar),
    ARRAY['Content-Type: application/json']
  ) AS resp
),
btc_daily AS (
  SELECT
    DATE(from_unixtime(t_val)) AS price_date,
    c_val AS price
  FROM pyth_btc_resp,
       UNNEST(CAST(json_extract(resp, '$.t') AS array(bigint)),
              CAST(json_extract(resp, '$.c') AS array(double))) AS t(t_val, c_val)
)
SELECT * FROM btc_daily
```

Multiple feeds in one query: wrap each in its own `*_resp` CTE, `UNION ALL` the parsed rows with a `feed` tag, then `GROUP BY price_date` and `MAX(CASE WHEN feed = 'BTC' THEN price END)` to pivot.

**When to use Hermes `/v2/updates` vs Benchmarks:**

| Use case | Endpoint |
|----------|----------|
| Live/latest price (one snapshot, any number of feeds in one call) | Hermes `/v2/updates/price/latest` |
| Single historical point in time (any number of feeds in one call) | Hermes `/v2/updates/price/<ts>` |
| Bulk historical (e.g., 30/90/365 days of daily prices) | **Benchmarks `/v1/shims/tradingview/history`** |
| Confidence intervals (`conf`), EMA prices | Hermes only |

For a worked Navi historical example with 7 feeds × 90 days using Benchmarks, see `references/protocol-patterns.md` § "V0.2 — Historical replay" and live query `7528506`.

### Dune's per-query HTTP cap

Dune limits a single query to ~40 outbound HTTP calls. Plan accordingly: dynamic-discovery pipelines (multi-stage RPC) plus Pyth fetching can hit this ceiling. The Navi V9.5.2 historical query stays under by (1) restricting `suix_getCoinMetadata` to the 7 `::coin::COIN` reserves that actually need disambiguation rather than all 35, and (2) using Benchmarks one-call-per-feed instead of Hermes one-call-per-(date,feed).

## Performance Best Practices

1. **Partition prune with `date`.** Not optional. Include in the outermost WHERE *and* inside every CTE branch of UNION ALL queries.

2. **Prefer `event_type` string filtering over package+module separate filters.** `event_type IN (...)` is one prunable predicate.

3. **CTE pre-filter before UNION.** Each branch of UNION ALL applies its own date filter and event_type filter, not relying on outer WHERE.

4. **Avoid `SELECT *` on `sui.transactions` and `sui.objects`.** Both have multi-KB string columns.

5. **Use `APPROX_DISTINCT` for high-cardinality counts** when exact precision isn't needed.

6. **Group by `date` directly.** Not `DATE_TRUNC('day', from_unixtime(timestamp_ms/1000))`.

7. **For LiveFetch: batch RPC calls.** `sui_multiGetObjects` with 35 IDs in one call beats 35 separate `sui_getObject` calls by an order of magnitude.

8. **Materialize long-running queries.** If a query takes >60s and gets reused, materialize via incremental queries.

## Anti-Patterns (Observed in Real Dashboards)

### Anti-pattern 1: No partition filter

```sql
-- BAD: full history scan
SELECT date, concat('0x', lower(to_hex(sender))) AS wallet
FROM sui.events
WHERE event_type IN ('<pkg>::<module>::DepositEvent', ...)
```

**Fix:** Add `AND date >= CURRENT_DATE - INTERVAL '180' DAY`.

### Anti-pattern 2: Comparing binary to string

```sql
-- BAD: silently returns no rows
WHERE sender = '0xabcdef...'

-- GOOD:
WHERE sender = from_hex('abcdef...')  -- no 0x prefix inside from_hex
```

### Anti-pattern 3: Single-package filter when protocol has upgraded

```sql
-- BAD: only post-upgrade era
WHERE event_type LIKE '0xf95b06141%::lending_market::%'

-- GOOD: explicit union of all known package eras
```

### Anti-pattern 4: `LIKE` on event_type instead of IN

```sql
-- BAD: harder to prune
WHERE event_type LIKE '%DepositEvent'

-- GOOD: exact IN list with full event_type strings
```

### Anti-pattern 5: Treating `event_json` as native JSON

```sql
-- BAD
WHERE event_json.amount > 1000000

-- GOOD
WHERE cast(json_extract_scalar(event_json, '$.amount') as decimal(38,0)) > 1000000
```

### Anti-pattern 6: Hardcoded values to "fix" missing on-chain data

```sql
-- BAD: hardcoded balances quickly stale
SELECT 'enzoBTC' AS symbol, 435 AS supply, 78000 AS price

-- GOOD: LiveFetch the current state
WITH live_state AS (SELECT http_post(...) AS resp) ...
```

### Anti-pattern 7: Mislabeling protocol identity

The most-cited "Navi Protocol" dashboard on Dune (mementomori7777) was actually querying Suilend (`0xf95b06141...::reserve::ReserveAssetDataEvent`). Always cross-check package hexes against protocol docs before trusting a dashboard's title.

### Anti-pattern 8: Joining `prices.hour` without double-hex encoding

```sql
-- BAD: zero matches because prices.hour double-encodes addresses
LEFT JOIN prices.hour pl ON pl.contract_address_varchar = canonical_addr

-- GOOD:
LEFT JOIN prices.hour pl ON pl.contract_address_varchar = '0x' || to_hex(to_utf8(canonical_addr))
```
