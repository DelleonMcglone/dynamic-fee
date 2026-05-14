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
| DynamicFee Hook | 0x9788B8495ebcEC1C1D1436681B0F56C6fc0140c0 | [view](https://sepolia.basescan.org/address/0x9788B8495ebcEC1C1D1436681B0F56C6fc0140c0) |
| tWETH (Mock) | 0x839Cc782708f1768F0F7591eA0c7D08290ba2a3c | [view](https://sepolia.basescan.org/address/0x839Cc782708f1768F0F7591eA0c7D08290ba2a3c) |
| tUSDC (Mock) | 0x8b6de320b93c2f8dEE5C9392A001E03CE6cc8Fe6 | [view](https://sepolia.basescan.org/address/0x8b6de320b93c2f8dEE5C9392A001E03CE6cc8Fe6) |
| tLINK (Mock) | 0x16538c37818d580F7f919D4583D7935C8624567E | [view](https://sepolia.basescan.org/address/0x16538c37818d580F7f919D4583D7935C8624567E) |
| PoolModifyLiquidityTest | 0x9f12E9d064398e07153Ca7E1401C71343edB772B | [view](https://sepolia.basescan.org/address/0x9f12E9d064398e07153Ca7E1401C71343edB772B) |
| PoolSwapTest | 0xF778eF19F4A0065430C55a7cD09d287368947C29 | [view](https://sepolia.basescan.org/address/0xF778eF19F4A0065430C55a7cD09d287368947C29) |
| Uniswap v4 PoolManager | 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408 | [view](https://sepolia.basescan.org/address/0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408) |

## Deployed Contracts (Unichain Sepolia)

| Contract | Address | Uniscan |
|----------|---------|---------|
| DynamicFee Hook | 0xa5eCBF949D964760f3F7805f59eb4AAc1f2500c0 | [view](https://sepolia.uniscan.xyz/address/0xa5eCBF949D964760f3F7805f59eb4AAc1f2500c0) |
| tWETH (Mock) | 0xC2EcA3888259398562ebe00C7039D52d8B93629F | [view](https://sepolia.uniscan.xyz/address/0xC2EcA3888259398562ebe00C7039D52d8B93629F) |
| tUSDC (Mock) | 0xb6639242Ba9A4799317C889De4c13314dAC6748D | [view](https://sepolia.uniscan.xyz/address/0xb6639242Ba9A4799317C889De4c13314dAC6748D) |
| tLINK (Mock) | 0x9f390f689954805A278b104cf5b5F59529cF779D | [view](https://sepolia.uniscan.xyz/address/0x9f390f689954805A278b104cf5b5F59529cF779D) |
| PoolModifyLiquidityTest | 0x5fa728C0A5cfd51BEe4B060773f50554c0C8A7AB | [view](https://sepolia.uniscan.xyz/address/0x5fa728C0A5cfd51BEe4B060773f50554c0C8A7AB) |
| PoolSwapTest | 0x9140a78c1A137c7fF1c151EC8231272aF78a99A4 | [view](https://sepolia.uniscan.xyz/address/0x9140a78c1A137c7fF1c151EC8231272aF78a99A4) |
| Uniswap v4 PoolManager | 0x00B036B58a818B1BC34d502D3fE730Db729e62AC | [view](https://sepolia.uniscan.xyz/address/0x00B036B58a818B1BC34d502D3fE730Db729e62AC) |

### Key Transactions (Unichain Sepolia)

| Action | Transaction |
|--------|-------------|
| Deploy DynamicFee Hook (CREATE2) | [0xcc6aca…](https://sepolia.uniscan.xyz/tx/0xcc6aca2af0c3746627bef9804718724788260a742924a28e27aab794409e5a30) |
| Deploy tWETH | [0x7342d7…](https://sepolia.uniscan.xyz/tx/0x7342d79588a39f13e4b54f55dd25c1c52a045a48cb53372f1fdd4fcdb428dfb5) |
| Deploy tUSDC | [0xc74196…](https://sepolia.uniscan.xyz/tx/0xc74196fa9190cbb594165da451dc46a852daffd2d46dee9ec4bbd13b4db9f313) |
| Deploy tLINK | [0x67f9df…](https://sepolia.uniscan.xyz/tx/0x67f9df36669b105fd63a88be1967b1e6f290778e286a3401b4648b4e5eb24aab) |
| Initialize ETH/USDC pool | [0xb0e383…](https://sepolia.uniscan.xyz/tx/0xb0e383625cf208a9313ffa9a07172a640158d49c5c09bc08dcea5383ea105be1) |
| Add liquidity ETH/USDC | [0x3b938e…](https://sepolia.uniscan.xyz/tx/0x3b938ecf80633c124fa1fc18f98db8121563308ead4085567c1cce3e2d057f38) |
| Initialize LINK/USDC pool | [0xdcf88a…](https://sepolia.uniscan.xyz/tx/0xdcf88a64ceadf2767c8163f1fa6da1f3149744541899409a7b4d49c7a0b2dc39) |
| Add liquidity LINK/USDC | [0x67582c…](https://sepolia.uniscan.xyz/tx/0x67582c1222bd646be42580013de54cdb2434dad19559972a087c7dec3604081c) |
| Initialize ETH/LINK pool | [0x7ec17e…](https://sepolia.uniscan.xyz/tx/0x7ec17e654f552943a55df20b96ca3819244ff581a1cf40fe5b9feb1adbaa5a5d) |
| Add liquidity ETH/LINK | [0x11d375…](https://sepolia.uniscan.xyz/tx/0x11d3750717f1d82b4e061489bc1369a539fbd065c0d0b09f606aa656eb5d490f) |

## Key Transactions

### Deployment

| Action | Transaction |
|--------|-------------|
| Deploy tWETH | [0x0eeded…](https://sepolia.basescan.org/tx/0x0eeded013c0ce4cd138f1081ee8f7d2cc0e8eadf7f2ac3b4b40df2f5506161f1) |
| Deploy tUSDC | [0xf7451c…](https://sepolia.basescan.org/tx/0xf7451c25a2bcaba5e6ee35804dabf067b74306938794f2625b823b762e61e15e) |
| Deploy tLINK | [0x7ca07c…](https://sepolia.basescan.org/tx/0x7ca07cf33e8a8ee1eae3f8ab7e8b4f88e5b636930425a885dae006676e3dd97b) |
| Deploy DynamicFee Hook (CREATE2) | [0x73dbaf…](https://sepolia.basescan.org/tx/0x73dbaf21f1c403e919dd8808f183a70b23612b843b98bdb5cb222e9711058e24) |
| Deploy LiquidityRouter | [0x6dd591…](https://sepolia.basescan.org/tx/0x6dd591d56a2c750814fb4cbaece047a983dd7d5ccd774ad2fe024205c666cba5) |
| Deploy SwapRouter | [0xa8cf52…](https://sepolia.basescan.org/tx/0xa8cf52b5980d9410575d04f03896357f33c7b703d2ff9a5e67bc6cbd9139dc3b) |

### Pool Creation & Liquidity

| Action | Transaction |
|--------|-------------|
| Configure ETH/USDC pool | [0xfa7cad…](https://sepolia.basescan.org/tx/0xfa7cadd58b821c136d93c76fb8197f3da60fc46c2dea12bd5a1f08ef4fc9bb9b) |
| Initialize ETH/USDC pool | [0x16d5c1…](https://sepolia.basescan.org/tx/0x16d5c15bfcc1ce260f659713bec2ee4719a38efb3df751b2d2d254bf834badbd) |
| Add liquidity ETH/USDC | [0x4a1bfa…](https://sepolia.basescan.org/tx/0x4a1bfa35d7b89458f6455daa85be791c81c3e0672aa077f0c58102a8cc17234f) |
| Configure LINK/USDC pool | [0xaea5ce…](https://sepolia.basescan.org/tx/0xaea5ce81871794fdde5a7afb63226378d8bc4e9be8a7650564cda86d5b9561fc) |
| Initialize LINK/USDC pool | [0x791a48…](https://sepolia.basescan.org/tx/0x791a48a0c06dda63973d374b4474654df7dda77180618547e9aa0d8ef729585c) |
| Add liquidity LINK/USDC | [0xc37d54…](https://sepolia.basescan.org/tx/0xc37d54d9a03702728539385ba28167bedbcc0a808db74c959ae3dc6461d36066) |
| Configure ETH/LINK pool | [0xa369f3…](https://sepolia.basescan.org/tx/0xa369f393f5a70d060d3221cb5726c195957bf8998d8d8fa4911965d5c278b798) |
| Initialize ETH/LINK pool | [0x7cb552…](https://sepolia.basescan.org/tx/0x7cb55213c9cd782d74066060b124fb9dd3c8e3ec94751d45724bc84be9a54039) |
| Add liquidity ETH/LINK | [0x4bd929…](https://sepolia.basescan.org/tx/0x4bd929ea2cefc55406d02474d3833005fd0c4e6a9c361c62ae221034153604b9) |

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
