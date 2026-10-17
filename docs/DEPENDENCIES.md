# Dependency evidence

Production code has no linked or imported third-party implementation libraries: it uses the minimal local interfaces and calls the requested deployed factory. All production library linking is absent. The factory subsequently creates its own ERC20T clone; the application itself is not a proxy.

## Sources and checks

- [ERC20TFactory verified source and ABI](https://eth.blockscout.com/address/0x801411c6acec4fa80c75c5d3c0eae13c84f8a173?tab=contract): `createAndLaunchAtPrice(Config,uint16,uint256)`, field ordering, 18-decimal supply, quote base units, allocation, single-sided liquidity and ownership handoff. A copy of its primary source is in `reference/ERC20TFactory.sol.txt`; its ABI is in `abi/ERC20TFactory.json`.
- [ERC20T verified source and ABI](https://eth.blockscout.com/address/0x2df7dcf4d19a7924e00ae96629cc1d1261670eee?tab=contract): fee bounds/decay configuration, LP lock/dust, transfer restrictions and administrative powers. Primary source and ABI are retained in the corresponding `reference/` and `abi/` files. The retained source files are review references, not incomplete build dependencies.
- [Official IMD token page](https://imd.fun/token/): the mainnet IMD address. On-chain calls confirmed `symbol() == "IMD"` and `decimals() == 18`.
- [Uniswap's Ethereum v4 deployments](https://developers.uniswap.org/docs/protocols/v4/deployments): PoolManager, PositionManager and Permit2. Live calls confirmed the PositionManager's PoolManager and Permit2 bindings.
- [Requested hook](https://eth.blockscout.com/address/0xed9a04fa6693e754661a22502524df9b1857e544): no verified source was available through Blockscout or Sourcify during implementation. Its runtime, public getters, real swap execution and exact fee payouts were checked; this is not a source audit of the hook.

At Ethereum block **26,208,919**, the factory's `implementation()` matched the requested implementation; the hook's `poolManager()` matched the canonical manager; `PROTOCOL_FEE_BPS()` returned 15; and `externalBases(IMD)` returned `(true,true)`. The hook's protocol recipient then was `0x2ABD4B16a9663F4913F35A87A2C3078dF165bF12`; the launcher intentionally leaves this protocol-owned setting under the existing hook's control.

The hook's actual IMD conversion pool at that block was `(ETH, IMD, fee=10000, tickSpacing=60, hooks=0xc6c965bd164c483e87d0b550671798e9a3602840)`. It is an external dependency administered by the hook, not a launcher parameter. Its fee and available liquidity affect fee conversion proceeds.

## Offline integration fixtures

`test/fixtures/*Bytecode.sol` contains `eth_getCode` results from that block. The address, byte count and Keccak-256 of each snapshot are listed in [dependency-snapshot.json](dependency-snapshot.json). These are EVM contract runtime fixtures, not a Solidity compiler binary or deployable application artifacts. The wrapper files do not relicense embedded third-party runtime code.

`ProtocolFixture` installs that code with Foundry cheatcodes into an isolated local EVM. It reconstructs a fresh test world: factory nonce 2 (nonce 1 created the implementation), initialization-locked implementation, PositionManager counter 1, test-controlled hook administration, and a registered test ETH/IMD pool. Only IMD's storage-dependent symbol getter is mocked to `IMD`; transfers execute its actual runtime. Test balances are funded through cheatcodes. The local conversion pool has a 3000 fee and no hook, so its state and fee differ from the live conversion pool. The actual PG hook, factory, ERC20T, Permit2, PoolManager and PositionManager execute their real code throughout the successful launch/trade tests.

Failure tests deliberately mock individual dependency calls or replace code to exercise fail-closed and rollback behavior. These changes occur only inside isolated tests.

A separate, disposable mainnet-fork smoke test at block 26,208,919 passed token creation, supply split, ownership, a buy and a sell using the live conversion pool and hook state. It used a simulation-only $1 IMD input and artificial trader funding. It broadcast nothing. This extra check is not required by, or included in, the network-free submitted suite.

## Vendored test library

`lib/forge-std` contains the `src/` tree and licenses from [forge-std v1.9.7](https://github.com/foundry-rs/forge-std/tree/v1.9.7), fetched from the tagged GitHub archive. `LICENSE-APACHE` and `LICENSE-MIT` are included. There are no submodules, nested git repositories or package-manager installation requirements. Test binaries/artifacts are rebuilt locally from ordinary submitted files.
