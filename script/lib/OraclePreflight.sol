// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {LIQUIDATION_CURSOR, MAX_LIQUIDATION_INCENTIVE_FACTOR} from "@lido-lend/src/libraries/ConstantsLib.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {WAD} from "../../src/libs/Constants.sol";

import {WstEthRateOracle} from "../../src/oracle/WstEthRateOracle.sol";
import {UsdyStableOracle} from "../../src/oracle/UsdyStableOracle.sol";
import {
    TrailingAnchorOracleBase,
    ORACLE_PRICE_DECIMALS,
    PRICE_DECIMALS
} from "../../src/oracle/TrailingAnchorOracleBase.sol";
import {OssifiableProxy} from "../../src/proxy/OssifiableProxy.sol";

import {NavOracleImplementation} from "./NavOracleImplementation.sol";
import {NavOracleConfig, OracleConfigFile, WstEthOracleConfig, UsdyOracleConfig} from "./OracleConfigFile.sol";

interface IOraclePreflight {
    function price() external view returns (uint256);
}

interface IWstEthOraclePreflight {
    function WSTETH() external view returns (address);
}

interface IUsdyOraclePreflight {
    function USDY_ORACLE() external view returns (address);
    function stableUsdFeed() external view returns (address);
    function scale() external view returns (uint256);
    function MIN_PRICE() external view returns (uint256);
    function MAX_PRICE() external view returns (uint256);
}

interface IFeedDecimals {
    function decimals() external view returns (uint8);
}

