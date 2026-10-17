# Independent PLAYGROUND tests

These tests extend the accepted integration suite without changing application code or configuration.
They use the existing, committed protocol bytecode fixtures and require no RPC, FFI, environment reads,
downloaded packages, or generated files. The fixture reconstructs a local conversion pool; it does not
reproduce live liquidity or certify an IMD/USD market observation.

| File | Properties exercised |
| --- | --- |
| `PlaygroundLifecycleInvariant.t.sol` | Random price updates, time advances, previews, authorized and unauthorized launches, invalid observations, expiry/retry, and terminal launch state. Ghost state tracks only successful owner actions. |
| `PlaygroundTradingInvariant.t.sol` | Random activity by three traders and four wallets, in both token address orderings. PG balances sum to supply; supply plus explicit burns remains one billion; IMD and native value are conserved; the LP position stays locked; public activity cannot change launch terms. |
| `helpers/PlaygroundTradingHandler.sol` | Buys, sells, isolated round trips, untaxed wallet transfers, burns, overspending, unauthorized administration, and time advances. Swap events independently constrain the net 2.5% tax; each native payout checks the included 15/250 protocol share. Transfer permissions are checked inside the settlement transaction. |
| `PlaygroundPostconditions.t.sol` | Every malformed-token postcondition, rollback/retry, distinct or shared owner/beneficiary roles, clone and implementation reinitialization, price endpoints, and quote monotonicity. |
| `PlaygroundTokenFailures.t.sol` | Unsupported swap rollback, transfer permissions, approval/distributor revocation, invalid fees and recipients, and both ERC20 and Permit2 launch allowance cleanup. |

Each invariant campaign runs 256 sequences of 64 calls, with unexpected handler reverts treated as
failures. Inputs are bounded to meaningful domains, without discarded `assume` cases. Trades use up
to 1,000 IMD per buy and up to the trader's full PG balance per sell. Funding happens only before the
campaign. Successful burns are explicitly accounted for because the supplied ERC20T permits holders
to burn their tokens. Deterministic tests exercise the handlers and pin one-wei, zero, self-transfer,
full-wallet, and insufficient-balance cases.

The trading campaigns retain the launch's administrative settings. Their authorization properties
cover public callers; the existing implementation intentionally lets the owner change tax and
recipient settings. The supplied hook explicitly rejects exact-output swaps with
`ExactOutputNotAllowed()`. The failure test verifies rollback and subsequent exact-input liveness;
the trading campaigns use the supported exact-input mode.

Run the complete suite offline with:

```sh
forge build
FOUNDRY_FUZZ_SEED=0x264abe70522ef0b0f11976770e148dba39b0d34d2e2faad777263c4925419190 forge test
```
