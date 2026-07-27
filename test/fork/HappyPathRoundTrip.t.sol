// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Market} from "@lido-lend/src/interfaces/IMorpho.sol";
import {SharesMathLib} from "@lido-lend/src/libraries/SharesMathLib.sol";
import {ORACLE_PRICE_SCALE} from "@lido-lend/src/libraries/ConstantsLib.sol";

import {ILidoLendMarketController} from "../../src/interfaces/ILidoLendMarketController.sol";
import {ForkStack} from "./helpers/ForkStack.sol";

interface IWETH {
    function deposit() external payable;
}

interface IStETH {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function submit(address referral) external payable returns (uint256);
}

interface IWstETH {
    function wrap(uint256 stETHAmount) external returns (uint256);
}

/// @notice The illustrative happy path over the DEPLOYED `weth-wsteth` market — the simplest end-to-end proof
///         that a provisioned stack and the fork-test binding work together. One story, one step per helper:
///         a lender deposits WETH into the live vault; a borrower stakes ETH through the real Lido contracts
///         into wstETH, posts it as collateral, waits out the live activation timer, draws WETH, repays in
///         full and reclaims the collateral; the lender exits with the principal.
///
///         Everything is sized off the LIVE controller config and oracle price (never deploy-time constants),
///         all actors are fresh, and every assertion is a delta or an independently recomputed value — so the
///         test passes against a freshly provisioned fork AND a market that already carries positions.
contract HappyPathRoundTripTest is ForkStack {
    using SharesMathLib for uint256;

    BoundMarket internal m;

    address internal LENDER;
    address internal BORROWER;

    function setUp() public {
        _fork();
        m = _bindMarket("fork-weth-wsteth");
        _pokeAccrue(m); // fold pending interest so same-block delta assertions below are exact

        LENDER = _freshActor(m, "happyPath.lender");
        BORROWER = _freshActor(m, "happyPath.borrower");
    }

    function test_happyPath_lendBorrowRepayExit() public {
        // The network config's [external] table and the live market agree on the token wiring.
        assertEq(address(m.loanToken), _ext("weth"), "market loan token is the configured WETH");
        assertEq(address(m.collateralToken), _ext("wstEth"), "market collateral is the configured wstETH");

        (uint256 depositAssets, uint256 shares) = _lenderDeposits();
        uint256 collateral = _borrowerPostsCollateralAndItMatures();
        uint256 borrowAssets = _borrowerDraws(collateral);
        _borrowerRepaysInFullAndReclaims(collateral, borrowAssets);
        _lenderExits(depositAssets, shares);
    }

    // ---
    // STEPS
    // ---

    /// @dev 1. The lender wraps ETH and deposits into the deployed vault. Sized off the live activation
    ///      config so the test tracks governance values; comfortably covers the borrow in step 3.
    function _lenderDeposits() internal returns (uint256 depositAssets, uint256 shares) {
        depositAssets = 2 * uint256(m.activation.minActivationAmount);
        _requireDepositHeadroom(m, depositAssets);

        uint256 expectedShares = m.vault.previewDeposit(depositAssets);
        uint256 vaultAssetsBefore = m.vault.totalAssets();

        vm.deal(LENDER, depositAssets);
        vm.startPrank(LENDER);
        IWETH(address(m.loanToken)).deposit{value: depositAssets}();
        m.loanToken.approve(address(m.vault), depositAssets);
        shares = m.vault.deposit(depositAssets, LENDER);
        vm.stopPrank();

        assertEq(shares, expectedShares, "minted shares match the vault's preview");
        assertEq(m.vault.balanceOf(LENDER), shares, "lender holds the minted shares");
        assertEq(m.vault.totalAssets() - vaultAssetsBefore, depositAssets, "vault assets grew by the deposit");
    }

    /// @dev 2. The borrower stakes ETH into wstETH via the real Lido contracts and posts it as collateral.
    ///      The fresh lot sits in the controller's activation timer, then matures once the live maximum
    ///      delay has passed. Staking 3x the live dust threshold in ETH clears `minActivationAmount` with
    ///      margin (wstETH/ETH < 1 across the wrap).
    function _borrowerPostsCollateralAndItMatures() internal returns (uint256 collateral) {
        collateral = _stakeToWstEth(BORROWER, 3 * uint256(m.activation.minActivationAmount));
        require(collateral >= m.activation.minActivationAmount, "HappyPath: stake must clear the live dust threshold");

        vm.startPrank(BORROWER);
        m.collateralToken.approve(address(m.core), collateral);
        m.core.supplyCollateral(m.params, collateral, BORROWER, "");
        vm.stopPrank();

        ILidoLendMarketController.BorrowerPosition memory pos = m.controller.positionOf(BORROWER);
        assertEq(pos.activating, collateral, "fresh collateral enters the activation timer");
        assertEq(pos.active, 0, "nothing is active before the delay elapses");

        // The activation gate resolves LAZILY: after the warp the lot is mature, but the buckets fold over on
        // the next position touch — the borrow in step 3 both consumes and proves the maturation.
        _warpPastActivation(m);
        _pokeAccrue(m); // fold the interest the warp accrued, so the borrow-shares math in step 3 is exact
    }

    /// @dev 3. The borrower draws a quarter of the collateral's loan-token value — comfortably inside the
    ///      market LLTV. The expected debt shares are recomputed independently from the live totals.
    function _borrowerDraws(uint256 collateral) internal returns (uint256 borrowAssets) {
        borrowAssets = (collateral * m.oracle.price()) / ORACLE_PRICE_SCALE / 4;
        require(borrowAssets != 0, "HappyPath: borrow rounds to zero");
        require(borrowAssets <= _freeLiquidity(m), "HappyPath: market lacks liquidity for the borrow");

        Market memory mkt = m.core.market(m.id);
        uint256 expectedDebtShares =
            borrowAssets.toSharesUp(uint256(mkt.totalBorrowAssets), uint256(mkt.totalBorrowShares));

        vm.prank(BORROWER);
        m.core.borrow(m.params, borrowAssets, 0, BORROWER, BORROWER);

        assertEq(m.loanToken.balanceOf(BORROWER), borrowAssets, "borrower received the drawn WETH");
        assertEq(
            m.core.position(m.id, BORROWER).borrowShares,
            expectedDebtShares,
            "recorded debt shares match the independent recomputation"
        );
        assertEq(m.controller.positionOf(BORROWER).active, collateral, "the borrow resolved the matured lot to active");
    }

    /// @dev 4. The borrower repays in full and reclaims the collateral. Same block as the borrow, so no
    ///      further interest: repaying by SHARES closes the position exactly; the assets owed for those
    ///      shares round up, so wrap a small buffer over the drawn amount.
    function _borrowerRepaysInFullAndReclaims(uint256 collateral, uint256 borrowAssets) internal {
        uint256 debtShares = m.core.position(m.id, BORROWER).borrowShares;
        Market memory mkt = m.core.market(m.id);
        uint256 owed = debtShares.toAssetsUp(uint256(mkt.totalBorrowAssets), uint256(mkt.totalBorrowShares));
        assertGe(owed, borrowAssets, "the debt covers at least the drawn amount");

        vm.deal(BORROWER, 1 ether);
        vm.startPrank(BORROWER);
        IWETH(address(m.loanToken)).deposit{value: 1 ether}(); // covers the share-rounding dust over the draw
        m.loanToken.approve(address(m.core), owed);
        (uint256 repaidAssets,) = m.core.repay(m.params, 0, debtShares, BORROWER, "");
        m.core.withdrawCollateral(m.params, collateral, BORROWER, BORROWER);
        vm.stopPrank();

        assertEq(repaidAssets, owed, "repaid exactly the recomputed debt");
        assertEq(m.core.position(m.id, BORROWER).borrowShares, 0, "debt fully closed");
        assertEq(m.core.position(m.id, BORROWER).collateral, 0, "no collateral left in the market");
        assertEq(m.collateralToken.balanceOf(BORROWER), collateral, "collateral back in the borrower's wallet");
    }

    /// @dev 5. The lender redeems every share. Principal comes back (minus at most 1 wei of share rounding),
    ///      plus whatever interest pre-existing market debt accrued over the activation warp.
    function _lenderExits(uint256 depositAssets, uint256 shares) internal {
        uint256 expectedAssets = m.vault.previewRedeem(shares);
        require(_freeLiquidity(m) >= expectedAssets, "HappyPath: market lacks liquidity for the lender's exit");

        vm.prank(LENDER);
        uint256 redeemed = m.vault.redeem(shares, LENDER, LENDER);

        assertEq(redeemed, expectedAssets, "redeemed assets match the vault's preview");
        assertGe(redeemed, depositAssets - 1, "principal back (1 wei share rounding), plus any accrued interest");
        assertEq(m.vault.balanceOf(LENDER), 0, "no shares left behind");
    }

    // ---
    // HELPERS
    // ---

    /// @dev Stake `ethAmount` through the real Lido contracts (submit -> stETH -> wrap) and return the
    ///      resulting wstETH, left in `user`'s wallet.
    function _stakeToWstEth(address user, uint256 ethAmount) internal returns (uint256 wstEthAmount) {
        IStETH stEth = IStETH(_ext("stEth"));

        vm.deal(user, ethAmount);
        vm.startPrank(user);
        stEth.submit{value: ethAmount}(address(0));
        uint256 stEthAmount = stEth.balanceOf(user);
        stEth.approve(address(m.collateralToken), stEthAmount);
        wstEthAmount = IWstETH(address(m.collateralToken)).wrap(stEthAmount);
        vm.stopPrank();
    }
}
