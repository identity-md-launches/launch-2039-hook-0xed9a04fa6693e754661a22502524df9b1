# PLAYGROUND launcher

`PlaygroundLauncher` creates **PLAYGROUND (PG)** and its canonical **PG/IMD** pool through the specified Ethereum ERC20T factory. It is a single-use application, deployed first and operated by the launch owner afterward. No transaction is broadcast by this repository.

| Launch property | Value |
| --- | --- |
| Initial total supply | 1,000,000,000 PG, 18 decimals (`1e27` base units) |
| Beneficiary allocation | 50,000,000 PG (5%) |
| Liquidity allocation | 950,000,000 PG (95%) |
| Allocation and tax beneficiary | `0xcB58AdA9F7338Bfbe06Ec647f27DE8D0664dddaC` |
| Buy/sell tax | 250 basis points (2.5%) total |
| Included protocol portion | 15 basis points (0.15%) |
| Beneficiary portion | 235 basis points (2.35%) |
| Launch decay | Disabled: both launch tax and decay interval are zero |
| Opening valuation target | $20,000 fully diluted valuation (FDV) |
| Pair | PG / Ethereum IMD |

## Deployment parameters

Deploy only `src/PlaygroundLauncher.sol:PlaygroundLauncher` as the application, with one nonpayable constructor argument:

| Argument | Manifest binding | Value for this assignment |
| --- | --- | --- |
| `address owner_` | `$owner` | `0x1EE3ffadfE138415A2ddaedeEBe5F46616fA413d` |

The constructor makes no external calls and works on an empty chain. It assigns no authority to its deploying factory or transaction origin. The launcher has no proxy, upgrade mechanism, arbitrary-call function, minting authority, or funding requirement. Its owner is immutable. There is intentionally no `launch.json`; the manifest stage supplies it.

The following dependencies are fixed in the launcher, checked on first use, and cannot be replaced by its owner:

| Dependency | Ethereum address |
| --- | --- |
| Requested factory | `0x801411c6aCeC4Fa80c75c5d3C0eAe13C84f8a173` |
| Requested hook | `0xed9A04Fa6693e754661A22502524DF9b1857e544` |
| Required ERC20T implementation | `0x2df7DCf4D19a7924e00AE96629CC1d1261670eEe` |
| IMD | `0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7` |
| Uniswap v4 PoolManager | `0x000000000004444c5dc75cB358380D2e3dE08A90` |
| Uniswap v4 PositionManager | `0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e` |
| Permit2 | `0x000000000022D473030F116dDEE9F6B43aC78BA3` |

Addresses and ABI provenance are recorded in [DEPENDENCIES.md](docs/DEPENDENCIES.md). Ethereum chain ID 1 is enforced when previewing or launching. The constructor itself has no chain dependency.

## After launch

After the application deployment, the **launch owner**, not the application deployer, performs these operational steps:

1. Obtain a current USD price for one whole IMD from independently checked market data. Call `setImdUsdPrice(uint256 priceUsdWad, uint64 observedAt)`, using USD scaled by `1e18` and the actual observation's Unix timestamp. There is no default price, feed address, or automatic oracle. The owner is responsible for the price's accuracy and avoiding a manipulable single-block pool quote. Future timestamps and observations at least one hour old are rejected.
2. Inspect `tokenConfig()`, `startingPriceQuote()`, and both `preview(true)` and `preview(false)`. The token address is determined by the shared factory's nonce, so its order relative to IMD is unknown in advance. In the preview, the upstream field named `effectivePriceWei` means **IMD base units per whole PG**, not ETH wei. Confirm the effective USD FDV and the registered IMD-to-ETH conversion pool's liquidity before execution.
3. Call `launch()` with **zero ETH** before the quote is one hour old. A refreshed quote can be set if needed. No IMD deposit or token approval is required. All calls must come from `owner()`; an unrelated submitter cannot launch early or alter the price.
4. Record the `PlaygroundLaunched` event and `token()` address; verify PG metadata, balances, pool key, fee settings, and token owner. The existing factory and token emit the pool's starting price and ticks. Publish the confirmed addresses through the deployment handoff.

