// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {stdStorage, StdStorage} from "forge-std/StdStorage.sol";
import {PlaygroundLauncher} from "../../src/PlaygroundLauncher.sol";
import {IERC20TToken} from "../../src/interfaces/ILaunchDependencies.sol";
import {FactoryBytecode} from "../fixtures/FactoryBytecode.sol";
import {ImplementationBytecode} from "../fixtures/ImplementationBytecode.sol";
import {HookBytecode} from "../fixtures/HookBytecode.sol";
import {PoolManagerBytecode} from "../fixtures/PoolManagerBytecode.sol";
import {PositionManagerBytecode} from "../fixtures/PositionManagerBytecode.sol";
import {Permit2Bytecode} from "../fixtures/Permit2Bytecode.sol";
import {ImdBytecode} from "../fixtures/ImdBytecode.sol";
import {IV4Manager, ITestHook, IPositionNFT, PoolKey, PoolActor} from "./V4TestInterfaces.sol";

abstract contract ProtocolFixture is
    Test,
    FactoryBytecode,
    ImplementationBytecode,
    HookBytecode,
    PoolManagerBytecode,
    PositionManagerBytecode,
    Permit2Bytecode,
    ImdBytecode
{
    using stdStorage for StdStorage;

    PlaygroundLauncher internal launcher;
    address internal constant PROTOCOL_RECIPIENT = 0x2ABD4B16a9663F4913F35A87A2C3078dF165bF12;
    bytes32 internal constant SOLADY_OWNER_SLOT =
        0xffffffffffffffffffffffffffffffffffffffffffffffffffffffff74873927;

    function _setUpProtocol() internal {
        vm.chainId(1);
        vm.warp(1_000_000);
        launcher = new PlaygroundLauncher(address(this));
        vm.etch(launcher.FACTORY(), _factoryCode());
        vm.etch(launcher.IMPLEMENTATION(), _implementationCode());
        vm.etch(launcher.HOOK(), _hookCode());
        vm.etch(launcher.POOL_MANAGER(), _poolManagerCode());
        vm.etch(launcher.POSITION_MANAGER(), _positionManagerCode());
        vm.etch(launcher.PERMIT2(), _permit2Code());
        vm.etch(launcher.IMD(), _imdCode());

        // Reconstruct just the local test world's administrative/metadata state, not live pool state.
        // Factory nonce 1 created the supplied implementation; clones start at nonce 2.
        vm.setNonce(launcher.FACTORY(), 2);
        vm.store(launcher.IMPLEMENTATION(), bytes32(0), bytes32(uint256(1)));
        stdstore.target(launcher.POSITION_MANAGER()).sig("nextTokenId()").checked_write(1);
        vm.store(launcher.HOOK(), SOLADY_OWNER_SLOT, bytes32(uint256(uint160(address(this)))));
        // IMD's owner-mutable string resides in storage; transfer logic remains the live bytecode.
        vm.mockCall(launcher.IMD(), abi.encodeWithSignature("symbol()"), abi.encode("IMD"));
        ITestHook(launcher.HOOK()).setProtocolFeeRecipient(PROTOCOL_RECIPIENT);
        PoolKey memory base = _basePool();
        IV4Manager(launcher.POOL_MANAGER()).initialize(base, uint160(1 << 96));
        ITestHook(launcher.HOOK()).registerExternalBase(launcher.IMD(), base);
        launcher.setImdUsdPrice(1 ether, uint64(block.timestamp));
    }

    function _basePool() internal view returns (PoolKey memory) {
        // Native ETH is currency zero; a plain local v4 pool supplies fee-conversion liquidity.
        return PoolKey(address(0), launcher.IMD(), 3000, 60, address(0));
    }

    function _fundBasePool() internal returns (PoolActor actor) {
        actor = new PoolActor(launcher.POOL_MANAGER());
        vm.deal(address(actor), 1_000_000 ether);
        deal(launcher.IMD(), address(actor), 1_000_000 ether);
        actor.addLiquidity(_basePool(), -887220, 887220, 100_000 ether);
    }

    function _launch() internal returns (IERC20TToken pg) {
        pg = IERC20TToken(launcher.launch());
    }
}
