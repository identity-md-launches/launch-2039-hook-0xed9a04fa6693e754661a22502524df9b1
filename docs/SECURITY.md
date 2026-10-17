# Local security review

This is the builder's manual review and test record, not an independent audit or a claim that third-party contracts are free of defects.

## Reviewed boundaries

- **Authority:** the constructor accepts an explicit launch owner and makes no external calls. Only that owner can set the price or launch. The beneficiary, supply, fees, chain and dependencies are constants. Owner handoff happens after the beneficiary transfer; neither launcher nor factory retains token administration after success.
- **Atomicity:** a failed factory call, false-returning distribution, no-op distribution or failed ownership handoff rolls back the clone, LP creation and wrapper state. Tests confirm the same predicted clone can be launched successfully after the failure is removed.
- **Reentrancy:** `_launching` is set before the first state-changing external call and remains set through all result checks, transfers and ownership handoff. A malicious factory calling through the legitimate owner cannot reenter launch or change the quote. Pre-guard dependency calls are Solidity static calls, so cannot change state.
- **Accounting:** total supply is exactly `1e27`. Both postconditions and integration tests require `50e24` for the beneficiary and `950e24` in pool custody plus locked token dust. No caller-selected recipient or allowance is exposed. The existing token resets launch approvals, verified in tests.
- **Pricing:** USD is an owner attestation, not a trustless oracle. Positive bounded inputs, upward division rounding, explicit units, future observation rejection and a one-hour expiry avoid missing/obviously stale configuration and decimal mistakes. Fuzz tests check the division inequality over the entire accepted numeric range and actual factory launch conservation over a broad economically meaningful range. The factory chooses correct token ordering and aligned ticks.
- **Fees:** actual deployed hook execution is tested in both buy and sell directions. Gross swap event amounts are compared with net receipts to verify 250 bps, and native payouts verify the included 15/250 protocol share. Time passage does not create launch decay.
- **Deployment:** local tests mirror the provided floor's runtime size and forbidden-opcode scan and rehearse explicit ownership through a deploying contract. Solidity is pinned, metadata is omitted, and no linked placeholders or external constructor calls exist.

## Operational trust and limits

The initial token tax and recipient can later be changed by the ERC20T owner. Shared hook administration, IMD ownership/bridge behavior, the external conversion pool and Uniswap infrastructure remain outside the launcher's control. Thin conversion liquidity can reduce payouts or make swaps fail. The one-hour freshness limit does not prove the input quote is accurate, and USD market movement between observation and launch remains an operator risk. Preview is advisory: token ordering can change as other users call the shared factory, which correctly derives ordering during execution.

The LP's locked NFT and token rounding dust are not withdrawable by this application. Underlying ERC20T restrictions mean some contract wallets/integrations need distributor approval. Its default global distributor registry creates a dependency on the hook's administrator. The supplied hook was unverified at the inspected explorer; runtime-based tests cannot substitute for its full source review.

Foundry tests and manual review were run. Slither, Mythril, formal verification and an independent adversarial review were not run. The provided protected suite depends on manifest-generated inputs and a separate `OwnerChecks.sol` that is not in the read bundle; no claim is made that that external harness ran here. It must be run by the verifier against the final manifest.

Foundry's build lint emits advisory timestamp, reentrancy and strict-balance-equality warnings. Timestamp comparisons deliberately enforce the observation lifetime. The explicit `_launching` guard covers the external calls and final event. Exact balance comparisons validate a freshly created token within its atomic creation transaction; a pre-existing donated ERC20 balance cannot perturb them. These warnings were reviewed against those conditions and the failure tests.
