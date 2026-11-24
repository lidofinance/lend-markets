// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {CentrifugeNavOracle, ICentrifugeVault} from "../../src/oracle/CentrifugeNavOracle.sol";
import {TrailingAnchorOracleBase} from "../../src/oracle/TrailingAnchorOracleBase.sol";
import {IOndoPriceGetter, UsdyNavOracle} from "../../src/oracle/UsdyNavOracle.sol";
import {OssifiableProxy} from "../../src/proxy/OssifiableProxy.sol";

import {TrailingAnchorOracleModel} from "../setup/TrailingAnchorOracleModel.sol";
import {ForkStack} from "./helpers/ForkStack.sol";

/// @dev The kind of a Centrifuge vault; 0 is an asynchronous vault.
interface ICentrifugeVaultKind {
    function vaultKind() external view returns (uint8);
}

/// @notice Each NAV adapter over its live mainnet source. The unit suites use mocks of the sources, so only these
///         tests show that an adapter reads the source that a deployment gives it.
contract NavOracleSourcesTest is ForkStack {
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant USDY = 0x96F6eF951840721AdBF46Ac996b59E0235CB985C;
    address internal constant ONDO_USDY_ORACLE = 0xA0219AA5B31e65Bc920B5b6DFb8EdF0988121De0;

    address internal constant JTRSY = 0x8c213ee79581Ff4984583C6a801e5263418C4b86;
    address internal constant JAAA = 0x5a0F93D040De44e78F251b03c43be9CF317Dcf64;
    address internal constant DEJTRSY = 0xA6233014B9b7aaa74f38fa1977ffC7A89642dC72;
    address internal constant DEJAAA = 0xAAA0008C8CF3A7Dca931adaF04336A5D808C82Cc;
    address internal constant JTRSY_USDC_VAULT = 0xFE6920eB6C421f1179cA8c8d4170530CDBdfd77A;
    address internal constant JAAA_USDC_VAULT = 0x4880799eE5200fC58DA299e965df644fBf46780B;
    address internal constant DEJTRSY_USDC_VAULT = 0x18Ab9fC0B2e4Fef9e0e03c8EC63BA287a3238257;
    address internal constant DEJAAA_USDC_VAULT = 0x4865BC9701fBD1207A7B50e2aF442C7DAf154c9c;
    uint256 internal constant MAX_PRICE_AGE = 7 days;

    /// @dev A NAV with 18 decimals is between these values. A source with other decimals is far outside them.
    uint256 internal constant MIN_NAV = 1e18;
    uint256 internal constant MAX_NAV = 2e18;

    address internal admin = makeAddr("admin");

    function setUp() public {
        _selectSourceFork();
    }

    /// @dev USDY has 18 decimals and USDC has 6, so the price is the Ondo value times 1e6.
    function test_usdyNavOracle_readsTheOndoOracle() public {
        assertEq(IERC20Metadata(USDY).decimals(), 18, "USDY decimals");
        assertEq(IERC20Metadata(USDC).decimals(), 6, "USDC decimals");
        uint256 nav = IOndoPriceGetter(ONDO_USDY_ORACLE).getPrice();
        assertGe(nav, MIN_NAV, "Ondo value below an 18-decimal NAV");
        assertLe(nav, MAX_NAV, "Ondo value above an 18-decimal NAV");

        _assertSeededFrom(address(new UsdyNavOracle(ONDO_USDY_ORACLE, USDC, USDY)), nav, 1e6);
    }

    /// @dev JTRSY and USDC have 6 decimals: the adapter converts 10^18 JTRSY units, and the price is that value times
    ///      1e18. The seed reverts if the vault's price stamp is older than `MAX_PRICE_AGE`.
    function test_centrifugeNavOracle_readsTheJtrsyVault() public {
        _assertVaultSeeds(JTRSY_USDC_VAULT, JTRSY, 6);
    }

    function test_centrifugeNavOracle_readsTheJaaaVault() public {
        _assertVaultSeeds(JAAA_USDC_VAULT, JAAA, 6);
    }

    /// @dev deJTRSY has 18 decimals: the adapter converts 10^30 deJTRSY units, and the price is that value times 1e6.
    function test_centrifugeNavOracle_readsTheDejtrsyVault() public {
        _assertVaultSeeds(DEJTRSY_USDC_VAULT, DEJTRSY, 18);
    }

    function test_centrifugeNavOracle_readsTheDejaaaVault() public {
        _assertVaultSeeds(DEJAAA_USDC_VAULT, DEJAAA, 18);
    }

    /// @dev The vault is the asynchronous USDC vault of `share`, its value of `10^(shareDecimals + 12)` share units is
    ///      an 18-decimal NAV, and an oracle over it seeds from that value.
    function _assertVaultSeeds(address vault, address share, uint8 shareDecimals) internal {
        assertEq(IERC20Metadata(share).decimals(), shareDecimals, "share decimals");
        assertEq(ICentrifugeVault(vault).share(), share, "share token of the vault");
        assertEq(ICentrifugeVault(vault).asset(), USDC, "asset of the vault");
        assertEq(ICentrifugeVaultKind(vault).vaultKind(), 0, "asynchronous vault");
        uint256 nav = ICentrifugeVault(vault).convertToAssets(10 ** (uint256(shareDecimals) + 12));
        assertGe(nav, MIN_NAV, "vault value below an 18-decimal NAV");
        assertLe(nav, MAX_NAV, "vault value above an 18-decimal NAV");

        _assertSeededFrom(
            address(new CentrifugeNavOracle(vault, MAX_PRICE_AGE, USDC, share)),
            nav,
            10 ** (24 - uint256(shareDecimals))
        );
    }

    /// @dev An oracle that is initialized over `implementation` has the source value `nav` as its anchor, returns it
    ///      times `priceScale`, and an update finds the price inside the bounds.
    function _assertSeededFrom(address implementation, uint256 nav, uint256 priceScale) internal {
        TrailingAnchorOracleBase oracle = TrailingAnchorOracleBase(
            address(new OssifiableProxy(implementation, admin, TrailingAnchorOracleModel.initializeCall(admin)))
        );
        assertEq(oracle.anchorPrice(), nav, "anchor is the source value");
        assertEq(oracle.price(), nav * priceScale, "price is the source value at the market scale");
        assertEq(
            uint8(oracle.updateAnchor()), uint8(TrailingAnchorOracleBase.UpdateOutcome.WithinBounds), "update outcome"
        );
    }
}
