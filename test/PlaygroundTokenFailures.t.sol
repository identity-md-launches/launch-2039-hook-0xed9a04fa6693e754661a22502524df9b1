// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ProtocolFixture} from "./helpers/ProtocolFixture.sol";
import {IERC20TToken} from "src/interfaces/ILaunchDependencies.sol";
import {ITokenExtras, PoolActor, PoolKey, SwapParams} from "./helpers/V4TestInterfaces.sol";
import {IPlaygroundAccounting} from "./helpers/PlaygroundTradingHandler.sol";

interface ITokenAdministration {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function setDistributors(address[] calldata accounts, bool allowed) external;
    function setFeeDecayRecipient(address recipient) external;
}

interface IHookSwapCallback {
    function afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        int256 delta,
        bytes calldata data
    ) external returns (bytes4, int128);
}

interface ITestPermitAllowance {
    function allowance(address owner, address token, address spender)
        external
        view
        returns (uint160, uint48, uint48);
}

contract PlaygroundTestSpender {
    function move(address token, address from, address to, uint256 amount) external {
        require(ITokenAdministration(token).transferFrom(from, to, amount), "transfer failed");
    }
}

contract PlaygroundTokenFailuresTest is ProtocolFixture {
    IERC20TToken internal pg;
    PoolActor internal trader;
    PoolKey internal key;

    function setUp() public {
        _setUpProtocol();
        trader = _fundBasePool();
        pg = _launch();
        key = ITokenExtras(address(pg)).poolKey();
    }

    function test_unsupportedExactOutputRollsBackAndDoesNotPreventAnExactInputTrade() public {
        // The supplied hook explicitly rejects exact-output swaps. This is a dependency constraint;
        // verify atomic failure, then use its supported exact-input route.
        uint256 imdBefore = IERC20TToken(launcher.IMD()).balanceOf(address(trader));
        uint256 reserveBefore = pg.balanceOf(launcher.POOL_MANAGER());
        uint256 beneficiaryBefore = launcher.BENEFICIARY().balance;
        uint256 protocolBefore = PROTOCOL_RECIPIENT.balance;
        bytes memory expected = abi.encodeWithSignature(
            "WrappedError(address,bytes4,bytes,bytes)",
            launcher.HOOK(),
            IHookSwapCallback.afterSwap.selector,
            abi.encodeWithSignature("ExactOutputNotAllowed()"),
            abi.encodeWithSignature("HookCallFailed()")
        );
        bool buyZeroForOne = key.currency0 == launcher.IMD();
        vm.expectRevert(expected);
        trader.swap(key, buyZeroForOne, int256(1_000_000 ether));
        assertEq(pg.balanceOf(address(trader)), 0);
        assertEq(IERC20TToken(launcher.IMD()).balanceOf(address(trader)), imdBefore);
        assertEq(pg.balanceOf(launcher.POOL_MANAGER()), reserveBefore);
        assertEq(launcher.BENEFICIARY().balance, beneficiaryBefore);
        assertEq(PROTOCOL_RECIPIENT.balance, protocolBefore);
        trader.swap(key, key.currency0 == launcher.IMD(), -int256(100 ether));
        assertGt(pg.balanceOf(address(trader)), 0);
        assertGt(launcher.BENEFICIARY().balance, beneficiaryBefore);
    }

    function test_completedSwapDoesNotAuthorizeLaterUnrelatedPoolTransfers() public {
        trader.swap(key, key.currency0 == launcher.IMD(), -int256(100 ether));
        address beneficiary = launcher.BENEFICIARY();
        address manager = launcher.POOL_MANAGER();
        uint256 reserveBefore = pg.balanceOf(manager);
        uint256 beneficiaryBefore = pg.balanceOf(beneficiary);
        vm.prank(beneficiary, beneficiary);
        vm.expectRevert(bytes4(keccak256("InvalidTransfer()")));
        pg.transfer(manager, 1);
        assertEq(pg.balanceOf(manager), reserveBefore);
        assertEq(pg.balanceOf(beneficiary), beneficiaryBefore);
        IPlaygroundAccounting token = IPlaygroundAccounting(address(pg));
        assertEq(token.getTransferAllowance(false), 0);
        assertEq(token.getTransferAllowance(true), 0);
        assertEq(token.getNetTransferAllowance(), 0);
    }

    function test_approvalAloneCannotBypassDistributionPolicyAndFailedSpendKeepsAllowance() public {
        PlaygroundTestSpender spender = new PlaygroundTestSpender();
        address beneficiary = launcher.BENEFICIARY();
        address receiver = address(spender);
        ITokenExtras token = ITokenExtras(address(pg));
        vm.prank(beneficiary, beneficiary);
        assertTrue(token.approve(address(spender), 100 ether));
        vm.expectRevert(bytes4(keccak256("InvalidTransfer()")));
        spender.move(address(pg), beneficiary, receiver, 60 ether);
        assertEq(token.allowance(beneficiary, address(spender)), 100 ether);
        assertEq(pg.balanceOf(beneficiary), 50_000_000 ether);
        assertEq(pg.balanceOf(receiver), 0);

        address[] memory distributors = new address[](1);
        distributors[0] = address(spender);
        ITokenAdministration(address(pg)).setDistributors(distributors, true);
        spender.move(address(pg), beneficiary, receiver, 60 ether);
        assertEq(token.allowance(beneficiary, address(spender)), 40 ether);
        assertEq(pg.balanceOf(beneficiary), 50_000_000 ether - 60 ether);
        assertEq(pg.balanceOf(receiver), 60 ether);
        vm.expectRevert(bytes4(keccak256("InsufficientAllowance()")));
        spender.move(address(pg), beneficiary, receiver, 40 ether + 1);
        assertEq(token.allowance(beneficiary, address(spender)), 40 ether);
        assertEq(pg.balanceOf(receiver), 60 ether);

        // Revocation takes effect despite an unspent ERC20 allowance.
        ITokenAdministration(address(pg)).setDistributors(distributors, false);
        vm.expectRevert(bytes4(keccak256("InvalidTransfer()")));
        spender.move(address(pg), beneficiary, receiver, 1);
        assertEq(token.allowance(beneficiary, address(spender)), 40 ether);
        assertEq(pg.totalSupply(), 1_000_000_000 ether);
    }

    function test_ownerCannotSetOutOfRangeTaxOrForbiddenRecipients() public {
        uint16[4] memory invalidRates = [uint16(0), 29, 501, type(uint16).max];
        for (uint256 i; i < invalidRates.length; ++i) {
            vm.expectRevert(bytes4(keccak256("InvalidTax()")));
            ITokenExtras(address(pg)).setTaxBps(invalidRates[i]);
            assertEq(pg.taxBps(), 250);
        }
        address[4] memory invalidRecipients =
            [address(0), address(pg), launcher.POOL_MANAGER(), launcher.HOOK()];
        for (uint256 i; i < invalidRecipients.length; ++i) {
            vm.expectRevert(bytes4(keccak256("InvalidAddress()")));
            ITokenExtras(address(pg)).setFeeRecipient(invalidRecipients[i]);
            vm.expectRevert(bytes4(keccak256("InvalidAddress()")));
            ITokenAdministration(address(pg)).setFeeDecayRecipient(invalidRecipients[i]);
            assertEq(pg.feeRecipient(), launcher.BENEFICIARY());
            assertEq(pg.feeDecayRecipient(), launcher.BENEFICIARY());
        }
    }

    function test_launchClearsBothErc20AndPermit2Allowances() public view {
        assertEq(ITokenExtras(address(pg)).allowance(address(pg), launcher.PERMIT2()), 0);
        (uint160 amount,,) = ITestPermitAllowance(launcher.PERMIT2())
            .allowance(address(pg), address(pg), launcher.POSITION_MANAGER());
        assertEq(amount, 0);
    }
}
