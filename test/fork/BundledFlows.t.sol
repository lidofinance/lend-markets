// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {Call, IBundler3} from "@bundler3/src/interfaces/IBundler3.sol";

import {LidoLendVaultAdapter} from "../../src/adapters/LidoLendVaultAdapter.sol";
import {Erc4626Math} from "../setup/Erc4626Math.sol";
import {IGeneralAdapter1} from "../setup/IGeneralAdapter1.sol";
import {Market} from "../setup/Types.sol";
import {MarketActions} from "../setup/MarketActions.sol";
import {ForkStack} from "./helpers/ForkStack.sol";

/// @notice The frontend guide's bundles through the deployed Bundler3 and its adapters, on one market per kind: a vault
///         deposit, posting collateral, a borrow, closing a position and a lender's exit. Each lands its tokens on the
///         user and leaves nothing on the dispatcher or the adapters. Posting collateral moves it through the general
///         adapter, so it skips where the collateral does not admit the adapter: a Centrifuge member list holds only
///         the core. Skips when the network records no bundler.
contract BundledFlowsForkTest is ForkStack {
    using MarketActions for Market;

    IBundler3 internal bundler3;
    IGeneralAdapter1 internal adapter;
    address internal vaultAdapter;

    function setUp() public {
        _onlyOnOneMarketPerKind();
        _setUpTarget();
        if (bundler.bundler == address(0)) vm.skip(true, "Bundler: absent in this deployment");
        bundler3 = IBundler3(bundler.bundler);
        adapter = IGeneralAdapter1(bundler.generalAdapter);
        vaultAdapter = bundler.vaultAdapter;
        _seedLenderAndBorrower();
    }

    /// @dev Inside free liquidity only the redeem leg runs: the initiator gets the ERC-4626 value of its shares in
    ///      loan tokens, with the adapter's floors set to exactly that, and the bundle leaves no residue behind.
    function test_bundledFallbackExit_liquidOnly_paysInitiator() public {
        uint256 shares = lenderShares / 2;
        uint256 expectedAssets = Erc4626Math.toAssets(market.vault, shares, Math.Rounding.Floor);
        assertLe(expectedAssets, _freeLiquidity(), "setup: the exit fits free liquidity");

        Call[] memory bundle = new Call[](1);
        bundle[0] = _call(
            vaultAdapter,
            abi.encodeCall(
                LidoLendVaultAdapter.fallbackExit, (address(market.vault), shares, 0, LENDER, expectedAssets, shares)
            )
        );
        vm.prank(LENDER);
        market.vault.approve(vaultAdapter, shares);
        vm.prank(LENDER);
        bundler3.multicall(bundle);

        assertEq(market.loanToken.balanceOf(LENDER), expectedAssets, "initiator paid the ERC-4626 value");
        assertEq(market.vault.balanceOf(LENDER), lenderShares - shares, "exactly the requested shares burned");
        _assertNoResidue();
    }

    /// @dev The loan token goes to the adapter and into the vault for the depositor, at the previewed shares.
    function test_bundle_deposit_mintsThePreviewedShares() public {
        address depositor = _freshActor(market, "bundle.depositor");
        uint256 assets = 2 * _oneLoanToken();
        _requireSupplyHeadroom(market, assets);
        deal(address(market.loanToken), depositor, assets);
        _approve(address(market.loanToken), depositor, address(adapter), assets);
        uint256 expectedShares = market.vault.previewDeposit(assets);

        Call[] memory bundle = new Call[](2);
        bundle[0] = _adapterCall(
            abi.encodeCall(IGeneralAdapter1.erc20TransferFrom, (address(market.loanToken), address(adapter), assets))
        );
        bundle[1] = _adapterCall(
            abi.encodeCall(
                IGeneralAdapter1.erc4626Deposit,
                (address(market.vault), type(uint256).max, type(uint256).max, depositor)
            )
        );
        vm.prank(depositor);
        bundler3.multicall(bundle);

        assertEq(market.vault.balanceOf(depositor), expectedShares, "the previewed shares");
        assertEq(market.loanToken.balanceOf(depositor), 0, "the whole deposit spent");
        _assertNoResidue();
    }

    /// @dev The collateral goes to the adapter and into the core for the poster.
    function test_bundle_postCollateral_suppliesThePoster() public {
        if (!_collateralAdmits(address(adapter))) {
            vm.skip(true, "Bundler: the collateral does not admit the general adapter");
        }
        address poster = _freshActor(market, "bundle.poster");
        collateralIssuer.dealCollateral(poster, lot);
        _approve(address(market.collateralToken), poster, address(adapter), lot);

        Call[] memory bundle = new Call[](2);
        bundle[0] = _adapterCall(
            abi.encodeCall(IGeneralAdapter1.erc20TransferFrom, (address(market.collateralToken), address(adapter), lot))
        );
        bundle[1] = _adapterCall(
            abi.encodeCall(IGeneralAdapter1.morphoSupplyCollateral, (market.params, type(uint256).max, poster, ""))
        );
        vm.prank(poster);
        bundler3.multicall(bundle);

        assertEq(market.core.position(market.id, poster).collateral, lot, "the collateral posted");
        assertEq(market.collateralToken.balanceOf(poster), 0, "the whole collateral spent");
        _assertNoResidue();
    }

    /// @dev Against active collateral, the authorized adapter borrows straight to the borrower.
    function test_bundle_borrow_paysTheBorrower() public {
        uint256 assets = _maxBorrow(market, lot, market.oracle.price()) / 10;
        uint256 debtBefore = market.controller.positionOf(BORROWER).debtAssets;
        uint256 loanBefore = market.loanToken.balanceOf(BORROWER);
        vm.prank(BORROWER);
        market.core.setAuthorization(address(adapter), true);

        Call[] memory bundle = new Call[](1);
        bundle[0] = _adapterCall(abi.encodeCall(IGeneralAdapter1.morphoBorrow, (market.params, assets, 0, 0, BORROWER)));
        vm.prank(BORROWER);
        bundler3.multicall(bundle);

        assertEq(market.loanToken.balanceOf(BORROWER), loanBefore + assets, "the borrow paid the borrower");
        assertGe(market.controller.positionOf(BORROWER).debtAssets, debtBefore + assets, "the debt grew by the borrow");
        _assertNoResidue();
    }

    /// @dev Repays all debt by shares, withdraws the whole collateral straight to the borrower and sweeps the
    ///      overshoot back: the position closes and the collateral comes back in full.
    function test_bundle_closePosition_returnsTheCollateral() public {
        uint256 repayAssets = market.repayAssets(market.core.position(market.id, BORROWER).borrowShares);
        uint256 pulled = repayAssets + repayAssets / 100 + 1;
        deal(address(market.loanToken), BORROWER, pulled);
        _approve(address(market.loanToken), BORROWER, address(adapter), pulled);
        vm.prank(BORROWER);
        market.core.setAuthorization(address(adapter), true);

        Call[] memory bundle = new Call[](4);
        bundle[0] = _adapterCall(
            abi.encodeCall(IGeneralAdapter1.erc20TransferFrom, (address(market.loanToken), address(adapter), pulled))
        );
        bundle[1] = _adapterCall(
            abi.encodeCall(
                IGeneralAdapter1.morphoRepay, (market.params, 0, type(uint256).max, type(uint256).max, BORROWER, "")
            )
        );
        bundle[2] = _adapterCall(
            abi.encodeCall(IGeneralAdapter1.morphoWithdrawCollateral, (market.params, type(uint256).max, BORROWER))
        );
        bundle[3] = _adapterCall(
            abi.encodeCall(IGeneralAdapter1.erc20Transfer, (address(market.loanToken), BORROWER, type(uint256).max))
        );
        vm.prank(BORROWER);
        bundler3.multicall(bundle);

        assertEq(market.core.position(market.id, BORROWER).borrowShares, 0, "the debt repaid");
        assertEq(market.core.position(market.id, BORROWER).collateral, 0, "the collateral withdrawn");
        assertEq(market.collateralToken.balanceOf(BORROWER), lot, "the collateral back in full");
        assertEq(market.loanToken.balanceOf(BORROWER), pulled - repayAssets, "the overshoot swept back");
        _assertNoResidue();
    }

    function _adapterCall(bytes memory data) internal view returns (Call memory) {
        return _call(address(adapter), data);
    }

    function _call(address to, bytes memory data) internal pure returns (Call memory) {
        return Call({to: to, data: data, value: 0, skipRevert: false, callbackHash: bytes32(0)});
    }

    /// @dev The dispatcher and adapters are stateless conduits: anything left on them is a bundle-encoding bug.
    function _assertNoResidue() internal view {
        address[3] memory holders = [address(bundler3), address(adapter), vaultAdapter];
        for (uint256 i; i < holders.length; ++i) {
            assertEq(market.loanToken.balanceOf(holders[i]), 0, "residue: loan token");
            assertEq(market.collateralToken.balanceOf(holders[i]), 0, "residue: collateral token");
            assertEq(market.vault.balanceOf(holders[i]), 0, "residue: vault shares");
        }
    }
}