library OraclePreflight {
    error UnknownOracleConfig(string name);
    error AmbiguousOracleConfig(string name);
    error OracleNotContract(address oracle);
    error OracleImplementationNotContract(address implementation);
    error OracleProxyCodehashMismatch(bytes32 expected, bytes32 actual);
    error OracleProxyAdminMismatch(address expected, address actual);
    error OracleImplementationMismatch(bytes32 expected, bytes32 actual);
    error OracleAddressMismatch(string field, address expected, address actual);
    error OracleScaleMismatch(uint256 expected, uint256 actual);
    error OracleUintMismatch(string field, uint256 expected, uint256 actual);
    error OraclePriceOutOfConfiguredBounds(uint256 price, uint256 minPrice, uint256 maxPrice);
    error OraclePriceIsZero();
    /// @notice A position borrowed at `lltv` against the highest price the NAV oracle returns would not cover its debt
    ///         and the liquidation incentive at the lowest; `largestAboveMark` is the widest `maxAnchorAboveMark` that
    ///         would with this `maxAnchorBelowMark`, zero when none above zero would.
    error NavCorridorTooWide(
        uint256 maxAnchorBelowMark, uint256 maxAnchorAboveMark, uint256 lltv, uint256 largestAboveMark
    );
    /// @notice A source falling at `maxAnchorFallPerYear` would outrun the lower bound within one delay, so each
    ///         re-anchor would land short of it; `largestFall` is the fastest fall the bound covers.
    error NavFallOutrunsDelay(uint256 maxAnchorFallPerYear, uint256 reanchorDelay, uint256 largestFall);

    uint256 private constant YEAR = 365 days;

    /// @param lltv The LLTV of the market the oracle is validated for; only a NAV oracle uses it.
    function validate(
        string memory name,
        address oracle,
        address loanToken,
        address collateralToken,
        uint256 lltv,
        address expectedAdmin
    ) internal {
        string memory toml = OracleConfigFile.readRaw(name);
        bool isWstEth = OracleConfigFile.hasKey(toml, ".wsteth");
        bool isUsdy = OracleConfigFile.hasKey(toml, ".usdy_oracle");
        bool isNav = OracleConfigFile.isNavKind(OracleConfigFile.kind(name));
        if (!isWstEth && !isUsdy && !isNav) revert UnknownOracleConfig(name);
        if (isWstEth && isUsdy) revert AmbiguousOracleConfig(name);

        if (isNav) {
            NavOracleConfig memory cfg = OracleConfigFile.readNav(name);
            address implementation = validateProxy(oracle, expectedAdmin);
            validateNav(cfg, oracle, implementation, loanToken, collateralToken, lltv);
        } else if (isWstEth) {
            WstEthOracleConfig memory cfg = OracleConfigFile.readWstEth(name);
            address implementation = validateProxy(oracle, expectedAdmin);
            validateWstEth(cfg, oracle, implementation, collateralToken);
        } else {
            UsdyOracleConfig memory cfg = OracleConfigFile.readUsdy(name);
            address implementation = validateProxy(oracle, expectedAdmin);
            validateUsdy(cfg, oracle, implementation, loanToken, collateralToken);
        }

        if (IOraclePreflight(oracle).price() == 0) revert OraclePriceIsZero();
    }

    function validateProxy(address oracle, address expectedAdmin) internal returns (address implementation) {
        if (oracle.code.length == 0) revert OracleNotContract(oracle);

        OssifiableProxy proxy = OssifiableProxy(payable(oracle));
        address actualAdmin = proxy.proxy__getAdmin();
        if (actualAdmin != expectedAdmin) revert OracleProxyAdminMismatch(expectedAdmin, actualAdmin);
        implementation = proxy.proxy__getImplementation();
        if (implementation.code.length == 0) revert OracleImplementationNotContract(implementation);

        address expectedProxy = address(new OssifiableProxy(implementation, expectedAdmin, ""));
        if (oracle.codehash != expectedProxy.codehash) {
            revert OracleProxyCodehashMismatch(expectedProxy.codehash, oracle.codehash);
        }
    }

    function validateWstEth(
        WstEthOracleConfig memory cfg,
        address oracle,
        address implementation,
        address collateralToken
    ) internal {
        if (cfg.wstETH != collateralToken) {
            revert OracleAddressMismatch("collateral_token", collateralToken, cfg.wstETH);
        }
        address expectedImplementation = address(new WstEthRateOracle(cfg.wstETH));
        _requireCodehash(expectedImplementation, implementation);
        address actualWstEth = IWstEthOraclePreflight(oracle).WSTETH();
        if (actualWstEth != cfg.wstETH) revert OracleAddressMismatch("wsteth", cfg.wstETH, actualWstEth);
    }

    function validateUsdy(
        UsdyOracleConfig memory cfg,
        address oracle,
        address implementation,
        address loanToken,
        address collateralToken
    ) internal {
        if (cfg.loanToken != loanToken) {
            revert OracleAddressMismatch("loan_token", loanToken, cfg.loanToken);
        }
        if (cfg.collateralToken != collateralToken) {
            revert OracleAddressMismatch("collateral_token", collateralToken, cfg.collateralToken);
        }

        address expectedImplementation = address(new UsdyStableOracle(cfg.usdyOracle, cfg.minPrice, cfg.maxPrice));
        _requireCodehash(expectedImplementation, implementation);

        address actualNavOracle = IUsdyOraclePreflight(oracle).USDY_ORACLE();
        if (actualNavOracle != cfg.usdyOracle) {
            revert OracleAddressMismatch("usdy_oracle", cfg.usdyOracle, actualNavOracle);
        }
        address actualFeed = IUsdyOraclePreflight(oracle).stableUsdFeed();
        if (actualFeed != cfg.feed) revert OracleAddressMismatch("feed", cfg.feed, actualFeed);

        uint256 expectedScale =
            10 ** (uint256(IERC20Metadata(cfg.loanToken).decimals()) + IFeedDecimals(cfg.feed).decimals());
        uint256 actualScale = IUsdyOraclePreflight(oracle).scale();
        if (actualScale != expectedScale) revert OracleScaleMismatch(expectedScale, actualScale);

        uint256 actualMinPrice = IUsdyOraclePreflight(oracle).MIN_PRICE();
        if (actualMinPrice != cfg.minPrice) revert OracleUintMismatch("min_price", cfg.minPrice, actualMinPrice);
        uint256 actualMaxPrice = IUsdyOraclePreflight(oracle).MAX_PRICE();
        if (actualMaxPrice != cfg.maxPrice) revert OracleUintMismatch("max_price", cfg.maxPrice, actualMaxPrice);

        // A live price on either edge means the band is mis-set: `price()` would revert on the next move.
        // Catch that before the market is wired to this oracle.
        uint256 livePrice = IOraclePreflight(oracle).price();
        if (livePrice <= cfg.minPrice || livePrice >= cfg.maxPrice) {
            revert OraclePriceOutOfConfiguredBounds(livePrice, cfg.minPrice, cfg.maxPrice);
        }
    }

    /// @notice The NAV oracle is the configured adapter over the market's tokens, its implementation is the one the
    ///         config builds, it runs on the configured parameters, and they pass the two rules the oracle cannot
    ///         check: the floor and the ceiling suit a market at `lltv`, and the fall speed stays within the lower
    ///         bound over one delay.
    function validateNav(
        NavOracleConfig memory cfg,
        address oracle,
        address implementation,
        address loanToken,
        address collateralToken,
        uint256 lltv
    ) internal {
        if (cfg.loanToken != loanToken) {
            revert OracleAddressMismatch("loan_token", loanToken, cfg.loanToken);
        }
        if (cfg.collateralToken != collateralToken) {
            revert OracleAddressMismatch("collateral_token", collateralToken, cfg.collateralToken);
        }
        _requireCodehash(NavOracleImplementation.deploy(cfg), implementation);

        TrailingAnchorOracleBase nav = TrailingAnchorOracleBase(oracle);
        uint256 expectedScale = 10
            ** (ORACLE_PRICE_DECIMALS
                + IERC20Metadata(loanToken).decimals()
                - IERC20Metadata(collateralToken).decimals()
                - PRICE_DECIMALS);
        if (nav.PRICE_SCALE() != expectedScale) revert OracleScaleMismatch(expectedScale, nav.PRICE_SCALE());
        TrailingAnchorOracleBase.Parameters memory p = cfg.parameters;
        _requireUint("max_price_above_anchor", p.maxPriceAboveAnchor, nav.maxPriceAboveAnchor());
        _requireUint("max_price_below_anchor", p.maxPriceBelowAnchor, nav.maxPriceBelowAnchor());
        _requireUint("max_anchor_rise_per_year", p.maxAnchorRisePerYear, nav.maxAnchorRisePerYear());
        _requireUint("max_anchor_fall_per_year", p.maxAnchorFallPerYear, nav.maxAnchorFallPerYear());
        _requireUint("max_anchor_below_mark", p.maxAnchorBelowMark, nav.maxAnchorBelowMark());
        _requireUint("max_anchor_above_mark", p.maxAnchorAboveMark, nav.maxAnchorAboveMark());
        _requireUint("reanchor_delay", p.reanchorDelay, nav.reanchorDelay());
        _requireUint("reanchor_window", p.reanchorWindow, nav.reanchorWindow());
        requireNavSizing(p, lltv);
    }

    /// @notice The two rules the oracle's validator cannot check, with the parameters as WAD fractions:
    ///         - a position borrowed at `lltv` against the highest price the oracle returns, the ceiling × (1 +
    ///           maxPriceAboveAnchor), still covers its debt and the core's liquidation incentive at the lowest, the
    ///           floor × (1 − maxPriceBelowAnchor): (1 − maxAnchorBelowMark)(1 − maxPriceBelowAnchor) ≥ lltv
    ///           × LIF × (1 + maxAnchorAboveMark)(1 + maxPriceAboveAnchor), rounded against the corridor;
    ///         - a source falling at `maxAnchorFallPerYear` stays within the lower bound over one delay, the fall side
    ///           of the rule the validator holds the rise to: reanchorDelay × maxAnchorFallPerYear ≤
    ///           maxPriceBelowAnchor × 365 days.
    function requireNavSizing(TrailingAnchorOracleBase.Parameters memory p, uint256 lltv) internal pure {
        uint256 incentive = Math.min(
            MAX_LIQUIDATION_INCENTIVE_FACTOR,
            Math.mulDiv(WAD, WAD, WAD - Math.mulDiv(LIQUIDATION_CURSOR, WAD - lltv, WAD))
        );
        // What the upper bound needs with the ceiling on the mark, and the room the floor's lower bound leaves.
        uint256 needed = Math.mulDiv(
            Math.mulDiv(lltv, incentive, WAD, Math.Rounding.Ceil), WAD + p.maxPriceAboveAnchor, WAD, Math.Rounding.Ceil
        );
        uint256 room = Math.mulDiv(WAD - p.maxAnchorBelowMark, WAD - p.maxPriceBelowAnchor, WAD);
        if (room < Math.mulDiv(needed, WAD + p.maxAnchorAboveMark, WAD, Math.Rounding.Ceil)) {
            uint256 largest = room < needed ? 0 : Math.mulDiv(room, WAD, needed) - WAD;
            revert NavCorridorTooWide(p.maxAnchorBelowMark, p.maxAnchorAboveMark, lltv, largest);
        }
        if (uint256(p.reanchorDelay) * p.maxAnchorFallPerYear > uint256(p.maxPriceBelowAnchor) * YEAR) {
            revert NavFallOutrunsDelay(
                p.maxAnchorFallPerYear, p.reanchorDelay, uint256(p.maxPriceBelowAnchor) * YEAR / p.reanchorDelay
            );
        }
    }

    function _requireUint(string memory field, uint256 expected, uint256 actual) private pure {
        if (actual != expected) revert OracleUintMismatch(field, expected, actual);
    }

    function _requireCodehash(address expected, address actual) private view {
        if (expected.codehash != actual.codehash) {
            revert OracleImplementationMismatch(expected.codehash, actual.codehash);
        }
    }
}
