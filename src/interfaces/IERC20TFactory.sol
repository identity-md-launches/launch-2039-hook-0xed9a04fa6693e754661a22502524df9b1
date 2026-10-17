// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice ABI of the supplied, verified Ethereum ERC20TFactory.
/// @dev Contract-typed fields in the upstream Config have the same ABI as address.
interface IERC20TFactory {
    struct Config {
        string name;
        string symbol;
        uint256 supply;
        uint256 lpSupply;
        address owner;
        address hook;
        address quoteToken;
        address positionManager;
        address permit2;
        uint16 taxBps;
        address feeRecipient;
        uint16 launchTaxBps;
        uint32 taxDecayIntervalSeconds;
        address feeDecayRecipient;
    }

    struct LaunchPreview {
        uint256 creatorSupply;
        uint256 lpSupply;
        uint160 sqrtPriceX96;
        int24 tickLower;
        int24 tickUpper;
        uint256 effectivePriceWei;
    }

    function implementation() external view returns (address);

    function createAndLaunchAtPrice(
        Config calldata config,
        uint16 creatorAllocationBps,
        uint256 startingPriceQuote
    ) external payable returns (address token);

    function previewQuotedLaunch(
        uint256 supply,
        uint16 creatorAllocationBps,
        uint256 startingPriceQuote,
        bool tokenIsCurrency0
    ) external pure returns (LaunchPreview memory);
}
