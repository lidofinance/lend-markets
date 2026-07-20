// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Call} from "@bundler3/src/interfaces/IBundler3.sol";

import {BundlerSetup} from "../setup/BundlerSetup.sol";
import {MarketActions} from "../setup/MarketActions.sol";
import {MockERC20, MockPriceOracle} from "../setup/Mocks.sol";
import {Market} from "../setup/Types.sol";

/// @notice Bundled flows on a market whose loan token has 6 decimals (like USDC) while the collateral
///         keeps 18 (like USDY). The bundler contracts take every token and market as call arguments,
///         so the one deployed stack must serve such a market unchanged; this suite holds that claim
///         against the decimals gap. The WETH market from the shared setup stays deployed alongside,
///         so the residue check covers both markets after every bundle.
contract BundledFlowsDecimalsTest is BundlerSetup {
    using MarketActions for Market;

    /// @dev One whole loan token, at 6 decimals.
    uint256 internal constant ONE_LOAN = 1e6;

    uint256 internal constant COLLATERAL_AMOUNT = 100 ether;
    uint256 internal constant IDLE_LIQUIDITY = ONE_LOAN;

    MockERC20 internal loan6;
    MockERC20 internal collateral18;

    /// @dev This market's oracle price, rescaled for the decimals gap.
    uint256 internal price6;

    address internal lender;
    address internal borrower;

    function setUp() public {
        // Deploys the WETH market and the bundler stack; this suite then adds a second market with
        // the decimals gap on the same core and reuses the same dispatcher and adapters.
        _deployBundledMarket();

        loan6 = new MockERC20("Mock USD Stablecoin", "USD6", 6);
        collateral18 = new MockERC20("Mock Yield Dollar", "YLD18", 18);
        Market storage m = _addMarket(_defaultConfig(address(loan6), address(collateral18), address(0)));

        // The seeded price assumes tokens with equal decimals. Dividing by 1e12 keeps the same
        // real-terms ratio when the loan token has 12 fewer decimals than the collateral.
        price6 = oraclePrice / 1e12;
        MockPriceOracle(address(m.oracle)).setPrice(price6);

        lender = _actor("usdLender");
        borrower = _actor("usdBorrower");
    }

    /// @dev The 6-decimal market (the shared setup's WETH market is at index 0).
    function _m6() internal view returns (Market storage) {
        return protocol.markets[1];
    }

    /// @dev Same drained-market arrangement as the WETH exit tests, in 6-decimal amounts: the
    ///      borrower takes all but `IDLE_LIQUIDITY` of the pool and opts into settlement, so the
    ///      lender's exit must settle for collateral. The borrow is sized from the rescaled price to
    ///      sit at half of what the collateral allows.
    function _setUpIlliquidVaultLender() internal returns (Market storage m, uint256 borrowAmount) {
        m = _m6();
        borrowAmount = (COLLATERAL_AMOUNT * price6) / 1e36 / 2;

        _fund(m.loanToken, lender, borrowAmount + IDLE_LIQUIDITY);
        m.vaultDeposit(lender, borrowAmount + IDLE_LIQUIDITY);

        _fund(m.collateralToken, borrower, COLLATERAL_AMOUNT);
        m.supplyCollateral(borrower, COLLATERAL_AMOUNT);
        m.activateCollateral();
        m.borrow(borrower, borrowAmount);
        m.setSettlementLtv(borrower, 0.25e18);

        // Vault shares have no signature-based approval, so the adapter must be approved up front.
        vm.prank(lender);
        m.vault.approve(address(vaultAdapter), type(uint256).max);
    }

    /// @dev A plain pull-and-deposit works unchanged with a 6-decimal loan token; the shares match
    ///      the vault's own preview.
    function test_bundle_deposit_sixDecimalLoanToken() public {
        Market storage m = _m6();
        address user = _actor("usdDepositor");
        uint256 amount = 1_234_567_891; // a non-round amount, about 1234.57 whole tokens
        _fund(m.loanToken, user, amount);
        vm.prank(user);
        loan6.approve(address(adapter), amount);

        uint256 expectedShares = m.vault.previewDeposit(amount);

        Call[] memory bundle = new Call[](2);
        bundle[0] = _adapterCall(abi.encodeCall(adapter.erc20TransferFrom, (address(loan6), address(adapter), amount)));
        bundle[1] = _adapterCall(
            abi.encodeCall(adapter.erc4626Deposit, (address(m.vault), type(uint256).max, MAX_SHARE_PRICE_E27, user))
        );
        _exec(user, 0, bundle);

        assertGt(expectedShares, 0, "sanity: the preview mints shares");
        assertEq(m.vault.balanceOf(user), expectedShares, "vault shares match the preview");
        assertEq(loan6.balanceOf(user), 0, "all loan tokens deposited");
    }

    /// @dev Deposit then redeem, with the minimum share price computed exactly from the vault's own
    ///      preview: the share-price check in the general adapter must hold at 6 decimals too, and the
    ///      round trip may lose at most 1 unit of the loan token to rounding.
    function test_bundle_depositThenRedeem_roundTripSixDecimals() public {
        Market storage m = _m6();
        address user = _actor("usdRoundTripper");
        uint256 amount = 987_654_321;
        _fund(m.loanToken, user, amount);
        vm.prank(user);
        loan6.approve(address(adapter), amount);

        Call[] memory depositBundle = new Call[](2);
        depositBundle[0] =
            _adapterCall(abi.encodeCall(adapter.erc20TransferFrom, (address(loan6), address(adapter), amount)));
        depositBundle[1] = _adapterCall(
            abi.encodeCall(adapter.erc4626Deposit, (address(m.vault), type(uint256).max, MAX_SHARE_PRICE_E27, user))
        );
        _exec(user, 0, depositBundle);

        uint256 shares = m.vault.balanceOf(user);
        uint256 expectedAssets = m.vault.previewRedeem(shares);
        uint256 minSharePrice = (expectedAssets * 1e27) / shares;
        vm.prank(user);
        m.vault.approve(address(adapter), shares);

        Call[] memory redeemBundle = new Call[](1);
        redeemBundle[0] = _adapterCall(
            abi.encodeCall(adapter.erc4626Redeem, (address(m.vault), type(uint256).max, minSharePrice, user, user))
        );
        _exec(user, 0, redeemBundle);

        assertEq(m.vault.balanceOf(user), 0, "all shares redeemed");
        assertEq(loan6.balanceOf(user), expectedAssets, "round trip pays the previewed assets");
        assertLe(amount - expectedAssets, 1, "round-trip loss is at most one loan-token unit");
    }

    /// @dev The exit from a drained market across the decimals gap: `fallbackExit` pays the adapter
    ///      the idle 6-decimal loan tokens plus the seized 18-decimal collateral, the bundle forwards
    ///      both to the lender, and both minimums are given in 6-decimal loan units. The seized
    ///      collateral must equal the cancelled debt converted through the oracle price, which is
    ///      where the 12-decimal difference crosses.
    function test_bundle_fallbackExit_sixDecimalLoanToken() public {
        (Market storage m,) = _setUpIlliquidVaultLender();

        uint256 sharesBefore = m.vault.balanceOf(lender);
        uint128 borrowerCollateralBefore = m.core.position(m.id, borrower).collateral;
        uint128 totalBorrowBefore = m.core.market(m.id).totalBorrowAssets;

        // The minimum payout is one loan unit above the idle liquidity, so meeting it requires the
        // settlement to cancel debt; a value floor of that size only makes sense in 6-decimal units.
        Call[] memory bundle = new Call[](3);
        bundle[0] = _call(
            address(vaultAdapter),
            abi.encodeCall(
                vaultAdapter.fallbackExit,
                (address(m.vault), type(uint256).max, 0, address(adapter), IDLE_LIQUIDITY + 1, 1)
            )
        );
        bundle[1] = _adapterCall(abi.encodeCall(adapter.erc20Transfer, (address(loan6), lender, type(uint256).max)));
        bundle[2] =
            _adapterCall(abi.encodeCall(adapter.erc20Transfer, (address(collateral18), lender, type(uint256).max)));
        _exec(lender, 0, bundle);

        // No time passed since the borrow, so the drop in total debt is exactly what the settlement
        // cancelled, and the exit's loan payout is exactly the idle liquidity.
        uint256 debtCanceled = totalBorrowBefore - m.core.market(m.id).totalBorrowAssets;
        uint256 seized = borrowerCollateralBefore - m.core.position(m.id, borrower).collateral;
        assertGt(debtCanceled, 0, "settlement cancelled debt");
        assertEq(loan6.balanceOf(lender), IDLE_LIQUIDITY, "the idle loan tokens were paid out");
        assertEq(collateral18.balanceOf(lender), seized, "all seized collateral reached the lender");
        assertLt(m.vault.balanceOf(lender), sharesBefore, "shares were burned");

        // seized = debt cancelled * 1e36 / price, allowing one unit of rounding-down per settlement
        // slice. With debt in 6 decimals and collateral in 18, the price carries the conversion.
        assertApproxEqAbs(
            seized,
            (debtCanceled * 1e36) / price6,
            m.vault.DEFAULT_MAX_SETTLEMENT_ITERATIONS(),
            "seized collateral prices the cancelled debt across the decimals gap"
        );
        assertEq(
            uint256(totalBorrowBefore), (COLLATERAL_AMOUNT * price6) / 1e36 / 2, "sanity: debt was 6-decimal sized"
        );
    }
}
