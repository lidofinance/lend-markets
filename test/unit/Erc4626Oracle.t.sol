// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {Erc4626Oracle} from "../../src/oracle/Erc4626Oracle.sol";
import {NavOracleBase} from "../../src/oracle/NavOracleBase.sol";
import {OssifiableProxy} from "../../src/proxy/OssifiableProxy.sol";

import {MockERC20, MockUsdFeed} from "../setup/Mocks.sol";
import {NavOracleModel} from "../setup/NavOracleModel.sol";

/// @dev OpenZeppelin vault with a configurable decimals offset, so the share and asset decimals can differ.
contract OffsetVault is ERC4626 {
    uint8 internal immutable OFFSET;

    constructor(IERC20 asset_, uint8 offset_) ERC20("Vault", "VLT") ERC4626(asset_) {
        OFFSET = offset_;
    }

    function _decimalsOffset() internal view override returns (uint8) {
        return OFFSET;
    }
}

/// @notice `Erc4626Oracle` prices one whole vault share at `convertToAssets(10^shareDecimals)`, scaled from the asset's
///         decimals to 18, with the share as the collateral token and the asset taken as one loan token per unit.
contract Erc4626OracleTest is Test {
    MockUsdFeed internal pegFeed;
    MockERC20 internal usdc;

    function setUp() public {
        vm.warp(1_760_000_000);
        pegFeed = new MockUsdFeed();
        usdc = new MockERC20("USDC", "USDC", 6);
    }

    function testRevert_constructor_zeroVault() public {
        vm.expectRevert(NavOracleBase.ZeroAddress.selector);
        new Erc4626Oracle(address(0), address(usdc), address(pegFeed));
    }

    function testRevert_constructor_assetDecimalsAbove18() public {
        MockERC20 asset = new MockERC20("A", "A", 19);
        OffsetVault vault = new OffsetVault(IERC20(address(asset)), 0);
        vm.expectRevert(abi.encodeWithSelector(Erc4626Oracle.UnsupportedAssetDecimals.selector, 19));
        new Erc4626Oracle(address(vault), address(usdc), address(pegFeed));
    }

    /// @dev sUSDS-like: an 18-decimal share of an 18-decimal asset that is not the loan token, at 1.08 assets per
    ///      share, prices at 1.08 USDC per share, `1.08e18 × 10^(36 + 6 − 18 − 18) = 1.08e24`.
    function test_price_foreignAssetExample() public {
        MockERC20 usds = new MockERC20("USDS", "USDS", 18);
        OffsetVault vault = _seed(usds, 0, 1_000_000e18, 1_080_000e18);
        Erc4626Oracle oracle = _deploy(vault);
        assertEq(oracle.ONE_SHARE(), 1e18, "ONE_SHARE");
        assertEq(oracle.SOURCE_SCALE(), 1, "SOURCE_SCALE");
        assertEq(oracle.PRICE_SCALE(), 1e6, "PRICE_SCALE");
        assertEq(oracle.price(), vault.convertToAssets(1e18) * 1e6, "price");
        assertApproxEqAbs(oracle.price(), 1.08e24, 1e7, "about 1.08 USDC per share");
    }

    /// @dev Any asset decimals and offset: the price is `convertToAssets(10^shareDecimals) × 10^(18 −
    /// assetDecimals)`
    ///      times `10^(36 + 6 − shareDecimals − 18)`.
    function testFuzz_price_scalesShareAndAssetDecimals(uint8 assetDecimals, uint8 offset, uint256 gain) public {
        assetDecimals = uint8(bound(assetDecimals, 0, 18));
        offset = uint8(bound(offset, 0, 6));
        uint256 shareDecimals = uint256(assetDecimals) + offset;
        vm.assume(shareDecimals <= 24);
        MockERC20 asset = new MockERC20("A", "A", assetDecimals);
        uint256 deposit = 1_000_000 * 10 ** uint256(assetDecimals);
        gain = bound(gain, 0, deposit);
        OffsetVault vault = _seed(asset, offset, deposit, deposit + gain);
        Erc4626Oracle oracle = _deploy(vault);

        uint256 nav = vault.convertToAssets(10 ** shareDecimals) * 10 ** (18 - uint256(assetDecimals));
        assertEq(oracle.ONE_SHARE(), 10 ** shareDecimals, "ONE_SHARE");
        assertEq(oracle.PRICE_SCALE(), 10 ** (24 - shareDecimals), "PRICE_SCALE");
        assertEq(oracle.price(), nav * 10 ** (24 - shareDecimals), "price");
        // A whole share converts with one asset unit of precision, so the rate check needs some asset decimals.
        if (assetDecimals >= 6) {
            uint256 rate = Math.mulDiv(deposit + gain, 1e18, deposit);
            assertApproxEqRel(nav, rate, 1e13, "NAV is the vault's assets per share");
        }
    }

    /// @dev A deposit, then a donation that moves the exchange rate: assets in the vault over shares out.
    function _seed(MockERC20 asset, uint8 offset, uint256 deposit, uint256 totalAssets)
        internal
        returns (OffsetVault vault)
    {
        vault = new OffsetVault(IERC20(address(asset)), offset);
        asset.mint(address(this), deposit);
        asset.approve(address(vault), deposit);
        vault.deposit(deposit, address(this));
        asset.mint(address(vault), totalAssets - deposit);
    }

    function _deploy(OffsetVault vault) internal returns (Erc4626Oracle) {
        Erc4626Oracle impl = new Erc4626Oracle(address(vault), address(usdc), address(pegFeed));
        bytes memory init =
            abi.encodeCall(NavOracleBase.initialize, (address(this), NavOracleModel.workingDefaults(0.0425e18)));
        return Erc4626Oracle(address(new OssifiableProxy(address(impl), address(this), init)));
    }
}
