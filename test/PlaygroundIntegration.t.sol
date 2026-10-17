// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ProtocolFixture} from "./helpers/ProtocolFixture.sol";
import {IERC20TToken} from "../src/interfaces/ILaunchDependencies.sol";
import {IERC20TFactory} from "../src/interfaces/IERC20TFactory.sol";
import {Vm} from "forge-std/Vm.sol";
import {IPositionNFT, ITokenExtras, ITestHook, PoolKey, PoolActor} from "./helpers/V4TestInterfaces.sol";

contract PlaygroundIntegrationTest is ProtocolFixture {
    function setUp() public {
        _setUpProtocol();
    }

    function test_realFactoryCreatesTokenAllocatesAndLocksLiquidity() public {
        uint256 positionId = IPositionNFT(launcher.POSITION_MANAGER()).nextTokenId();
        IERC20TToken pg = _launch();
        assertEq(pg.name(), "PLAYGROUND");
        assertEq(pg.symbol(), "PG");
        assertEq(pg.decimals(), 18);
        assertEq(pg.totalSupply(), 1_000_000_000 ether);
        assertEq(pg.balanceOf(launcher.BENEFICIARY()), 50_000_000 ether);
        assertEq(pg.balanceOf(address(launcher)), 0);
        assertEq(pg.balanceOf(launcher.FACTORY()), 0);
        assertEq(pg.owner(), address(this));
        assertTrue(pg.launched());
        assertEq(pg.hook(), launcher.HOOK());
        assertEq(pg.quoteToken(), launcher.IMD());
        assertEq(address(pg).code.length, 145);
        uint256 poolReserve = pg.balanceOf(launcher.POOL_MANAGER());
        uint256 lockedDust = pg.balanceOf(address(pg));
        assertEq(poolReserve + lockedDust, 950_000_000 ether);
        assertGt(poolReserve, 949_999_999 ether);
        assertEq(IPositionNFT(launcher.POSITION_MANAGER()).ownerOf(positionId), address(uint160(0xdead)));
        assertGt(IPositionNFT(launcher.POSITION_MANAGER()).getPositionLiquidity(positionId), 0);
        assertEq(ITokenExtras(address(pg)).allowance(address(pg), launcher.PERMIT2()), 0);
        PoolKey memory key = ITokenExtras(address(pg)).poolKey();
        assertEq(key.fee, 0);
        assertEq(key.tickSpacing, 60);
        assertEq(key.hooks, launcher.HOOK());
        assertEq(ITestHook(launcher.HOOK()).poolToken(keccak256(abi.encode(key))), address(pg));
    }

    function test_realTokenTaxIs250BpsWithNoDecay() public {
        IERC20TToken pg = _launch();
        assertEq(pg.taxBps(), 250);
        assertEq(pg.restingTaxBps(), 250);
        assertEq(pg.launchTaxBps(), 0);
        assertEq(pg.taxDecayIntervalSeconds(), 0);
        assertEq(pg.feeRecipient(), launcher.BENEFICIARY());
        assertEq(pg.feeDecayRecipient(), launcher.BENEFICIARY());
        assertFalse(ITokenExtras(address(pg)).taxDecayActive());
        vm.warp(block.timestamp + 365 days);
        assertEq(pg.taxBps(), 250);
    }

    function test_realBuyAndSellPayProtocolAndBeneficiary() public {
        PoolActor actor = _fundBasePool();
        IERC20TToken pg = _launch();
        PoolKey memory key = ITokenExtras(address(pg)).poolKey();
        bool buyZeroForOne = key.currency0 == launcher.IMD();
        uint256 beneficiaryBefore = launcher.BENEFICIARY().balance;
        uint256 protocolBefore = PROTOCOL_RECIPIENT.balance;
        vm.recordLogs();
        actor.swap(key, buyZeroForOne, -int256(100 ether));
        uint256 grossBought = _grossOutput(vm.getRecordedLogs(), key, address(actor));
        uint256 beneficiaryFee = launcher.BENEFICIARY().balance - beneficiaryBefore;
        uint256 protocolFee = PROTOCOL_RECIPIENT.balance - protocolBefore;
        assertGt(beneficiaryFee, 0);
        assertGt(protocolFee, 0);
        assertEq(protocolFee, (beneficiaryFee + protocolFee) * 15 / 250);
        uint256 bought = pg.balanceOf(address(actor));
        assertGt(bought, 0);
        assertEq(bought, grossBought - grossBought * 250 / 10_000);

        beneficiaryBefore = launcher.BENEFICIARY().balance;
        protocolBefore = PROTOCOL_RECIPIENT.balance;
        uint256 imdBefore = IERC20TToken(launcher.IMD()).balanceOf(address(actor));
        vm.recordLogs();
        actor.swap(key, !buyZeroForOne, -int256(bought / 2));
        uint256 grossSold = _grossOutput(vm.getRecordedLogs(), key, address(actor));
        assertEq(
            IERC20TToken(launcher.IMD()).balanceOf(address(actor)) - imdBefore,
            grossSold - grossSold * 250 / 10_000
        );
        beneficiaryFee = launcher.BENEFICIARY().balance - beneficiaryBefore;
        protocolFee = PROTOCOL_RECIPIENT.balance - protocolBefore;
        assertGt(beneficiaryFee, 0);
        assertGt(protocolFee, 0);
        assertEq(protocolFee, (beneficiaryFee + protocolFee) * 15 / 250);
    }

    function _grossOutput(Vm.Log[] memory logs, PoolKey memory key, address actor)
        private
        view
        returns (uint256)
    {
        bytes32 swapTopic = keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory entry = logs[i];
            if (
                entry.emitter == launcher.POOL_MANAGER() && entry.topics.length == 3
                    && entry.topics[0] == swapTopic && entry.topics[1] == keccak256(abi.encode(key))
                    && entry.topics[2] == bytes32(uint256(uint160(actor)))
            ) {
                (int128 amount0, int128 amount1,,,,) =
                    abi.decode(entry.data, (int128, int128, uint160, uint128, int24, uint24));
                return uint128(amount0 > 0 ? amount0 : amount1);
            }
        }
        revert("missing real v4 swap event");
    }

    function testFuzz_realLaunchConservesSupplyAcrossPricesAndAddressOrders(
        uint64 nonceSeed,
        uint256 priceSeed
    ) public {
        uint64 nonce = uint64(bound(nonceSeed, 2, 10_000));
        vm.setNonce(launcher.FACTORY(), nonce);
        uint256 imdUsdPrice = bound(priceSeed, 1e12, 1e24);
        launcher.setImdUsdPrice(imdUsdPrice, uint64(block.timestamp));
        address predicted = vm.computeCreateAddress(launcher.FACTORY(), nonce);
        IERC20TFactory.LaunchPreview memory p = launcher.preview(predicted < launcher.IMD());
        IERC20TToken pg = _launch();
        assertEq(address(pg), predicted);
        assertEq(pg.balanceOf(launcher.BENEFICIARY()), 50_000_000 ether);
        assertEq(pg.balanceOf(launcher.POOL_MANAGER()) + pg.balanceOf(address(pg)), 950_000_000 ether);
        assertEq(pg.totalSupply(), 1_000_000_000 ether);
        uint256 desired = launcher.startingPriceQuote();
        assertGe(p.effectivePriceWei, desired);
        assertLe(p.effectivePriceWei, desired * 100602 / 100000 + 1);
    }

    function test_actualLaunchWorksInBothAddressOrders() public {
        uint64 nonce = 2;
        while (vm.computeCreateAddress(launcher.FACTORY(), nonce) < launcher.IMD()) ++nonce;
        vm.setNonce(launcher.FACTORY(), nonce);
        IERC20TToken pg = _launch();
        assertGt(uint160(address(pg)), uint160(launcher.IMD()));
        assertEq(pg.balanceOf(launcher.BENEFICIARY()), 50_000_000 ether);
        assertEq(pg.balanceOf(launcher.POOL_MANAGER()) + pg.balanceOf(address(pg)), 950_000_000 ether);
    }

    function test_previewUsesBothCurrencyOrdersAndTargetsTwentyThousandDollars() public view {
        assertEq(launcher.startingPriceQuote(), 20_000_000_000_000);
        for (uint256 i; i < 2; ++i) {
            IERC20TFactory.LaunchPreview memory p = launcher.preview(i == 0);
            assertEq(p.creatorSupply, 50_000_000 ether);
            assertEq(p.lpSupply, 950_000_000 ether);
            assertGe(p.effectivePriceWei, 20_000_000_000_000);
            // One aligned tick (spacing 60) is less than a 0.602% increase.
            assertLt(p.effectivePriceWei, 20_000_000_000_000 * 100602 / 100000);
            assertEq(p.tickLower % 60, 0);
            assertEq(p.tickUpper % 60, 0);
            assertLt(p.tickLower, p.tickUpper);
        }
    }
}
