// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {WstEthRateOracle} from "../../src/oracle/WstEthRateOracle.sol";
import {UsdyStableOracle} from "../../src/oracle/UsdyStableOracle.sol";
import {OssifiableProxy} from "../../src/proxy/OssifiableProxy.sol";

import {OracleConfigFile, WstEthOracleConfig, UsdyOracleConfig} from "./OracleConfigFile.sol";

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

    function validate(
        string memory config,
        string memory name,
        address oracle,
        address loanToken,
        address collateralToken,
        address expectedAdmin
    ) internal {
        string memory toml = OracleConfigFile.readRaw(config, name);
        bool isWstEth = OracleConfigFile.hasKey(toml, ".wsteth");
        bool isUsdy = OracleConfigFile.hasKey(toml, ".usdy_oracle");
        if (!isWstEth && !isUsdy) revert UnknownOracleConfig(name);
        if (isWstEth && isUsdy) revert AmbiguousOracleConfig(name);

        if (isWstEth) {
            WstEthOracleConfig memory cfg = OracleConfigFile.readWstEth(config, name);
            address implementation = validateProxy(oracle, expectedAdmin);
            validateWstEth(cfg, oracle, implementation, collateralToken);
        } else {
            UsdyOracleConfig memory cfg = OracleConfigFile.readUsdy(config, name);
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

    function _requireCodehash(address expected, address actual) private view {
        if (expected.codehash != actual.codehash) {
            revert OracleImplementationMismatch(expected.codehash, actual.codehash);
        }
    }
}