Token creation, pool initialization/seeding, the beneficiary transfer, and the final ownership transfer occur in one transaction. A failure reverts them all and leaves the launcher available for retry. After success the launcher rejects further launches and price changes.

## Price and liquidity assumptions

“Starting valuation” means **FDV**, using all one billion tokens, rather than deposited dollar liquidity. The target opening price is `$0.00002/PG`. Given `P = USD per IMD * 1e18`, the launcher requests:

```text
IMD base units per whole PG = ceil(2e31 / P)
effective USD FDV = effectivePriceWei * P * 1,000,000,000 / 1e36
```

For illustration only, an IMD price of $1 would request `20,000,000,000,000` IMD base units per PG. This example is used in tests; it is not installed as a production setting. Values outside `1 <= P <= 2e31` are rejected. Division adds less than one IMD base unit; operators must check its relative significance at extreme prices.

The factory then rounds the starting tick upward in economic price to the spacing of 60. That adds less than approximately 0.602% relative to the requested quote price, subject to integer rounding. A mathematically exact $20,000 opening price is generally not representable on this grid. The result is a $20,000 target with disclosed rounding, and its USD value changes with IMD's market price. There is no ongoing price peg or guaranteed market capitalization.

The factory seeds **single-sided PG liquidity** at the position boundary. All 950 million PG are assigned to liquidity; tiny integer-rounding residue remains locked in the PG contract. The position NFT is locked at the ERC20T implementation's hardcoded burn destination. This is existing factory behavior, not an unknown recipient substituted by this application. Neither the launcher nor its owner can withdraw that initial position. No IMD is initially deposited: buyers supply IMD, and initial sells require quote liquidity from trading.

## Fees and administrative responsibilities

The hook applies a 250-bps tax to canonical pool trades, with the 15-bps protocol portion **inside** it. The hook converts the fee through its configured pools to ETH, pays `floor(realized ETH * 15 / 250)` to its protocol recipient, and sends the remainder to the beneficiary. Thus the beneficiary receives 94% of realized fee proceeds, corresponding to 235/250 of the nominal tax. Conversion fees, slippage and integer dust affect realized ETH; this is not a promise of an exact dollar payout. The PG pool's separate LP fee is zero.

The existing ERC20T implementation gives its final owner token administration. This launcher transfers that ownership to `$owner` after distributing the 5%. **The initial 2.5% tax and recipient are not permanently immutable:** the token owner can later set tax within the implementation's 30–500-bps limits, change recipients, manage distributors, toggle the shared distributor registry and allow external liquidity. Those powers are inherited, tested, and must be operated consistently with the promised terms. There is no public mint; holders may burn their own tokens. The launch decay configuration remains disabled.

ERC20T restricts contract transfers to its owner, approved distributors and hook-authorized pool settlement. Direct qualifying EOA-to-EOA transfers are untaxed. Smart-wallet and third-party contract integrations may need distributor approval. Global distributors start enabled, external liquidity starts disabled, and PG cannot become a quote token because it is itself IMD-quoted. The shared hook's administrator controls its distributor registry, external base registration/enabling, and protocol fee recipient. The launcher checks the current 15-bps constant and IMD registration at launch; it does not control that external administrator or guarantee future conversion-pool liquidity.

The deployment service handles manifest generation, final review, source verification and recording deployments. The launch owner handles the price observation, launch execution and later token administration. Independent security review remains a release responsibility; see [SECURITY.md](docs/SECURITY.md).

## Build and test

```sh
forge build
FOUNDRY_FUZZ_SEED=0x264abe70522ef0b0f11976770e148dba39b0d34d2e2faad777263c4925419190 forge test
forge fmt --check
```

The root configuration pins Solidity 0.8.26, Cancun, optimizer 200 runs, and no bytecode metadata hash. Dependencies are ordinary vendored files. Submitted tests use no RPC, environment reads, FFI or filesystem permissions. They include real deployed bytecode integration, actual v4 swaps and fee settlement, allocation conservation, both address orderings, price rounding/freshness, authorization, missing/incompatible dependencies, atomic rollback, reentrancy, LP lock and explicit owner handoff. Fuzz tests run 512 cases each. Test-only infrastructure under `test/` is not part of the application deployment.
