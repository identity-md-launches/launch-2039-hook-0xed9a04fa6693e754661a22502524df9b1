// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20TFactory} from "./interfaces/IERC20TFactory.sol";
import {IERC20TToken, IERC20THook, IPositionManager} from "./interfaces/ILaunchDependencies.sol";

/// @title PlaygroundLauncher
/// @notice One-use Ethereum launcher for PLAYGROUND (PG) through the requested ERC20T factory.
/// @dev The owner supplies a recent IMD/USD observation. This is an explicit operator price,
///      not an on-chain oracle. All economics except that observation are fixed here.
contract PlaygroundLauncher {
    address public constant FACTORY = 0x801411c6aCeC4Fa80c75c5d3C0eAe13C84f8a173;
    address public constant HOOK = 0xed9A04Fa6693e754661A22502524DF9b1857e544;
    address public constant IMPLEMENTATION = 0x2df7DCf4D19a7924e00AE96629CC1d1261670eEe;
    address public constant BENEFICIARY = 0xcB58AdA9F7338Bfbe06Ec647f27DE8D0664dddaC;
    address public constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address public constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address public constant POSITION_MANAGER = 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e;
    address public constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    uint256 public constant CHAIN_ID = 1;
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 ether;
    uint256 public constant BENEFICIARY_SUPPLY = 50_000_000 ether;
    uint256 public constant LP_SUPPLY = TOTAL_SUPPLY - BENEFICIARY_SUPPLY;
    uint16 public constant CREATOR_ALLOCATION_BPS = 500;
    uint16 public constant TOTAL_TAX_BPS = 250;
    uint16 public constant PROTOCOL_TAX_BPS = 15;
    uint16 public constant BENEFICIARY_TAX_BPS = TOTAL_TAX_BPS - PROTOCOL_TAX_BPS;
    uint256 public constant TARGET_FDV_USD_WAD = 20_000 ether;
    uint256 public constant MAX_QUOTE_AGE = 1 hours;

    // ($20,000 * 1e18 USD scale * 1e18 IMD scale) / 1 billion whole PG.
    uint256 private constant PRICE_NUMERATOR = 2e31;

    address public immutable owner;
    uint256 public imdUsdPriceWad;
    uint64 public priceObservedAt;
    address public token;
    bool private _launching;

    error Unauthorized();
    error InvalidOwner();
    error AlreadyLaunched();
    error LaunchInProgress();
    error PriceNotConfigured();
    error InvalidPrice();
    error InvalidQuoteTime();
    error StaleQuote();
    error WrongChain();
    error MissingDependency(address dependency);
    error IncompatibleDependencies();
    error ImdPairingUnavailable();
    error UnexpectedLaunchResult();
    error AllocationTransferFailed();

    event ImdUsdPriceSet(uint256 priceUsdWad, uint64 observedAt, uint256 startingPriceQuote);
    event PlaygroundLaunched(
        address indexed token,
        address indexed tokenOwner,
        address indexed beneficiary,
        uint256 startingPriceQuote,
        uint256 imdUsdPriceWad,
        uint64 priceObservedAt
    );

    /// @param owner_ Launch owner ($owner), who also receives ERC20T administration after launch.
    /// @dev No dependency calls or code checks: safe to deploy on the empty constructor rehearsal chain.
    constructor(address owner_) {
        if (
            owner_ == address(0) || owner_ == address(this) || owner_ == FACTORY || owner_ == HOOK
                || owner_ == IMPLEMENTATION || owner_ == POOL_MANAGER || owner_ == POSITION_MANAGER
                || owner_ == PERMIT2 || owner_ == IMD
        ) revert InvalidOwner();
        owner = owner_;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    modifier beforeLaunch() {
        if (_launching) revert LaunchInProgress();
        if (token != address(0)) revert AlreadyLaunched();
        _;
    }

    /// @notice Record USD per whole IMD, scaled by 1e18, from an owner-reviewed market observation.
    /// @dev This grants the owner pricing responsibility, not freedom to change the $20,000 FDV formula.
    function setImdUsdPrice(uint256 priceUsdWad, uint64 observedAt) external onlyOwner beforeLaunch {
        quotePrice(priceUsdWad); // Reject zero and values below one base unit of quote precision.
        if (observedAt > block.timestamp) revert InvalidQuoteTime();
        if (block.timestamp - observedAt >= MAX_QUOTE_AGE) revert StaleQuote();
        imdUsdPriceWad = priceUsdWad;
        priceObservedAt = observedAt;
        emit ImdUsdPriceSet(priceUsdWad, observedAt, quotePrice(priceUsdWad));
    }

    /// @notice IMD base units per whole PG, rounded upward by less than one IMD base unit.
    function quotePrice(uint256 priceUsdWad) public pure returns (uint256) {
        if (priceUsdWad == 0 || priceUsdWad > PRICE_NUMERATOR) revert InvalidPrice();
        return (PRICE_NUMERATOR - 1) / priceUsdWad + 1;
    }

    function startingPriceQuote() public view returns (uint256) {
        if (imdUsdPriceWad == 0) revert PriceNotConfigured();
        if (block.timestamp < priceObservedAt || block.timestamp - priceObservedAt >= MAX_QUOTE_AGE) {
            revert StaleQuote();
        }
        return quotePrice(imdUsdPriceWad);
    }

    /// @notice Inspect the exact factory configuration without creating a token.
    function tokenConfig() public view returns (IERC20TFactory.Config memory) {
        return IERC20TFactory.Config({
            name: "PLAYGROUND",
            symbol: "PG",
            supply: TOTAL_SUPPLY,
            lpSupply: LP_SUPPLY,
            owner: address(this),
            hook: HOOK,
            quoteToken: IMD,
            positionManager: POSITION_MANAGER,
            permit2: PERMIT2,
            taxBps: TOTAL_TAX_BPS,
            feeRecipient: BENEFICIARY,
            launchTaxBps: 0,
            taxDecayIntervalSeconds: 0,
            feeDecayRecipient: BENEFICIARY
        });
    }

    /// @notice Preview both possible token-address orderings before the factory creates the clone.
    function preview(bool tokenIsCurrency0) external view returns (IERC20TFactory.LaunchPreview memory) {
        _checkDependencies();
        return IERC20TFactory(FACTORY)
            .previewQuotedLaunch(TOTAL_SUPPLY, CREATOR_ALLOCATION_BPS, startingPriceQuote(), tokenIsCurrency0);
    }

    /// @notice Atomically create PG, seed the locked PG/IMD position, distribute 5%, and hand off ownership.
    /// @dev No ETH or IMD deposit: the factory creates single-sided PG liquidity at the opening price.
    function launch() external onlyOwner beforeLaunch returns (address created) {
        uint256 price = startingPriceQuote();
        _checkDependencies();
        _launching = true;

        created = IERC20TFactory(FACTORY).createAndLaunchAtPrice(tokenConfig(), CREATOR_ALLOCATION_BPS, price);
        IERC20TToken pg = IERC20TToken(created);
        _checkToken(pg);
        token = created;

        // The factory sends the creator allocation to this temporary token owner. The
        // owner's transfer is exempt from ERC20T's distributor restrictions.
        if (!pg.transfer(BENEFICIARY, BENEFICIARY_SUPPLY)) revert AllocationTransferFailed();
        if (pg.balanceOf(BENEFICIARY) != BENEFICIARY_SUPPLY || pg.balanceOf(address(this)) != 0) {
            revert UnexpectedLaunchResult();
        }
        pg.transferOwnership(owner);
        if (pg.owner() != owner) revert UnexpectedLaunchResult();

        _launching = false;
        emit PlaygroundLaunched(created, owner, BENEFICIARY, price, imdUsdPriceWad, priceObservedAt);
    }

    function _checkDependencies() private view {
        if (block.chainid != CHAIN_ID) revert WrongChain();
        _requireCode(FACTORY);
        _requireCode(IMPLEMENTATION);
        _requireCode(HOOK);
        _requireCode(IMD);
        _requireCode(POOL_MANAGER);
        _requireCode(POSITION_MANAGER);
        _requireCode(PERMIT2);
        if (
            IERC20TFactory(FACTORY).implementation() != IMPLEMENTATION
                || IERC20THook(HOOK).poolManager() != POOL_MANAGER
                || IERC20THook(HOOK).PROTOCOL_FEE_BPS() != PROTOCOL_TAX_BPS
                || IPositionManager(POSITION_MANAGER).poolManager() != POOL_MANAGER
                || IPositionManager(POSITION_MANAGER).permit2() != PERMIT2
                || IERC20TToken(IMD).decimals() != 18
                || keccak256(bytes(IERC20TToken(IMD).symbol())) != keccak256("IMD")
        ) revert IncompatibleDependencies();
        (bool registered, bool enabled) = IERC20THook(HOOK).externalBases(IMD);
        if (!registered || !enabled) revert ImdPairingUnavailable();
    }

    function _checkToken(IERC20TToken pg) private view {
        if (address(pg).code.length == 0) revert UnexpectedLaunchResult();
        if (
            !pg.launched() || pg.owner() != address(this) || pg.totalSupply() != TOTAL_SUPPLY
                || pg.balanceOf(address(this)) != BENEFICIARY_SUPPLY || pg.hook() != HOOK
                || pg.quoteToken() != IMD
                || pg.balanceOf(POOL_MANAGER) + pg.balanceOf(address(pg)) != LP_SUPPLY
                || pg.poolManager() != POOL_MANAGER || pg.positionManager() != POSITION_MANAGER
                || pg.permit2() != PERMIT2 || pg.taxBps() != TOTAL_TAX_BPS
                || pg.restingTaxBps() != TOTAL_TAX_BPS || pg.launchTaxBps() != 0
                || pg.taxDecayIntervalSeconds() != 0 || pg.feeRecipient() != BENEFICIARY
                || pg.feeDecayRecipient() != BENEFICIARY || pg.decimals() != 18
                || keccak256(bytes(pg.name())) != keccak256("PLAYGROUND")
                || keccak256(bytes(pg.symbol())) != keccak256("PG")
        ) revert UnexpectedLaunchResult();
    }

    function _requireCode(address dependency) private view {
        if (dependency.code.length == 0) revert MissingDependency(dependency);
    }
}
