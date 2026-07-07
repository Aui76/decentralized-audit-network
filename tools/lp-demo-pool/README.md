# LP demo pool — Part A operator runbook (Base Sepolia 84532)

**Scope:** L2/ops + membrane only. No cell contract changes. Part B (mint governor vs real reserves) is record-only — do not fix here.

**Testnet only** (DEC-14). Never mainnet. Do not commit `.env`.

## Verified addresses (2026-07-04)

Loaded from [`addresses-84532.json`](./addresses-84532.json) at script runtime — do not hardcode elsewhere.

| Contract | Address |
|----------|---------|
| CellEscrow | `0x7d2B523f78968d78eE2071E9F25BB928aDa81B54` |
| CellToken (AUDIT) | `0x756bD73C62C33eb4E4fD7028b9fe14314a94851F` |
| Uniswap V3 Factory | `0x4752ba5DBc23f44D87826276BF6Fd6b1C372aD24` |
| NonfungiblePositionManager | `0x27F971cb582BF9E50F397e4d29a5C7A34f11faA2` |
| SwapRouter02 | `0x94cC0AaC535CCDB3C01d6787D6413C739ae12bc4` |
| WETH9 | `0x4200000000000000000000000000000000000006` |
| Fee tier | 1% (`10000`) |

## Part B guardrail — keep seed small

`lpBalance` governs mint cap: `min(activityMint, mintLpCapBps * lpBalance / 1e4)` (500 bps).

- **Do not** drain `lpBalance` to 0 (`lp == 0` skips the cap).
- Recommended seed: **5 AUDIT** (`5e18` wei) — ~4.6% of ~108 AUDIT bucket; cap moves ~5.4 → ~5.15 AUDIT/block.

Record `lpBalance` before and after each withdraw.

Deploy manager with **`vm.addr(PRIVATE_KEY)`** as admin — not `msg.sender` (Foundry script quirk on 84532).

```powershell
cd C:\Users\cloni\Documents\Claude\network\cell
# .env: PRIVATE_KEY (escrow admin = 0xb0A354…), BASE_SEPOLIA_RPC_URL
```

Escrow admin signs `setLPManager`. Same key is `DemoLPManager` admin after deploy.

## Step 1 — Deploy DemoLPManager

```powershell
forge script script/lp-demo/LpDemoDeployManager.s.sol:LpDemoDeployManager `
  --rpc-url base_sepolia --broadcast
```

Save logged `DemoLPManager` address → `DEMO_LP_MANAGER` env / `84532-cell.json` field `demoLpManager`.

## Step 2 — setLPManager + withdraw + pool + position

```powershell
$env:DEMO_LP_MANAGER = "0x..."   # from step 1
$env:LP_DEMO_SEED_WEI = "5000000000000000000"   # optional; default 5e18
forge script script/lp-demo/LpDemoPartA.s.sol:LpDemoPartA `
  --rpc-url base_sepolia --broadcast
```

Logs: `lpBalance before/after`, `pool`, position `tokenId`, ticks.

Update `body/deployments/84532-cell.json`: `demoLpPool`, `demoLpSeedTx`, `demoLpPositionId`, `demoLpBalanceBefore`, `demoLpBalanceAfter`.

## Step 3 — Smoke swap (WETH → AUDIT)

```powershell
$env:LP_DEMO_SWAP_ETH_WEI = "1000000000000000000"   # 0.001 ETH default
forge script script/lp-demo/LpDemoSwapSmoke.s.sol:LpDemoSwapSmoke `
  --rpc-url base_sepolia --broadcast
```

Record swap tx → `demoLpSwapTx` in deployment JSON and `RealDeal/notebook/DEPLOYMENT-LOG.md`.

## Step 4 — Membrane

Open [`body/membrane/demo-pool.html`](../../membrane/demo-pool.html) (local static server or deployed body). Reads `demoLpPool` from `84532-cell.json` and live `slot0` / `liquidity` via Base Sepolia RPC.

## Recovery

`DemoLPManager.recover(to, amount)` — admin only; pulls leftover AUDIT from the helper contract (not from Uniswap position NFT).

## Files

| Path | Role |
|------|------|
| `contracts/DemoLPManager.sol` | LP manager helper |
| `addresses-84532.json` | Verified 84532 addresses + seed rationale |
| `cell/script/lp-demo/*.s.sol` | Forge broadcast scripts |
| `body/membrane/demo-pool.html` | DEMO-labelled read surface |
