// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PlaygroundLauncher} from "../src/PlaygroundLauncher.sol";

contract ConstructorDeployer {
    function deploy(address owner) external returns (PlaygroundLauncher) {
        return new PlaygroundLauncher(owner);
    }
}

contract PlaygroundPricingTest is Test {
    PlaygroundLauncher internal launcher;

    function setUp() public {
        vm.warp(1_000_000);
        launcher = new PlaygroundLauncher(address(this));
    }

    function test_constructorWorksWithoutDependenciesAndPreservesExplicitOwner() public {
        ConstructorDeployer deployingFactory = new ConstructorDeployer();
        PlaygroundLauncher deployed = deployingFactory.deploy(address(this));
        assertEq(deployed.owner(), address(this));
        assertNotEq(deployed.owner(), address(deployingFactory));
        assertEq(deployed.token(), address(0));
        assertEq(deployed.FACTORY().code.length, 0);
    }

    function test_constructorRejectsMissingOwnerAndProtocolOwners() public {
        address[9] memory owners = [
            address(0),
            launcher.FACTORY(),
            launcher.HOOK(),
            launcher.IMPLEMENTATION(),
            launcher.POOL_MANAGER(),
            launcher.POSITION_MANAGER(),
            launcher.PERMIT2(),
            launcher.IMD(),
            vm.computeCreateAddress(address(this), vm.getNonce(address(this)))
        ];
        for (uint256 i; i < owners.length; ++i) {
            vm.expectRevert(PlaygroundLauncher.InvalidOwner.selector);
            new PlaygroundLauncher(owners[i]);
        }
    }

    function test_unconfiguredPriceBlocksLaunchAndPreviewPrice() public {
        vm.expectRevert(PlaygroundLauncher.PriceNotConfigured.selector);
        launcher.startingPriceQuote();
        vm.expectRevert(PlaygroundLauncher.PriceNotConfigured.selector);
        launcher.launch();
    }

    function test_pricingExamplesAndRefresh() public {
        launcher.setImdUsdPrice(1 ether, uint64(block.timestamp));
        assertEq(launcher.startingPriceQuote(), 20_000_000_000_000); // IMD = $1
        launcher.setImdUsdPrice(0.25 ether, uint64(block.timestamp));
        assertEq(launcher.startingPriceQuote(), 80_000_000_000_000); // IMD = $0.25
        launcher.setImdUsdPrice(3 ether, uint64(block.timestamp));
        assertEq(launcher.startingPriceQuote(), 6_666_666_666_667); // upward rounding
        assertEq(launcher.imdUsdPriceWad(), 3 ether);
        assertEq(launcher.priceObservedAt(), block.timestamp);
    }

    function test_zeroAndUnrepresentablePricesRejectedWithoutChangingQuote() public {
        launcher.setImdUsdPrice(1 ether, uint64(block.timestamp));
        vm.expectRevert(PlaygroundLauncher.InvalidPrice.selector);
        launcher.setImdUsdPrice(0, uint64(block.timestamp));
        vm.expectRevert(PlaygroundLauncher.InvalidPrice.selector);
        launcher.setImdUsdPrice(2e31 + 1, uint64(block.timestamp));
        vm.expectRevert(PlaygroundLauncher.InvalidPrice.selector);
        launcher.quotePrice(type(uint256).max);
        assertEq(launcher.imdUsdPriceWad(), 1 ether);
    }

    function test_futureAndOldObservationsRejected() public {
        vm.expectRevert(PlaygroundLauncher.InvalidQuoteTime.selector);
        launcher.setImdUsdPrice(1 ether, uint64(block.timestamp + 1));
        vm.expectRevert(PlaygroundLauncher.StaleQuote.selector);
        launcher.setImdUsdPrice(1 ether, uint64(block.timestamp - 1 hours));
    }

    function test_quoteExpiryBoundaryAndRefresh() public {
        uint64 observedAt = uint64(vm.getBlockTimestamp());
        launcher.setImdUsdPrice(1 ether, observedAt);
        vm.warp(uint256(observedAt) + 1 hours - 1);
        assertEq(launcher.startingPriceQuote(), 20_000_000_000_000);
        vm.warp(uint256(observedAt) + 1 hours);
        vm.expectRevert(PlaygroundLauncher.StaleQuote.selector);
        launcher.launch();
        launcher.setImdUsdPrice(2 ether, uint64(vm.getBlockTimestamp()));
        assertEq(launcher.startingPriceQuote(), 10_000_000_000_000);
    }

    function test_quoteCannotBeUsedBeforeItsObservation() public {
        launcher.setImdUsdPrice(1 ether, uint64(block.timestamp));
        vm.warp(block.timestamp - 1);
        vm.expectRevert(PlaygroundLauncher.StaleQuote.selector);
        launcher.startingPriceQuote();
    }

    function testFuzz_ceilPriceNeverUndervaluesOrOverRounds(uint256 input) public view {
        uint256 p = bound(input, 1, 2e31);
        uint256 quote = launcher.quotePrice(p);
        assertGe(quote * p, 2e31);
        assertLt((quote - 1) * p, 2e31);
        assertLt(quote * p - 2e31, p);
    }

    function testFuzz_nonOwnerCannotConfigureOrLaunch(address caller) public {
        vm.assume(caller != address(this));
        vm.startPrank(caller);
        vm.expectRevert(PlaygroundLauncher.Unauthorized.selector);
        launcher.setImdUsdPrice(1 ether, uint64(block.timestamp));
        vm.expectRevert(PlaygroundLauncher.Unauthorized.selector);
        launcher.launch();
        vm.stopPrank();
    }

    function test_nonpayableFunctionsRejectEth() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(launcher).call{value: 1}(abi.encodeCall(launcher.launch, ()));
        assertFalse(ok);
        (ok,) = address(launcher).call{value: 1}("");
        assertFalse(ok);
        assertEq(address(launcher).balance, 0);
    }

    function test_runtimeFitsDeploymentFloorAndHasNoEscapeOpcodes() public view {
        bytes memory code = address(launcher).code;
        assertGt(code.length, 0);
        assertLe(code.length, 24_576);
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden opcode");
        }
    }
}
