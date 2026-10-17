// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IERC20TToken {
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function owner() external view returns (address);
    function hook() external view returns (address);
    function quoteToken() external view returns (address);
    function positionManager() external view returns (address);
    function permit2() external view returns (address);
    function poolManager() external view returns (address);
    function taxBps() external view returns (uint16);
    function restingTaxBps() external view returns (uint16);
    function launchTaxBps() external view returns (uint16);
    function taxDecayIntervalSeconds() external view returns (uint32);
    function feeRecipient() external view returns (address);
    function feeDecayRecipient() external view returns (address);
    function launched() external view returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferOwnership(address newOwner) external payable;
}

interface IERC20THook {
    function poolManager() external view returns (address);
    function PROTOCOL_FEE_BPS() external view returns (uint16);
    function externalBases(address quote) external view returns (bool registered, bool enabled);
}

interface IPositionManager {
    function poolManager() external view returns (address);
    function permit2() external view returns (address);
}
