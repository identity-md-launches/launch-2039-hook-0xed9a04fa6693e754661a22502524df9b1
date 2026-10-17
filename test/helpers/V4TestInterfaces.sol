// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

struct PoolKey {
    address currency0;
    address currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

struct ModifyLiquidityParams {
    int24 tickLower;
    int24 tickUpper;
    int256 liquidityDelta;
    bytes32 salt;
}

struct SwapParams {
    bool zeroForOne;
    int256 amountSpecified;
    uint160 sqrtPriceLimitX96;
}

interface IV4Manager {
    function initialize(PoolKey calldata key, uint160 sqrtPriceX96) external returns (int24 tick);
    function unlock(bytes calldata data) external returns (bytes memory);
    function modifyLiquidity(
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) external returns (int256 callerDelta, int256 feesAccrued);
    function swap(PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        external
        returns (int256 delta);
    function sync(address currency) external;
    function settle() external payable returns (uint256 paid);
    function take(address currency, address to, uint256 amount) external;
    function extsload(bytes32 slot) external view returns (bytes32);
}

interface ITestHook {
    function registerExternalBase(address token, PoolKey calldata pool) external;
    function setExternalBaseEnabled(address token, bool enabled) external;
    function setProtocolFeeRecipient(address recipient) external;
    function protocolFeeRecipient() external view returns (address);
    function poolToken(bytes32 poolId) external view returns (address);
}

interface IPositionNFT {
    function nextTokenId() external view returns (uint256);
    function ownerOf(uint256 id) external view returns (address);
    function getPositionLiquidity(uint256 id) external view returns (uint128);
    function modifyLiquidities(bytes calldata unlockData, uint256 deadline) external payable;
    function transferFrom(address from, address to, uint256 id) external;
}

interface ITokenExtras {
    function approve(address spender, uint256 amount) external returns (bool);
    function allowance(address from, address spender) external view returns (uint256);
    function setTaxBps(uint16 value) external;
    function setFeeRecipient(address recipient) external;
    function taxDecayActive() external view returns (bool);
    function poolKey() external view returns (PoolKey memory);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 value) external returns (bool);
}

/// @dev Test-only settlement helper. It owns its test funds, performs actual v4 unlock/settle flows,
///      and deliberately has no production authorization/slippage interface.
contract PoolActor {
    IV4Manager public immutable manager;

    constructor(address manager_) {
        manager = IV4Manager(manager_);
    }

    function addLiquidity(PoolKey memory key, int24 lower, int24 upper, int256 liquidity) external {
        manager.unlock(abi.encode(uint8(0), key, abi.encode(lower, upper, liquidity)));
    }

    function swap(PoolKey memory key, bool zeroForOne, int256 amount) external returns (int256 delta) {
        return abi.decode(manager.unlock(abi.encode(uint8(1), key, abi.encode(zeroForOne, amount))), (int256));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "manager only");
        (uint8 action, PoolKey memory key, bytes memory params) = abi.decode(data, (uint8, PoolKey, bytes));
        int256 delta;
        if (action == 0) {
            (int24 lower, int24 upper, int256 liquidity) = abi.decode(params, (int24, int24, int256));
            (delta,) =
                manager.modifyLiquidity(key, ModifyLiquidityParams(lower, upper, liquidity, bytes32(0)), "");
        } else {
            (bool zeroForOne, int256 amount) = abi.decode(params, (bool, int256));
            delta = manager.swap(
                key,
                SwapParams(
                    zeroForOne,
                    amount,
                    zeroForOne ? 4295128740 : 1461446703485210103287273052203988822378723970341
                ),
                ""
            );
        }
        _settle(key.currency0, int128(delta >> 128));
        _settle(key.currency1, int128(delta));
        return abi.encode(delta);
    }

    function _settle(address currency, int128 delta) private {
        if (delta > 0) {
            manager.take(currency, address(this), uint128(delta));
        } else if (delta < 0) {
            uint256 amount = uint128(-delta);
            if (currency == address(0)) {
                manager.settle{value: amount}();
            } else {
                manager.sync(currency);
                require(ITokenExtras(currency).transfer(address(manager), amount), "transfer failed");
                manager.settle();
            }
        }
    }

    receive() external payable {}
}
