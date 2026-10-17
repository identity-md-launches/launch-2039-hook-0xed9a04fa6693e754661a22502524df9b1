// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ProtocolFixture} from "./helpers/ProtocolFixture.sol";
import {PlaygroundLauncher} from "src/PlaygroundLauncher.sol";
import {IERC20TFactory} from "src/interfaces/IERC20TFactory.sol";
import {IERC20TToken} from "src/interfaces/ILaunchDependencies.sol";

/// @dev The handler is the explicit owner. Every action is a complete transaction, including launch.
contract PlaygroundLifecycleHandler is Test {
    PlaygroundLauncher public immutable launcher;
    uint256 public expectedPrice;
    uint64 public expectedObservedAt;
    address public expectedToken;
    uint256 public successfulLaunches;
    uint256 public successfulQuotes;
    uint256 public rejectedCalls;

    constructor() {
        launcher = new PlaygroundLauncher(address(this));
    }

    function configure(uint256 priceSeed, uint256 ageSeed) external {
        uint256 price = bound(priceSeed, 1e12, 1e24);
        uint64 observedAt = uint64(block.timestamp - bound(ageSeed, 0, 3599));
        if (expectedToken != address(0)) {
            vm.expectRevert(PlaygroundLauncher.AlreadyLaunched.selector);
            launcher.setImdUsdPrice(price, observedAt);
            ++rejectedCalls;
        } else {
            launcher.setImdUsdPrice(price, observedAt);
            expectedPrice = price;
            expectedObservedAt = observedAt;
            ++successfulQuotes;
        }
    }

    function advanceTime(uint256 secondsSeed) external {
        vm.warp(block.timestamp + bound(secondsSeed, 0, 2 hours));
    }

    function launch() external {
        bytes4 errorSelector;
        if (expectedToken != address(0)) {
            errorSelector = PlaygroundLauncher.AlreadyLaunched.selector;
        } else if (expectedPrice == 0) {
            errorSelector = PlaygroundLauncher.PriceNotConfigured.selector;
        } else if (block.timestamp - expectedObservedAt >= 1 hours) {
            errorSelector = PlaygroundLauncher.StaleQuote.selector;
        }

        if (errorSelector != bytes4(0)) {
            vm.expectRevert(errorSelector);
            launcher.launch();
            ++rejectedCalls;
        } else {
            expectedToken = launcher.launch();
            ++successfulLaunches;
        }
    }

    function invalidQuote(uint256 choiceSeed) external {
        uint256 choice = bound(choiceSeed, 0, 3);
        uint256 price = choice == 0 ? 0 : choice == 1 ? type(uint256).max : 1 ether;
        uint64 observedAt = uint64(choice == 2 ? block.timestamp + 1 : block.timestamp - 1 hours);
        bytes4 expectedError = expectedToken != address(0)
            ? PlaygroundLauncher.AlreadyLaunched.selector
            : choice < 2
                ? PlaygroundLauncher.InvalidPrice.selector
                : choice == 2
                    ? PlaygroundLauncher.InvalidQuoteTime.selector
                    : PlaygroundLauncher.StaleQuote.selector;
        vm.expectRevert(expectedError);
        launcher.setImdUsdPrice(price, observedAt);
        ++rejectedCalls;
    }

    function unauthorizedCalls(uint256 callerSeed, uint256 priceSeed) external {
        // The caller set is deliberately disjoint from the owner and all protocol contracts.
        address caller = address(uint160(bound(callerSeed, 0x10000, 0x1ffff)));
        vm.startPrank(caller, caller);
        vm.expectRevert(PlaygroundLauncher.Unauthorized.selector);
        launcher.setImdUsdPrice(priceSeed, uint64(block.timestamp));
        vm.expectRevert(PlaygroundLauncher.Unauthorized.selector);
        launcher.launch();
        vm.stopPrank();
        rejectedCalls += 2;
    }

    function preview(bool tokenIsCurrency0) external {
        if (expectedPrice == 0) {
            vm.expectRevert(PlaygroundLauncher.PriceNotConfigured.selector);
            launcher.preview(tokenIsCurrency0);
        } else if (block.timestamp - expectedObservedAt >= 1 hours) {
            vm.expectRevert(PlaygroundLauncher.StaleQuote.selector);
            launcher.preview(tokenIsCurrency0);
        } else {
            IERC20TFactory.LaunchPreview memory p = launcher.preview(tokenIsCurrency0);
            assertEq(p.creatorSupply, 50_000_000 ether);
            assertEq(p.lpSupply, 950_000_000 ether);
            // The tick grid may round the opening valuation up, but never below the target.
            uint256 desired = launcher.startingPriceQuote();
            assertGe(p.effectivePriceWei, desired);
            assertLe(p.effectivePriceWei, desired * 100602 / 100000 + 1);
        }
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract PlaygroundLifecycleInvariantTest is ProtocolFixture {
    PlaygroundLifecycleHandler internal handler;
    uint64 internal initialFactoryNonce;

    function setUp() public {
        _setUpProtocol();
        handler = new PlaygroundLifecycleHandler();
        launcher = handler.launcher();
        initialFactoryNonce = vm.getNonce(launcher.FACTORY());
        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = handler.configure.selector;
        selectors[1] = handler.advanceTime.selector;
        selectors[2] = handler.launch.selector;
        selectors[3] = handler.invalidQuote.selector;
        selectors[4] = handler.unauthorizedCalls.selector;
        selectors[5] = handler.preview.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    function invariant_onlySuccessfulOwnerCallsChangeLauncherState() public view {
        assertEq(launcher.owner(), address(handler));
        assertEq(launcher.imdUsdPriceWad(), handler.expectedPrice());
        assertEq(launcher.priceObservedAt(), handler.expectedObservedAt());
        assertEq(launcher.token(), handler.expectedToken());
        assertLe(handler.successfulLaunches(), 1);
        assertEq(vm.getNonce(launcher.FACTORY()), initialFactoryNonce + handler.successfulLaunches());
    }

    function invariant_completedLaunchKeepsItsAllocationAndOwner() public view {
        address created = handler.expectedToken();
        if (created == address(0)) {
            assertEq(handler.successfulLaunches(), 0);
            return;
        }
        IERC20TToken pg = IERC20TToken(created);
        assertEq(handler.successfulLaunches(), 1);
        assertTrue(pg.launched());
        assertEq(pg.owner(), address(handler));
        assertEq(pg.totalSupply(), 1_000_000_000 ether);
        assertEq(pg.balanceOf(launcher.BENEFICIARY()), 50_000_000 ether);
        assertEq(pg.balanceOf(launcher.POOL_MANAGER()) + pg.balanceOf(created), 950_000_000 ether);
        assertEq(pg.balanceOf(address(launcher)), 0);
        assertEq(pg.balanceOf(launcher.FACTORY()), 0);
        assertEq(pg.taxBps(), 250);
        assertEq(pg.launchTaxBps(), 0);
        assertEq(pg.feeRecipient(), launcher.BENEFICIARY());
    }

    function test_lifecycleHandlerReachesExpiryRetryAndTerminalState() public {
        handler.launch();
        handler.invalidQuote(0);
        handler.configure(1 ether, 0);
        handler.advanceTime(3600);
        handler.launch();
        handler.configure(2 ether, 0);
        handler.preview(true);
        handler.preview(false);
        handler.launch();
        handler.configure(3 ether, 0);
        handler.launch();
        handler.invalidQuote(2);
        handler.unauthorizedCalls(0x12345, 1 ether);
        assertEq(handler.successfulLaunches(), 1);
        assertEq(handler.successfulQuotes(), 2);
        assertEq(handler.rejectedCalls(), 8);
        invariant_onlySuccessfulOwnerCallsChangeLauncherState();
        invariant_completedLaunchKeepsItsAllocationAndOwner();
    }
}
