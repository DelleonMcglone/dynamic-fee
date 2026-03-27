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
| DynamicFee Hook | 0x25F98678a92Af6aCC54cE3cE687762aCA316C0C0 | [view](https://sepolia.basescan.org/address/0x25F98678a92Af6aCC54cE3cE687762aCA316C0C0) |
| tWETH (Mock) | 0x99cbB0a7B93000304CD1f345f3619aA2e2a04178 | [view](https://sepolia.basescan.org/address/0x99cbB0a7B93000304CD1f345f3619aA2e2a04178) |
| tUSDC (Mock) | 0xD7a18736e6E76091069398A6b7ed30b696938704 | [view](https://sepolia.basescan.org/address/0xD7a18736e6E76091069398A6b7ed30b696938704) |
| tLINK (Mock) | 0x3aD21bfc40d1C4232599ee61412976980f55463e | [view](https://sepolia.basescan.org/address/0x3aD21bfc40d1C4232599ee61412976980f55463e) |
| ETH/USD Oracle (Mock) | 0xa4f7aa1Facd8056D27047adD81Cb92dFAA2a5C71 | [view](https://sepolia.basescan.org/address/0xa4f7aa1Facd8056D27047adD81Cb92dFAA2a5C71) |
| LINK/USD Oracle (Mock) | 0x09C3483Cb112e39754b367C14A94E8F883194554 | [view](https://sepolia.basescan.org/address/0x09C3483Cb112e39754b367C14A94E8F883194554) |
| PoolModifyLiquidityTest | 0x07D9e709ad91465Cd790486b86dddA24D94b2904 | [view](https://sepolia.basescan.org/address/0x07D9e709ad91465Cd790486b86dddA24D94b2904) |
| PoolSwapTest | 0x779469D958cdc0ac7e00B4933E2C7b1974bc5Fd3 | [view](https://sepolia.basescan.org/address/0x779469D958cdc0ac7e00B4933E2C7b1974bc5Fd3) |
| Uniswap v4 PoolManager | 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408 | [view](https://sepolia.basescan.org/address/0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408) |

## Key Transactions

### Deployment

| Action | Transaction |
|--------|-------------|
| Deploy tWETH | [0x7e2f2c…](https://sepolia.basescan.org/tx/0x7e2f2c547a95199e16ce0504d25d00fdfbc46644353715d94f41b32550980382) |
| Deploy tUSDC | [0x2d82d3…](https://sepolia.basescan.org/tx/0x2d82d33cde90fc92ae9442c3ad98c7642a77ecc9efa95732c1ea722cfd9b9e75) |
| Deploy tLINK | [0x1d26e2…](https://sepolia.basescan.org/tx/0x1d26e259eaafe9863fb6fe57666850340838fd00ab8998ce0ec0c465eb2507a9) |
| Deploy ETH/USD Oracle | [0x1e8200…](https://sepolia.basescan.org/tx/0x1e8200e07c82fa16ec2232b33fc0a00c0ccb0a4ac9d25a05fd9023fdaefead85) |
| Deploy LINK/USD Oracle | [0x208735…](https://sepolia.basescan.org/tx/0x20873b559213b9f6d7307b5fee1dfa3d052b4d4aa239e7ced63a65a7507e0d02) |
| Deploy DynamicFee Hook (CREATE2) | [0x60d379…](https://sepolia.basescan.org/tx/0x60d3796f389116a4cf956ddced008bb2d352c85e21cb27f1770e46962c29c34b) |
| Deploy LiquidityRouter | [0x7e1a0c…](https://sepolia.basescan.org/tx/0x7e1a0cefa414c0f07009df2d260d35f5ea424e1bdccbddd7120040f4a287cb06) |
| Deploy SwapRouter | [0x333ab3…](https://sepolia.basescan.org/tx/0x333ab365825bf98e55569b8cb13aa51346e3559e9c7c6eeca5d3ece0f07952cd) |

### Pool Creation & Liquidity

| Action | Transaction |
|--------|-------------|
| Configure ETH/USDC pool | [0xbca925…](https://sepolia.basescan.org/tx/0xbca9254f761fa645ccb83e2dc7ea50825f1c20a1b415bece666dd91b4fb6a409) |
| Initialize ETH/USDC pool | [0x7e700f…](https://sepolia.basescan.org/tx/0x7e700ffb1cd12c226b29daf0f2a04f3473d4ebaa4f6901ad56adc02de377bc7c) |
| Add liquidity ETH/USDC | [0x9e0c48…](https://sepolia.basescan.org/tx/0x9e0c48e9e2af83d6fc11fbf4aae8e927dfe27e0bbfe4c27845efec8b77270572) |
| Configure LINK/USDC pool | [0x933aaf…](https://sepolia.basescan.org/tx/0x933aaf53cf24bfe1e27f4d253c5fe2ce834f8663934c6b0eecf62741decdf5cc) |
| Initialize LINK/USDC pool | [0x2583c3…](https://sepolia.basescan.org/tx/0x2583c34223350ca73e28dccc77c6903a82a72e35acdbd12f8e03e848dd2ffc22) |
| Add liquidity LINK/USDC | [0x8d928b…](https://sepolia.basescan.org/tx/0x8d928b49e3ec812d553ee552ad8f4dc320ddd2667e32c381c90b87b33e283f54) |
| Configure ETH/LINK pool | [0x889e34…](https://sepolia.basescan.org/tx/0x889e34ac7664bbed8f9cb98f74d63cd1d68477ccc9d7797064c4146e990c3175) |
| Initialize ETH/LINK pool | [0x4768c2…](https://sepolia.basescan.org/tx/0x4768c268e77b9986c5fa0e17992f2b7df2f0da28110adae8d0a5331295ffcb58) |
| Add liquidity ETH/LINK | [0x0fec8a…](https://sepolia.basescan.org/tx/0x0fec8aadb1572a74135982120b7ccd4b20642795051c183007c8e8c1e67ff2d1) |

### Test Swaps (9 total — 3 per pool)

| Pool | Swap | Transaction |
|------|------|-------------|
| ETH/USDC | Small (1 tWETH → tUSDC) | [0x46e46b…](https://sepolia.basescan.org/tx/0x46e46be3994640741af711893ad8e95a6d9a329e84eb4e098b20ba296b6079bf) |
| ETH/USDC | Medium (10 tWETH → tUSDC) | [0xe8a492…](https://sepolia.basescan.org/tx/0xe8a4927414575cecea431dc0dd3ebffc8e71ad397aec9b183fac13c29623a1d5) |
| ETH/USDC | Reverse (5 tUSDC → tWETH) | [0x273014…](https://sepolia.basescan.org/tx/0x273014c0e05ccea57bccdf12a1fa66d3d4b914c60ff253dd1dfade7215fcd41f) |
| LINK/USDC | Small (1 tLINK → tUSDC) | [0xe67d75…](https://sepolia.basescan.org/tx/0xe67d75f5def20837be2487e87528ef218ea368fbb911163b033d79fe9ed51c45) |
| LINK/USDC | Medium (10 tLINK → tUSDC) | [0xdde162…](https://sepolia.basescan.org/tx/0xdde1628719bfe5505aa62826fb48bbbabdd3e50710fd52141c79afbd7d8c13dc) |
| LINK/USDC | Reverse (5 tUSDC → tLINK) | [0x0c6910…](https://sepolia.basescan.org/tx/0x0c6910496709633677e4a2e8746d96d187febf24a5acdc08ddab4662741be4cc) |
| ETH/LINK | Small (1 tWETH → tLINK) | [0x3436f0…](https://sepolia.basescan.org/tx/0x3436f0ee6662a37cc6e4a13f7942d7388a48ab8a38478cd84e47784f2c0e2161) |
| ETH/LINK | Medium (10 tWETH → tLINK) | [0x9dfdfcef…](https://sepolia.basescan.org/tx/0x9dfdfcef3ce0f43565bef070a7641dc58e30a607710a16e80e9043299e89ccf4) |
| ETH/LINK | Reverse (5 tLINK → tWETH) | [0x075155…](https://sepolia.basescan.org/tx/0x0751555fabeb9b97c85e412ff2ccc2520db45e140d3ce17f0f487f76d6454494) |

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
