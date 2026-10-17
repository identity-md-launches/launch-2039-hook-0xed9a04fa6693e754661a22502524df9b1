// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ProtocolFixture} from "./helpers/ProtocolFixture.sol";
import {PlaygroundTradingHandler} from "./helpers/PlaygroundTradingHandler.sol";
import {IERC20TToken} from "src/interfaces/ILaunchDependencies.sol";
import {PoolActor, IPositionNFT, ITokenExtras} from "./helpers/V4TestInterfaces.sol";

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract PlaygroundTradingInvariantTest is ProtocolFixture {
    PlaygroundTradingHandler internal handler;
    IERC20TToken internal pg;
    address[] internal accounts;
    uint256 internal initialImd;
    uint256 internal initialEth;
    uint256 internal initialBeneficiaryEth;
    uint256 internal initialProtocolEth;
    uint256 internal positionId;
    uint128 internal positionLiquidity;
    address internal positionOwner;
    uint256 internal lockedDust;

    function setUp() public {
        _setUpProtocol();
        _chooseTokenOrdering();
        PoolActor baseLiquidityProvider = _fundBasePool();
        positionId = IPositionNFT(launcher.POSITION_MANAGER()).nextTokenId();
        pg = _launch();
        positionLiquidity = IPositionNFT(launcher.POSITION_MANAGER()).getPositionLiquidity(positionId);
        positionOwner = IPositionNFT(launcher.POSITION_MANAGER()).ownerOf(positionId);
        lockedDust = pg.balanceOf(address(pg));
        handler = new PlaygroundTradingHandler(launcher, PROTOCOL_RECIPIENT);

        accounts.push(launcher.POOL_MANAGER());
        accounts.push(launcher.HOOK());
        accounts.push(address(pg));
        accounts.push(address(launcher));
        accounts.push(launcher.FACTORY());
        accounts.push(launcher.POSITION_MANAGER());
        accounts.push(launcher.PERMIT2());
        accounts.push(address(baseLiquidityProvider));
        accounts.push(PROTOCOL_RECIPIENT);
        for (uint256 i; i < 4; ++i) {
            accounts.push(handler.wallets(i));
        }
        for (uint256 i; i < 3; ++i) {
            address trader = address(handler.traders(i));
            deal(launcher.IMD(), trader, 10_000 ether);
            accounts.push(trader);
        }
        initialImd = _sumTokens(IERC20TToken(launcher.IMD()));
        initialEth = _sumEth();
        initialBeneficiaryEth = launcher.BENEFICIARY().balance;
        initialProtocolEth = PROTOCOL_RECIPIENT.balance;

        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = handler.buy.selector;
        selectors[1] = handler.sell.selector;
        selectors[2] = handler.buyThenSell.selector;
        selectors[3] = handler.transferWallet.selector;
        selectors[4] = handler.burn.selector;
        selectors[5] = handler.overspend.selector;
        selectors[6] = handler.unauthorizedAdministration.selector;
        selectors[7] = handler.advanceTime.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    function invariant_allPgIsAccountedForAndOnlyExplicitBurnsReduceSupply() public view {
        assertEq(pg.totalSupply() + handler.burned(), 1_000_000_000 ether);
        assertEq(_sumTokens(pg), pg.totalSupply());
        for (uint256 i; i < 4; ++i) {
            address wallet = handler.wallets(i);
            assertEq(pg.balanceOf(wallet), handler.expectedPg(wallet));
        }
        for (uint256 i; i < 3; ++i) {
            address trader = address(handler.traders(i));
            assertEq(pg.balanceOf(trader), handler.expectedPg(trader));
        }
    }

    function invariant_quoteAndNativeValueAreConserved() public view {
        assertEq(_sumTokens(IERC20TToken(launcher.IMD())), initialImd, "IMD lost or created");
        assertEq(_sumEth(), initialEth, "native value lost or created");
        assertEq(launcher.BENEFICIARY().balance, initialBeneficiaryEth + handler.beneficiaryFees());
        assertEq(PROTOCOL_RECIPIENT.balance, initialProtocolEth + handler.protocolFees());
    }

    function invariant_liquidityRemainsLockedAndCustodyIsReleased() public view {
        IPositionNFT positions = IPositionNFT(launcher.POSITION_MANAGER());
        assertEq(positions.ownerOf(positionId), positionOwner);
        assertEq(positions.getPositionLiquidity(positionId), positionLiquidity);
        assertEq(positions.nextTokenId(), positionId + 1);
        assertEq(pg.balanceOf(address(pg)), lockedDust);
        assertEq(pg.balanceOf(address(launcher)), 0);
        assertEq(pg.balanceOf(launcher.FACTORY()), 0);
        assertEq(pg.balanceOf(launcher.HOOK()), 0);
        assertEq(ITokenExtras(address(pg)).allowance(address(pg), launcher.PERMIT2()), 0);
    }

    function invariant_publicActivityCannotChangeLaunchTerms() public view {
        assertEq(launcher.token(), address(pg));
        assertTrue(pg.launched());
        assertEq(pg.owner(), address(this));
        assertEq(pg.taxBps(), 250);
        assertEq(pg.restingTaxBps(), 250);
        assertEq(pg.launchTaxBps(), 0);
        assertEq(pg.taxDecayIntervalSeconds(), 0);
        assertFalse(ITokenExtras(address(pg)).taxDecayActive());
        assertEq(pg.feeRecipient(), launcher.BENEFICIARY());
        assertEq(pg.feeDecayRecipient(), launcher.BENEFICIARY());
    }

    function test_handlersExerciseTradesTransfersBurnsAndFailures() public {
        handler.buy(0, 100 ether);
        handler.buy(1, 25 ether);
        handler.sell(0, type(uint256).max);
        handler.buyThenSell(2, 20 ether);
        handler.transferWallet(0, 1, 1_000 ether);
        handler.transferWallet(1, 1, 1);
        handler.transferWallet(1, 2, 0);
        handler.burn(1, 500 ether);
        handler.burn(5, 1);
        handler.overspend(1, type(uint256).max);
        handler.unauthorizedAdministration(0, 500);
        handler.advanceTime(7 days);
        assertGt(handler.buys(), 0);
        assertGt(handler.sells(), 0);
        assertGt(handler.beneficiaryFees(), 0);
        assertGt(handler.protocolFees(), 0);
        assertEq(handler.roundTrips(), 1);
        assertEq(handler.transfers(), 3);
        assertEq(handler.burned(), 500 ether + 1);
        assertEq(handler.rejectedCalls(), 7);
        invariant_allPgIsAccountedForAndOnlyExplicitBurnsReduceSupply();
        invariant_quoteAndNativeValueAreConserved();
        invariant_liquidityRemainsLockedAndCustodyIsReleased();
        invariant_publicActivityCannotChangeLaunchTerms();
    }

    function test_oneWeiTradesAndFullWalletBalanceEdges() public {
        handler.buyThenSell(0, 1);
        handler.buy(1, 1);
        handler.sell(1, type(uint256).max);
        handler.transferWallet(0, 1, 50_000_000 ether);
        handler.transferWallet(1, 2, 1);
        handler.transferWallet(2, 2, 1);
        handler.burn(2, 1);
        handler.burn(1, type(uint256).max);
        handler.burn(0, 0);
        handler.overspend(0, 1);
        assertEq(handler.burned(), 50_000_000 ether);
        invariant_allPgIsAccountedForAndOnlyExplicitBurnsReduceSupply();
        invariant_quoteAndNativeValueAreConserved();
        invariant_liquidityRemainsLockedAndCustodyIsReleased();
        invariant_publicActivityCannotChangeLaunchTerms();
    }

    function _chooseTokenOrdering() internal virtual {
        assertLt(
            uint160(vm.computeCreateAddress(launcher.FACTORY(), vm.getNonce(launcher.FACTORY()))),
            uint160(launcher.IMD())
        );
    }

    function _sumTokens(IERC20TToken token) internal view returns (uint256 total) {
        for (uint256 i; i < accounts.length; ++i) {
            total += token.balanceOf(accounts[i]);
        }
    }

    function _sumEth() internal view returns (uint256 total) {
        for (uint256 i; i < accounts.length; ++i) {
            total += accounts[i].balance;
        }
    }
}

/// @dev The same accounting campaign also runs with PG as currency1. Only the shared factory's
///      starting nonce changes; liquidity, hook settlement, and taxes execute the actual bytecode.
/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract PlaygroundTradingReverseOrderInvariantTest is PlaygroundTradingInvariantTest {
    function _chooseTokenOrdering() internal override {
        uint64 nonce = 2;
        while (vm.computeCreateAddress(launcher.FACTORY(), nonce) < launcher.IMD()) ++nonce;
        vm.setNonce(launcher.FACTORY(), nonce);
        assertGt(uint160(vm.computeCreateAddress(launcher.FACTORY(), nonce)), uint160(launcher.IMD()));
    }
}
