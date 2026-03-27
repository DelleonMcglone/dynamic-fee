# DynamicFee Hook — Nezlobin's Directional Fee Framework

A Uniswap v4 hook that protects LPs from toxic arbitrage by charging **asymmetric fees** based on whether swaps move the pool price toward or away from the Chainlink oracle price.

## How It Works

1. **Get Oracle Price** — Fetch current price from Chainlink (ETH/USD, LINK/USD)
2. **Get Pool Price** — Derive from current `sqrtPriceX96`
3. **Calculate Deviation** — `|poolPrice - oraclePrice| / oraclePrice` in basis points
4. **Classify Zone** — TIGHT (0-1%), NORMAL (1-3%), ELEVATED (3-5%), HIGH (5-10%), EXTREME (>10%)
5. **Determine Direction** — Does swap move price TOWARD or AWAY from oracle?
6. **Apply Asymmetric Fee** — Lower fee for stabilizing trades, higher for arbitrage

### Fee Matrix (basis points)

| Zone | Toward Oracle | Away from Oracle |
|------|:---:|:---:|
| TIGHT (0-1%) | 5 | 10 |
| NORMAL (1-3%) | 10 | 30 |
| ELEVATED (3-5%) | 20 | 50 |
| HIGH (5-10%) | 30 | 100 |
| EXTREME (>10%) | 50 | 200 |

Max fee cap: **200 bps (2%)**

## Architecture

```
src/
├── DynamicFee.sol              # Main hook — beforeSwap returns dynamic fee
├── base/
│   └── BaseHook.sol            # Minimal base hook with permission validation
└── libraries/
    ├── OracleManager.sol       # Chainlink integration (staleness checks, decimal normalization)
    ├── DeviationMonitor.sol    # Deviation calculation and zone classification
    └── FeeCalculator.sol       # Direction determination and fee matrix lookup
```

### Hook Permissions

| Hook | Enabled | Purpose |
|------|---------|---------|
| `beforeInitialize` | Yes | Allow pool registration |
| `beforeSwap` | Yes | Calculate and return dynamic fee with `OVERRIDE_FEE_FLAG` |
| `afterSwap` | Yes | Update zone tracking, emit `ZoneTransition` events |

## Build & Test

```bash
# Install dependencies
forge install

# Build
forge build

# Run tests
forge test -vvv

# Run with gas reporting
forge test --gas-report

# Coverage
forge coverage
```

## Deploy to Base Sepolia

```bash
# Copy and fill environment variables
cp .env.example .env

# Deploy hook
forge script script/Deploy.s.sol:DeployDynamicFee \
  --rpc-url $BASE_SEPOLIA_RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast \
  --verify

# Create pools (after setting HOOK_ADDRESS in .env)
forge script script/CreatePools.s.sol:CreatePools \
  --rpc-url $BASE_SEPOLIA_RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast

# Execute test swaps
forge script script/TestSwap.s.sol:TestSwap \
  --rpc-url $BASE_SEPOLIA_RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast
```

## Deployed Contracts (Base Sepolia)

> Fill in after deployment

| Contract | Address | BaseScan |
|----------|---------|----------|
| DynamicFee Hook | `0x...` | [Link]() |
| ETH/USDC Pool | `0x...` | [Link]() |
| LINK/USDC Pool | `0x...` | [Link]() |
| ETH/LINK Pool | `0x...` | [Link]() |

## Key Transactions

> Fill in after test swaps

| Transaction | Tx Hash | Fee Applied |
|-------------|---------|-------------|
| ETH/USDC Small Swap | `0x...` | ... bps |
| ETH/USDC Medium Swap | `0x...` | ... bps |
| ETH/USDC Large Swap | `0x...` | ... bps |

## Example Scenarios

**Arbitrage Against Oracle (High Fee)**
- Oracle: ETH = $3000, Pool: ETH = $2900 (underpriced)
- Swap: Buy ETH (moves price away from oracle)
- Fee: 100+ bps (HIGH zone, AWAY direction)

**Stabilizing Trade (Low Fee)**
- Oracle: ETH = $3000, Pool: ETH = $3100 (overpriced)
- Swap: Sell ETH (moves price toward oracle)
- Fee: 10-30 bps (incentivizing rebalance)

## Network Details

- **Chain**: Base Sepolia (Chain ID 84532)
- **PoolManager**: `0xC81462Fec8B23319F288047f8A03A57682a35C1A`
- **Chainlink ETH/USD**: `0x4aDC67d868Ec4f4cD97E5c0a150AE3e2DB505D65`
- **Chainlink LINK/USD**: `0xb113F5A928BCfF189C998ab20d753a47F9dE5A61`

## License

MIT
