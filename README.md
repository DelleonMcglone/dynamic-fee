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
    └── FeeCalculator.sol       # Fee matrix lookup
```

### Hook Permissions

| Hook | Enabled | Purpose |
|------|---------|---------|
| `beforeSwap` | Yes | Calculate and return dynamic fee with `OVERRIDE_FEE_FLAG` |
| `afterSwap` | Yes | Update zone tracking, emit `ZoneTransition` events |

## Build & Test

```bash
forge install
forge build
forge test -vvv
forge coverage
```

## Deployed Contracts (Base Sepolia)

| Contract | Address | BaseScan |
|----------|---------|----------|
| DynamicFee Hook | 0xb662c25Fe810b766C7b94172d57E98D2698300C0 | [view](https://sepolia.basescan.org/address/0xb662c25Fe810b766C7b94172d57E98D2698300C0) |
| tWETH (Mock) | 0x839Cc782708f1768F0F7591eA0c7D08290ba2a3c | [view](https://sepolia.basescan.org/address/0x839Cc782708f1768F0F7591eA0c7D08290ba2a3c) |
| tUSDC (Mock) | 0x8b6de320b93c2f8dEE5C9392A001E03CE6cc8Fe6 | [view](https://sepolia.basescan.org/address/0x8b6de320b93c2f8dEE5C9392A001E03CE6cc8Fe6) |
| tLINK (Mock) | 0x16538c37818d580F7f919D4583D7935C8624567E | [view](https://sepolia.basescan.org/address/0x16538c37818d580F7f919D4583D7935C8624567E) |
| ETH/USD Oracle (Mock) | 0x178eda13C9992B755940C3F85ef094b566D72099 | [view](https://sepolia.basescan.org/address/0x178eda13C9992B755940C3F85ef094b566D72099) |
| LINK/USD Oracle (Mock) | 0xcbE2770BC2c72d59b5ED8373587c69160Bf02f9C | [view](https://sepolia.basescan.org/address/0xcbE2770BC2c72d59b5ED8373587c69160Bf02f9C) |
| PoolModifyLiquidityTest | 0x9f12E9d064398e07153Ca7E1401C71343edB772B | [view](https://sepolia.basescan.org/address/0x9f12E9d064398e07153Ca7E1401C71343edB772B) |
| PoolSwapTest | 0xF778eF19F4A0065430C55a7cD09d287368947C29 | [view](https://sepolia.basescan.org/address/0xF778eF19F4A0065430C55a7cD09d287368947C29) |
| Uniswap v4 PoolManager | 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408 | [view](https://sepolia.basescan.org/address/0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408) |

## Key Transactions

### Deployment

| Action | Transaction |
|--------|-------------|
| Deploy tWETH | [0x0eeded…](https://sepolia.basescan.org/tx/0x0eeded013c0ce4cd138f1081ee8f7d2cc0e8eadf7f2ac3b4b40df2f5506161f1) |
| Deploy tUSDC | [0xf7451c…](https://sepolia.basescan.org/tx/0xf7451c25a2bcaba5e6ee35804dabf067b74306938794f2625b823b762e61e15e) |
| Deploy tLINK | [0x7ca07c…](https://sepolia.basescan.org/tx/0x7ca07cf33e8a8ee1eae3f8ab7e8b4f88e5b636930425a885dae006676e3dd97b) |
| Deploy ETH/USD Oracle | [0x49322a…](https://sepolia.basescan.org/tx/0x49322aebeb448f0e9709e1ccb496d015ee5cd689fa9a03b715e5d263a685b3e4) |
| Deploy LINK/USD Oracle | [0xe66bda…](https://sepolia.basescan.org/tx/0xe66bda56f08fac31a546d396a0db7c6a4951d41146c26670de12d8d4cff57a1e) |
| Deploy DynamicFee Hook (CREATE2) | [0x82a2f9…](https://sepolia.basescan.org/tx/0x82a2f9f92a7087ce2282f474ab185a4aaa14de9cebab834c2dcba597711281af) |
| Deploy LiquidityRouter | [0x6dd591…](https://sepolia.basescan.org/tx/0x6dd591d56a2c750814fb4cbaece047a983dd7d5ccd774ad2fe024205c666cba5) |
| Deploy SwapRouter | [0xa8cf52…](https://sepolia.basescan.org/tx/0xa8cf52b5980d9410575d04f03896357f33c7b703d2ff9a5e67bc6cbd9139dc3b) |

### Pool Creation & Liquidity

| Action | Transaction |
|--------|-------------|
| Configure ETH/USDC pool | [0x651048…](https://sepolia.basescan.org/tx/0x651048614253ab17975f7f45d3fcd4ea34adc21b320bbb27e08fac9b9f4f0818) |
| Initialize ETH/USDC pool | [0x5c74b4…](https://sepolia.basescan.org/tx/0x5c74b40d46d8f22aa59d6c5cee81e7a639bed6c6f95ba5af0ab30b96ac041284) |
| Add liquidity ETH/USDC | [0x4e805c…](https://sepolia.basescan.org/tx/0x4e805cafa60ac8414e464c6e1d668c34ea7b901b64e310b9251bed130eee37aa) |
| Configure LINK/USDC pool | [0x21a031…](https://sepolia.basescan.org/tx/0x21a03182bbf4bb41e194fdf6254fdd70c67c1ebb4a3b42bd3f5f99a3068d3900) |
| Initialize LINK/USDC pool | [0xccc694…](https://sepolia.basescan.org/tx/0xccc694552d142f425051dce35bd159038eb42675a15f56b4c5b8c068cfac136e) |
| Add liquidity LINK/USDC | [0x95c24f…](https://sepolia.basescan.org/tx/0x95c24fa425412beca6dea06536989737e7055f236ff2f0c108d82b223c80fd44) |
| Configure ETH/LINK pool | [0x372e36…](https://sepolia.basescan.org/tx/0x372e36ffbcd32b44b3fc78bddcdb808333f0d84328e4ed79dc2d74f95b48f719) |
| Initialize ETH/LINK pool | [0x67b59b…](https://sepolia.basescan.org/tx/0x67b59b1185111b6e2dff944866ae5857cb0e5c4171df464773afcfb9488e5df3) |
| Add liquidity ETH/LINK | [0xa4a18a…](https://sepolia.basescan.org/tx/0xa4a18a804699ce04a63d936c7879a6e7960d739b98eba24b4173afdcd76c6879) |

### Test Swaps

Test swaps have not yet been re-executed against the new hook deployment. Run [`script/TestSwap.s.sol`](script/TestSwap.s.sol) against the new pools to populate this section.

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
- **PoolManager**: `0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408`
- **Deployer**: `0xbaacDCFfA93B984C914014F83Ee28B68dF88DC87`

## License

MIT
