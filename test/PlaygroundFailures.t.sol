// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ProtocolFixture} from "./helpers/ProtocolFixture.sol";
import {PlaygroundLauncher} from "../src/PlaygroundLauncher.sol";
import {IERC20TFactory} from "../src/interfaces/IERC20TFactory.sol";
import {IERC20TToken, IERC20THook, IPositionManager} from "../src/interfaces/ILaunchDependencies.sol";
import {IPositionNFT, ITestHook, ITokenExtras} from "./helpers/V4TestInterfaces.sol";

interface IReentryOwner {
    function attemptReentry() external;
}

contract ReenteringFactory {
    error ReentryChecksPassed();

    function implementation() external pure returns (address) {
        return 0x2df7DCf4D19a7924e00AE96629CC1d1261670eEe;
    }

    function createAndLaunchAtPrice(IERC20TFactory.Config calldata, uint16, uint256)
        external
        payable
        returns (address)
    {
        IReentryOwner(PlaygroundLauncher(msg.sender).owner()).attemptReentry();
        revert ReentryChecksPassed();
    }
}

contract PlaygroundFailuresTest is ProtocolFixture {
    function setUp() public {
        _setUpProtocol();
    }

    function _clearMocks() internal {
        vm.clearMockedCalls();
        vm.mockCall(launcher.IMD(), abi.encodeWithSignature("symbol()"), abi.encode("IMD"));
    }

    function test_wrongChainCannotLaunch() public {
        vm.chainId(11155111);
        vm.expectRevert(PlaygroundLauncher.WrongChain.selector);
        launcher.launch();
        assertEq(launcher.token(), address(0));
    }

    function testFuzz_missingDependencyFailsAndCanBeRepaired(uint8 index) public {
        address[7] memory dependencies = [
            launcher.FACTORY(),
            launcher.IMPLEMENTATION(),
            launcher.HOOK(),
            launcher.IMD(),
            launcher.POOL_MANAGER(),
            launcher.POSITION_MANAGER(),
            launcher.PERMIT2()
        ];
        address dependency = dependencies[bound(index, 0, 6)];
        bytes memory originalCode = dependency.code;
        vm.etch(dependency, "");
        vm.expectRevert(abi.encodeWithSelector(PlaygroundLauncher.MissingDependency.selector, dependency));
        launcher.launch();
        assertEq(launcher.token(), address(0));
        vm.etch(dependency, originalCode);
        assertTrue(_launch().launched());
    }

    function test_wrongImplementationRejected() public {
        vm.mockCall(
            launcher.FACTORY(), abi.encodeCall(IERC20TFactory.implementation, ()), abi.encode(address(this))
        );
        vm.expectRevert(PlaygroundLauncher.IncompatibleDependencies.selector);
        launcher.launch();
    }

    function test_protocolFeeCannotBeAddedOnTopOrSilentlyChanged() public {
        vm.mockCall(launcher.HOOK(), abi.encodeCall(IERC20THook.PROTOCOL_FEE_BPS, ()), abi.encode(uint16(30)));
        vm.expectRevert(PlaygroundLauncher.IncompatibleDependencies.selector);
        launcher.launch();
    }

    function test_wrongPoolManagerRejected() public {
        vm.mockCall(launcher.HOOK(), abi.encodeCall(IERC20THook.poolManager, ()), abi.encode(address(this)));
        vm.expectRevert(PlaygroundLauncher.IncompatibleDependencies.selector);
        launcher.launch();
    }

    function test_positionManagerMustMatchPoolManagerAndPermit2() public {
        vm.mockCall(
            launcher.POSITION_MANAGER(),
            abi.encodeCall(IPositionManager.poolManager, ()),
            abi.encode(address(this))
        );
        vm.expectRevert(PlaygroundLauncher.IncompatibleDependencies.selector);
        launcher.launch();
        _clearMocks();
        vm.mockCall(
            launcher.POSITION_MANAGER(),
            abi.encodeCall(IPositionManager.permit2, ()),
            abi.encode(address(this))
        );
        vm.expectRevert(PlaygroundLauncher.IncompatibleDependencies.selector);
        launcher.launch();
    }

    function test_wrongImdMetadataRejected() public {
        vm.mockCall(launcher.IMD(), abi.encodeCall(IERC20TToken.decimals, ()), abi.encode(uint8(6)));
        vm.expectRevert(PlaygroundLauncher.IncompatibleDependencies.selector);
        launcher.launch();
        _clearMocks();
        vm.mockCall(launcher.IMD(), abi.encodeCall(IERC20TToken.symbol, ()), abi.encode("OTHER"));
        vm.expectRevert(PlaygroundLauncher.IncompatibleDependencies.selector);
        launcher.launch();
    }

    function test_hookCanDisableNewImdPairsAndRetryWorksAfterEnable() public {
        ITestHook(launcher.HOOK()).setExternalBaseEnabled(launcher.IMD(), false);
        vm.expectRevert(PlaygroundLauncher.ImdPairingUnavailable.selector);
        launcher.launch();
        ITestHook(launcher.HOOK()).setExternalBaseEnabled(launcher.IMD(), true);
        assertTrue(_launch().launched());
    }

    function test_unregisteredImdFails() public {
        vm.mockCall(
            launcher.HOOK(),
            abi.encodeCall(IERC20THook.externalBases, (launcher.IMD())),
            abi.encode(false, true)
        );
        vm.expectRevert(PlaygroundLauncher.ImdPairingUnavailable.selector);
        launcher.launch();
    }

    function test_factoryFailureDoesNotConsumeLaunch() public {
        bytes memory failure = abi.encodeWithSignature("FactoryUnavailable()");
        vm.mockCallRevert(launcher.FACTORY(), IERC20TFactory.createAndLaunchAtPrice.selector, failure);
        vm.expectRevert(failure);
        launcher.launch();
        assertEq(launcher.token(), address(0));
        _clearMocks();
        assertTrue(_launch().launched());
    }

    function test_badFactoryResultRejectedAndRetryWorks() public {
        vm.mockCall(
            launcher.FACTORY(),
            IERC20TFactory.createAndLaunchAtPrice.selector,
            abi.encode(makeAddr("no-token-code"))
        );
        vm.expectRevert(PlaygroundLauncher.UnexpectedLaunchResult.selector);
        launcher.launch();
        _clearMocks();
        assertTrue(_launch().launched());
    }

    function test_failedDistributionRollsBackClonePoolAndOwnership() public {
        address predicted = vm.computeCreateAddress(launcher.FACTORY(), vm.getNonce(launcher.FACTORY()));
        uint256 nextId = IPositionNFT(launcher.POSITION_MANAGER()).nextTokenId();
        vm.mockCall(
            launcher.IMPLEMENTATION(),
            abi.encodeCall(IERC20TToken.transfer, (launcher.BENEFICIARY(), 50_000_000 ether)),
            abi.encode(false)
        );
        vm.expectRevert(PlaygroundLauncher.AllocationTransferFailed.selector);
        launcher.launch();
        assertEq(launcher.token(), address(0));
        assertEq(predicted.code.length, 0);
        assertEq(IPositionNFT(launcher.POSITION_MANAGER()).nextTokenId(), nextId);
        _clearMocks();
        assertEq(address(_launch()), predicted);
    }

    function test_noOpTransferCannotReportSuccessfulDistribution() public {
        address predicted = vm.computeCreateAddress(launcher.FACTORY(), vm.getNonce(launcher.FACTORY()));
        vm.mockCall(
            launcher.IMPLEMENTATION(),
            abi.encodeCall(IERC20TToken.transfer, (launcher.BENEFICIARY(), 50_000_000 ether)),
            abi.encode(true)
        );
        vm.expectRevert(PlaygroundLauncher.UnexpectedLaunchResult.selector);
        launcher.launch();
        assertEq(predicted.code.length, 0);
        assertEq(launcher.token(), address(0));
    }

    function test_failedOwnershipHandoffRollsBackEntireLaunch() public {
        address predicted = vm.computeCreateAddress(launcher.FACTORY(), vm.getNonce(launcher.FACTORY()));
        vm.mockCall(
            launcher.IMPLEMENTATION(),
            abi.encodeCall(IERC20TToken.transferOwnership, (address(this))),
            bytes("")
        );
        vm.expectRevert(PlaygroundLauncher.UnexpectedLaunchResult.selector);
        launcher.launch();
        assertEq(predicted.code.length, 0);
        assertEq(launcher.token(), address(0));
        _clearMocks();
        assertEq(_launch().owner(), address(this));
    }

    function test_dependencyCallbacksCannotReenterLaunchOrChangePrice() public {
        ReenteringFactory adversary = new ReenteringFactory();
        vm.etch(launcher.FACTORY(), address(adversary).code);
        vm.expectRevert(ReenteringFactory.ReentryChecksPassed.selector);
        launcher.launch();
        assertEq(launcher.token(), address(0));
        assertEq(launcher.imdUsdPriceWad(), 1 ether);
        vm.etch(launcher.FACTORY(), _factoryCode());
        assertTrue(_launch().launched());
    }

    function attemptReentry() external {
        assertEq(msg.sender, launcher.FACTORY());
        (bool ok, bytes memory reason) = address(launcher).call(abi.encodeCall(launcher.launch, ()));
        assertFalse(ok);
        assertEq(reason, abi.encodeWithSelector(PlaygroundLauncher.LaunchInProgress.selector));
        (ok, reason) = address(launcher)
            .call(abi.encodeCall(launcher.setImdUsdPrice, (2 ether, uint64(block.timestamp))));
        assertFalse(ok);
        assertEq(reason, abi.encodeWithSelector(PlaygroundLauncher.LaunchInProgress.selector));
    }

    function test_onlyOneLaunchAndNoReconfigurationAfterSuccess() public {
        address created = address(_launch());
        vm.expectRevert(PlaygroundLauncher.AlreadyLaunched.selector);
        launcher.launch();
        vm.expectRevert(PlaygroundLauncher.AlreadyLaunched.selector);
        launcher.setImdUsdPrice(2 ether, uint64(block.timestamp));
        assertEq(launcher.token(), created);
    }

    function test_tokenAdministrationGoesToOwnerNotFactoryOrLauncher() public {
        IERC20TToken pg = _launch();
        vm.prank(address(launcher));
        vm.expectRevert();
        ITokenExtras(address(pg)).setTaxBps(300);
        vm.prank(launcher.FACTORY());
        vm.expectRevert();
        ITokenExtras(address(pg)).setTaxBps(300);
        // This inherited ERC20T power is intentional and documented: launch tax is not immutable.
        ITokenExtras(address(pg)).setTaxBps(300);
        assertEq(pg.taxBps(), 300);
    }

    function test_ownerCannotWithdrawOrTransferLockedLpNft() public {
        uint256 positionId = IPositionNFT(launcher.POSITION_MANAGER()).nextTokenId();
        _launch();
        IPositionNFT positions = IPositionNFT(launcher.POSITION_MANAGER());
        vm.expectRevert();
        positions.transferFrom(address(uint160(0xdead)), address(this), positionId);
        bytes[] memory params = new bytes[](1);
        params[0] = abi.encode(positionId, uint128(0), uint128(0), bytes(""));
        vm.expectRevert();
        positions.modifyLiquidities(abi.encode(hex"03", params), block.timestamp);
    }
}
