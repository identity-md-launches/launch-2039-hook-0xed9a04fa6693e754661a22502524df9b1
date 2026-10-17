// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {PlaygroundLauncher} from "src/PlaygroundLauncher.sol";
import {IERC20TToken} from "src/interfaces/ILaunchDependencies.sol";
import {PoolKey, PoolActor, ITokenExtras} from "./V4TestInterfaces.sol";

interface IPlaygroundAccounting {
    function burn(uint256 amount) external;
    function getTransferAllowance(bool fromPoolManager) external view returns (uint256);
    function getNetTransferAllowance() external view returns (int256);
    function increaseTransferAllowance(uint256 amount, bool fromPoolManager) external;
    function accountTransferDelta(int128 delta) external;
}

/// @dev All balances are funded before the campaign. No action mints or deals tokens/native currency.
///      Ghost balances use requested transfers/burns and independently checked swap deltas.
contract PlaygroundTradingHandler is Test {
    PlaygroundLauncher public immutable launcher;
    IERC20TToken public immutable pg;
    IERC20TToken public immutable imd;
    address public immutable protocolRecipient;
    PoolActor[3] public traders;
    address[4] public wallets;
    PoolKey internal key;

    mapping(address => uint256) public expectedPg;
    uint256 public burned;
    uint256 public beneficiaryFees;
    uint256 public protocolFees;
    uint256 public buys;
    uint256 public sells;
    uint256 public roundTrips;
    uint256 public transfers;
    uint256 public rejectedCalls;

    struct TradeSnapshot {
        IERC20TToken input;
        IERC20TToken output;
        uint256 inputBalance;
        uint256 outputBalance;
        uint256 beneficiaryEth;
        uint256 protocolEth;
    }

    constructor(PlaygroundLauncher launcher_, address protocolRecipient_) {
        launcher = launcher_;
        pg = IERC20TToken(launcher_.token());
        imd = IERC20TToken(launcher_.IMD());
        protocolRecipient = protocolRecipient_;
        key = ITokenExtras(address(pg)).poolKey();
        wallets[0] = launcher_.BENEFICIARY();
        expectedPg[wallets[0]] = 50_000_000 ether;
        for (uint256 i; i < 3; ++i) {
            traders[i] = new PoolActor(launcher_.POOL_MANAGER());
            wallets[i + 1] = makeAddr(string.concat("PG holder ", vm.toString(i)));
        }
    }

    function buy(uint256 traderSeed, uint256 amountSeed) external {
        PoolActor trader = traders[bound(traderSeed, 0, 2)];
        uint256 balance = imd.balanceOf(address(trader));
        if (balance == 0) return;
        _trade(trader, true, bound(amountSeed, 1, _min(balance, 1_000 ether)));
    }

    function sell(uint256 traderSeed, uint256 amountSeed) external {
        PoolActor trader = traders[bound(traderSeed, 0, 2)];
        uint256 balance = pg.balanceOf(address(trader));
        if (balance == 0) return;
        _trade(trader, false, bound(amountSeed, 1, balance));
    }

    function buyThenSell(uint256 traderSeed, uint256 amountSeed) external {
        PoolActor trader = traders[bound(traderSeed, 0, 2)];
        uint256 quoteBefore = imd.balanceOf(address(trader));
        uint256 pgBefore = pg.balanceOf(address(trader));
        if (quoteBefore == 0) return;
        _trade(trader, true, bound(amountSeed, 1, _min(quoteBefore, 1_000 ether)));
        uint256 bought = pg.balanceOf(address(trader)) - pgBefore;
        if (bought != 0) _trade(trader, false, bought);
        assertLe(imd.balanceOf(address(trader)), quoteBefore, "profitable isolated buy/sell cycle");
        assertEq(pg.balanceOf(address(trader)), pgBefore, "round trip must sell only what it bought");
        ++roundTrips;
    }

    function transferWallet(uint256 fromSeed, uint256 toSeed, uint256 amountSeed) external {
        address from = wallets[bound(fromSeed, 0, 3)];
        address to = wallets[bound(toSeed, 0, 3)];
        uint256 amount = bound(amountSeed, 0, expectedPg[from]);
        uint256 supplyBefore = pg.totalSupply();
        vm.prank(from, from);
        assertTrue(pg.transfer(to, amount));
        expectedPg[from] -= amount;
        expectedPg[to] += amount;
        assertEq(pg.balanceOf(from), expectedPg[from]);
        assertEq(pg.balanceOf(to), expectedPg[to]);
        assertEq(pg.totalSupply(), supplyBefore);
        ++transfers;
    }

    function burn(uint256 actorSeed, uint256 amountSeed) external {
        uint256 actorIndex = bound(actorSeed, 0, 6);
        address actor = actorIndex < 4 ? wallets[actorIndex] : address(traders[actorIndex - 4]);
        uint256 amount = bound(amountSeed, 0, expectedPg[actor]);
        vm.prank(actor, actor);
        IPlaygroundAccounting(address(pg)).burn(amount);
        expectedPg[actor] -= amount;
        burned += amount;
        assertEq(pg.balanceOf(actor), expectedPg[actor]);
    }

    function overspend(uint256 actorSeed, uint256 extraSeed) external {
        address actor = wallets[bound(actorSeed, 0, 3)];
        uint256 amount = pg.balanceOf(actor) + bound(extraSeed, 1, 1_000_000_000 ether);
        vm.prank(actor, actor);
        vm.expectRevert(bytes4(keccak256("InsufficientBalance()")));
        pg.transfer(wallets[1], amount);
        vm.prank(actor, actor);
        vm.expectRevert(bytes4(keccak256("InsufficientBalance()")));
        IPlaygroundAccounting(address(pg)).burn(amount);
        rejectedCalls += 2;
    }

    function unauthorizedAdministration(uint256 actorSeed, uint16 rate) external {
        address actor = wallets[bound(actorSeed, 0, 3)];
        vm.startPrank(actor, actor);
        vm.expectRevert(bytes4(keccak256("Unauthorized()")));
        ITokenExtras(address(pg)).setTaxBps(rate);
        vm.expectRevert(bytes4(keccak256("Unauthorized()")));
        ITokenExtras(address(pg)).setFeeRecipient(actor);
        vm.expectRevert(bytes4(keccak256("Unauthorized()")));
        pg.transferOwnership(actor);
        vm.expectRevert(bytes4(keccak256("OnlyHook()")));
        IPlaygroundAccounting(address(pg)).increaseTransferAllowance(type(uint128).max, true);
        vm.expectRevert(bytes4(keccak256("OnlyHook()")));
        IPlaygroundAccounting(address(pg)).accountTransferDelta(type(int128).max);
        vm.stopPrank();
        rejectedCalls += 5;
    }

    function advanceTime(uint256 secondsSeed) external {
        vm.warp(block.timestamp + bound(secondsSeed, 0, 7 days));
    }

    function _trade(PoolActor trader, bool buying, uint256 amount) internal {
        TradeSnapshot memory before_;
        before_.input = buying ? imd : pg;
        before_.output = buying ? pg : imd;
        before_.inputBalance = before_.input.balanceOf(address(trader));
        before_.outputBalance = before_.output.balanceOf(address(trader));
        before_.beneficiaryEth = launcher.BENEFICIARY().balance;
        before_.protocolEth = protocolRecipient.balance;
        vm.recordLogs();
        int256 delta = trader.swap(key, key.currency0 == address(before_.input), -int256(amount));
        uint256 grossOutput = _grossOutput(vm.getRecordedLogs(), address(trader), address(before_.output));
        int128 inputDelta = key.currency0 == address(before_.input) ? int128(delta >> 128) : int128(delta);
        int128 outputDelta = key.currency0 == address(before_.output) ? int128(delta >> 128) : int128(delta);
        assertLe(inputDelta, 0);
        assertGe(outputDelta, 0);
        uint256 paid = uint128(-inputDelta);
        uint256 received = uint128(outputDelta);
        assertLe(paid, amount, "swap overcharged input");
        assertEq(before_.input.balanceOf(address(trader)), before_.inputBalance - paid);
        assertEq(before_.output.balanceOf(address(trader)), before_.outputBalance + received);
        assertEq(received, grossOutput - grossOutput * 250 / 10_000, "tax must be included at 2.5%");
        if (buying) {
            expectedPg[address(trader)] += received;
            ++buys;
        } else {
            expectedPg[address(trader)] -= paid;
            ++sells;
        }
        uint256 beneficiaryPaid = launcher.BENEFICIARY().balance - before_.beneficiaryEth;
        uint256 protocolPaid = protocolRecipient.balance - before_.protocolEth;
        assertEq(protocolPaid, (beneficiaryPaid + protocolPaid) * 15 / 250, "protocol share added on top");
        beneficiaryFees += beneficiaryPaid;
        protocolFees += protocolPaid;

        // Check inside the same transaction; checking only from an invariant would miss leftover
        // transient authorization, since Forge clears it between top-level calls.
        IPlaygroundAccounting accounting = IPlaygroundAccounting(address(pg));
        assertEq(accounting.getTransferAllowance(true), 0, "unconsumed withdrawal authorization");
        assertEq(accounting.getTransferAllowance(false), 0, "unconsumed deposit authorization");
        assertEq(accounting.getNetTransferAllowance(), 0, "unsettled token delta");
    }

    function _grossOutput(Vm.Log[] memory logs, address trader, address output)
        internal
        view
        returns (uint256)
    {
        bytes32 swapTopic = keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory entry = logs[i];
            if (
                entry.emitter == launcher.POOL_MANAGER() && entry.topics.length == 3
                    && entry.topics[0] == swapTopic && entry.topics[1] == keccak256(abi.encode(key))
                    && entry.topics[2] == bytes32(uint256(uint160(trader)))
            ) {
                (int128 amount0, int128 amount1,,,,) =
                    abi.decode(entry.data, (int128, int128, uint160, uint128, int24, uint24));
                int128 gross = output == key.currency0 ? amount0 : amount1;
                assertGe(gross, 0, "output is negative");
                return uint128(gross);
            }
        }
        revert("missing canonical pool swap event");
    }

    function _min(uint256 a, uint256 b) private pure returns (uint256) {
        return a < b ? a : b;
    }
}
