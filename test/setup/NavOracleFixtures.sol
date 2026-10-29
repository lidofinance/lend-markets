// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";

import {CentrifugeNavOracle} from "../../src/oracle/CentrifugeNavOracle.sol";
import {TrailingAnchorOracleBase} from "../../src/oracle/TrailingAnchorOracleBase.sol";
import {UsdyNavOracle} from "../../src/oracle/UsdyNavOracle.sol";
import {OssifiableProxy} from "../../src/proxy/OssifiableProxy.sol";

import {MockERC20} from "./Mocks.sol";
import {INavSourceMock, MockCentrifugeSpoke, MockOndoPriceGetter} from "./NavSourceMocks.sol";

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

/// @notice `CentrifugeNavOracle` over the Spoke, for a 6-decimal share class like JTRSY.
abstract contract CentrifugeNavOracleFixture is NavOracleFixture {
    uint64 internal constant POOL_ID = 281474976710662;
    bytes16 internal constant SHARE_CLASS_ID = 0x00010000000000060000000000000001;

    function _setUpSource() internal override {
        source = new MockCentrifugeSpoke(POOL_ID, SHARE_CLASS_ID);
        collateralToken = address(new MockERC20("Janus Henderson Anemoy Treasury Fund", "JTRSY", 6));
    }

    function _newImplementation(address loanToken) internal override returns (address) {
        return address(new CentrifugeNavOracle(address(source), POOL_ID, SHARE_CLASS_ID, loanToken, collateralToken));
    }

    function _namespace() internal pure override returns (string memory) {
        return "lido.lend.storage.CentrifugeNavOracle";
    }
}
