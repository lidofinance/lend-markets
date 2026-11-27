// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";

import {CentrifugeNavOracle} from "../../src/oracle/CentrifugeNavOracle.sol";
import {ChainlinkOracle} from "../../src/oracle/ChainlinkOracle.sol";
import {TrailingAnchorOracleBase} from "../../src/oracle/TrailingAnchorOracleBase.sol";
import {UsdyNavOracle} from "../../src/oracle/UsdyNavOracle.sol";
import {OssifiableProxy} from "../../src/proxy/OssifiableProxy.sol";

import {MockERC20} from "./Mocks.sol";
import {INavSourceMock, MockCentrifugeVault, MockChainlinkFeed, MockOndoPriceGetter} from "./NavSourceMocks.sol";

/// @notice One NAV adapter over its source mock, for suites that run the same anchor rules through every adapter. A
///         concrete suite mixes in exactly one of the fixtures below.
abstract contract NavOracleFixture is Test {
    /// @dev The adapter's source, driven in the oracle's price units.
    INavSourceMock internal source;
    /// @dev The adapter's collateral token.
    address internal collateralToken;

    /// @dev Deploys the source mock and the collateral token.
    function _setUpSource() internal virtual;

    /// @dev A new implementation of the adapter over the fixture's source, for `loanToken`.
    function _newImplementation(address loanToken) internal virtual returns (address);

    /// @dev The adapter's ERC-7201 namespace id.
    function _namespace() internal pure virtual returns (string memory);

    /// @dev The adapter behind a new proxy administered by `admin` and initialized with `init`.
    function _deployOracle(address loanToken, address admin, bytes memory init)
        internal
        returns (TrailingAnchorOracleBase)
    {
        return TrailingAnchorOracleBase(address(new OssifiableProxy(_newImplementation(loanToken), admin, init)));
    }
}

/// @notice `UsdyNavOracle` over Ondo's getter, for an 18-decimal USDY.
abstract contract UsdyNavOracleFixture is NavOracleFixture {
    function _setUpSource() internal override {
        source = new MockOndoPriceGetter();
        collateralToken = address(new MockERC20("Ondo US Dollar Yield", "USDY", 18));
    }

    function _newImplementation(address loanToken) internal override returns (address) {
        return address(new UsdyNavOracle(address(source), loanToken, collateralToken));
    }

    function _namespace() internal pure override returns (string memory) {
        return "lido.lend.storage.UsdyNavOracle";
    }
}

/// @notice `CentrifugeNavOracle` over a vault, for a 6-decimal share token like JTRSY.
abstract contract CentrifugeNavOracleFixture is NavOracleFixture {
    uint256 internal constant MAX_PRICE_AGE = 7 days;

    function _setUpSource() internal override {
        collateralToken = address(new MockERC20("Janus Henderson Anemoy Treasury Fund", "JTRSY", 6));
        source = new MockCentrifugeVault(collateralToken, address(0));
    }

    /// @dev The vault's asset becomes `loanToken`, the one loan token of the suite's oracle. A zero loan token
    ///      leaves it, so that the constructor, which refuses it, is the next call a suite expects to revert.
    function _newImplementation(address loanToken) internal override returns (address) {
        if (loanToken != address(0)) MockCentrifugeVault(address(source)).setAsset(loanToken);
        return address(new CentrifugeNavOracle(address(source), MAX_PRICE_AGE, loanToken, collateralToken));
    }

    function _namespace() internal pure override returns (string memory) {
        return "lido.lend.storage.CentrifugeNavOracle";
    }
}

/// @notice `ChainlinkOracle` over an 18-decimal feed, for an 18-decimal collateral like deJTRSY. With 18 decimals
///         the feed's answer is the price a suite sets, exactly.
abstract contract ChainlinkOracleFixture is NavOracleFixture {
    uint256 internal constant MAX_PRICE_AGE = 2 days;

    function _setUpSource() internal override {
        collateralToken = address(new MockERC20("JTRSY deRWA", "deJTRSY", 18));
        source = new MockChainlinkFeed(18);
    }

    function _newImplementation(address loanToken) internal override returns (address) {
        return address(new ChainlinkOracle(address(source), MAX_PRICE_AGE, loanToken, collateralToken));
    }

    function _namespace() internal pure override returns (string memory) {
        return "lido.lend.storage.ChainlinkOracle";
    }
}
