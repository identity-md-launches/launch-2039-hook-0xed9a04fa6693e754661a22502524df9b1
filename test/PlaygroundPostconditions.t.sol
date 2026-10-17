// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ProtocolFixture} from "./helpers/ProtocolFixture.sol";
import {PlaygroundLauncher} from "src/PlaygroundLauncher.sol";
import {IERC20TFactory} from "src/interfaces/IERC20TFactory.sol";
import {IERC20TToken} from "src/interfaces/ILaunchDependencies.sol";

/// @dev A deliberately malformed factory return value, used only to exercise the launcher's guards.
///      Positive launch tests use the real bundled factory/implementation bytecode instead.
contract MalformedLaunchResult {
    bool public launched = true;
    address public owner;
    uint256 public totalSupply = 1_000_000_000 ether;
    mapping(address => uint256) public balanceOf;
    address public hook;
    address public quoteToken;
    address public poolManager;
    address public positionManager;
    address public permit2;
    uint16 public taxBps = 250;
    uint16 public restingTaxBps = 250;
    uint16 public launchTaxBps;
    uint32 public taxDecayIntervalSeconds;
    address public feeRecipient;
    address public feeDecayRecipient;
    uint8 public decimals = 18;
    string public name = "PLAYGROUND";
    string public symbol = "PG";

    constructor(PlaygroundLauncher launcher, uint256 defect) {
        owner = address(launcher);
        hook = launcher.HOOK();
        quoteToken = launcher.IMD();
        poolManager = launcher.POOL_MANAGER();
        positionManager = launcher.POSITION_MANAGER();
        permit2 = launcher.PERMIT2();
        feeRecipient = launcher.BENEFICIARY();
        feeDecayRecipient = launcher.BENEFICIARY();
        balanceOf[address(launcher)] = 50_000_000 ether;
        balanceOf[poolManager] = 950_000_000 ether;
        if (defect == 0) launched = false;
        else if (defect == 1) owner = msg.sender;
        else if (defect == 2) ++totalSupply;
        else if (defect == 3) --balanceOf[address(launcher)];
        else if (defect == 4) hook = msg.sender;
        else if (defect == 5) quoteToken = msg.sender;
        else if (defect == 6) --balanceOf[poolManager];
        else if (defect == 7) poolManager = msg.sender;
        else if (defect == 8) positionManager = msg.sender;
        else if (defect == 9) permit2 = msg.sender;
        else if (defect == 10) taxBps = 265;
        else if (defect == 11) restingTaxBps = 235;
        else if (defect == 12) launchTaxBps = 9900;
        else if (defect == 13) taxDecayIntervalSeconds = 1;
        else if (defect == 14) feeRecipient = msg.sender;
        else if (defect == 15) feeDecayRecipient = msg.sender;
        else if (defect == 16) decimals = 6;
        else if (defect == 17) name = "OTHER";
        else if (defect == 18) symbol = "OTHER";
        else revert("unknown fixture defect");
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferOwnership(address newOwner) external payable {
        require(msg.sender == owner, "stub owner only");
        owner = newOwner;
    }
}

contract PlaygroundPostconditionsTest is ProtocolFixture {
    function setUp() public {
        _setUpProtocol();
    }

    function test_everyMalformedFactoryResultFailsBeforeDistributionAndCanRetry() public {
        address predicted = vm.computeCreateAddress(launcher.FACTORY(), vm.getNonce(launcher.FACTORY()));
        // Enumerate rather than randomly sample: each launch postcondition is exercised on every run.
        for (uint256 defect; defect < 19; ++defect) {
            MalformedLaunchResult result = new MalformedLaunchResult(launcher, defect);
            vm.mockCall(
                launcher.FACTORY(),
                IERC20TFactory.createAndLaunchAtPrice.selector,
                abi.encode(address(result))
            );
            vm.expectRevert(PlaygroundLauncher.UnexpectedLaunchResult.selector);
            launcher.launch();
            assertEq(launcher.token(), address(0));
            assertEq(launcher.imdUsdPriceWad(), 1 ether);
            assertEq(result.balanceOf(launcher.BENEFICIARY()), 0, "invalid token was distributed");
            assertEq(predicted.code.length, 0);
        }
        vm.clearMockedCalls();
        vm.mockCall(launcher.IMD(), abi.encodeCall(IERC20TToken.symbol, ()), abi.encode("IMD"));
        assertEq(address(_launch()), predicted);
    }

    function test_eoaOwnerCanLaunchWithoutReceivingTheBeneficiaryAllocation() public {
        address explicitOwner = makeAddr("explicit PG owner");
        launcher = new PlaygroundLauncher(explicitOwner);
        vm.startPrank(explicitOwner, explicitOwner);
        launcher.setImdUsdPrice(1 ether, uint64(block.timestamp));
        IERC20TToken pg = IERC20TToken(launcher.launch());
        vm.stopPrank();
        assertEq(pg.owner(), explicitOwner);
        assertEq(pg.balanceOf(explicitOwner), 0);
        assertEq(pg.balanceOf(launcher.BENEFICIARY()), 50_000_000 ether);
        assertEq(pg.balanceOf(address(this)), 0);
        assertEq(pg.balanceOf(address(launcher)), 0);
    }

    function test_beneficiaryMayAlsoBeTheExplicitOwner() public {
        address beneficiary = launcher.BENEFICIARY();
        launcher = new PlaygroundLauncher(beneficiary);
        vm.startPrank(beneficiary, beneficiary);
        launcher.setImdUsdPrice(1 ether, uint64(block.timestamp));
        IERC20TToken pg = IERC20TToken(launcher.launch());
        vm.stopPrank();
        assertEq(pg.owner(), beneficiary);
        assertEq(pg.balanceOf(beneficiary), 50_000_000 ether);
        assertEq(pg.feeRecipient(), beneficiary);
        assertEq(pg.balanceOf(address(launcher)), 0);
    }

    function test_tokenAndImplementationRejectReinitialization() public {
        IERC20TToken pg = _launch();
        IERC20TFactory.Config memory config = launcher.tokenConfig();
        bytes memory payload = abi.encodeWithSignature(
            "initialize((string,string,uint256,uint256,address,address,address,address,address,uint16,address,uint16,uint32,address))",
            config
        );
        address attacker = makeAddr("reinitializer");
        vm.startPrank(attacker, attacker);
        (bool ok, bytes memory reason) = address(pg).call(payload);
        assertFalse(ok);
        assertEq(reason, abi.encodeWithSignature("AlreadyInitialized()"));
        (ok, reason) = launcher.IMPLEMENTATION().call(payload);
        assertFalse(ok);
        assertEq(reason, abi.encodeWithSignature("AlreadyInitialized()"));
        vm.stopPrank();
        assertEq(pg.owner(), address(this));
        assertEq(pg.totalSupply(), 1_000_000_000 ether);
        assertEq(pg.balanceOf(attacker), 0);
    }

    function test_quotePinsOneWeiAndLargestAcceptedPrice() public view {
        assertEq(launcher.quotePrice(1), 2e31);
        assertEq(launcher.quotePrice(2e31), 1);
        assertEq(launcher.quotePrice(2e31 - 1), 2);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_higherImdUsdPriceNeverRaisesThePgImdQuote(uint256 firstSeed, uint256 secondSeed)
        public
        view
    {
        uint256 first = bound(firstSeed, 1, 2e31);
        uint256 second = bound(secondSeed, first, 2e31);
        assertLe(launcher.quotePrice(second), launcher.quotePrice(first));
    }
}
