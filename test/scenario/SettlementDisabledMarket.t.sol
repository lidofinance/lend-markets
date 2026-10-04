// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {ILidoLendERC4626} from "../../src/interfaces/ILidoLendERC4626.sol";
import {ILidoLendMarketController} from "../../src/interfaces/ILidoLendMarketController.sol";
import {SettlementSlice} from "../../src/types/SettlementTypes.sol";

import {LidoLendSetup} from "../setup/LidoLendSetup.sol";
import {Market} from "../setup/Types.sol";
import {MarketActions} from "../setup/MarketActions.sol";
import {MockERC20} from "../setup/Mocks.sol";

/// @notice Lender exits on a market created with settlement switched off. The choice is fixed at market
///         creation and has no setter, so a deployment that launches this way keeps it forever — yet every
///         other settlement suite runs with settlement enabled.
///
///         Two things this pins that are easy to get wrong. The core rejects a settlement outright, but the
///         vault's fallback exit only reaches the core when the liquid leg falls short AND the queue root
///         quotes a positive cut: a request covered by free liquidity returns normally without ever touching
///         settlement, and a root that quotes nothing breaks the loop and keeps the liquid leg. And the
///         controller's quoting views never read the flag, so they keep returning cuts the core will refuse.
contract SettlementDisabledMarketTest is LidoLendSetup {
    using MarketActions for Market;

    /// @dev The core's `require` message for a settlement on a market that never enabled it.
    bytes internal constant SETTLEMENT_DISABLED = bytes("settlement disabled");

    address internal vaultLender;
    address internal coreLender;
    address internal borrower;

    function setUp() public {
        MockERC20 loan = new MockERC20("Loan", "LOAN", 18);
        MockERC20 collateral = new MockERC20("Collateral", "COLL", 18);

        DeployConfig memory cfg = _defaultConfig(address(loan), address(collateral), address(collateral));
        cfg.enableSettlement = false; // the whole point of this suite
        _deployProtocol(cfg);

        Market storage m = _m();
        assertFalse(m.core.isSettlementEnabled(m.id), "setup: settlement must be disabled on this market");

        vaultLender = _actor("vaultLender");
        _fund(m.loanToken, vaultLender, 1000 ether);

        coreLender = _actor("coreLender");
        _fund(m.loanToken, coreLender, 1000 ether);

        borrower = _actor("borrower");
        _fund(m.collateralToken, borrower, 100 ether);
    }

    function _m() internal view returns (Market storage) {
        return protocol.markets[0];
    }

    /// @dev Seeds a vault lender and a borrower who has opted into a personal settlement LTV, so the
    ///      controller quotes a positive cut and the core is actually reached.
    function _seedSettleableBorrower() internal returns (uint256 lenderShares) {
        Market storage m = _m();
        lenderShares = m.vaultDeposit(vaultLender, 1000 ether);

        m.supplyCollateral(borrower, 100 ether);
        m.activateCollateral();
        uint256 maxBorrow = ((100 ether * oraclePrice) / 1e36) * 80 / 100;
        m.borrow(borrower, (maxBorrow * 9900) / 10_000);

        m.setSettlementLtv(borrower, 0.5e18);
        (uint256 ltv, uint256 sliceAssets) = m.controller.settlementLtv(borrower);
        assertEq(ltv, 0.5e18, "setup: personal LTV stored");
        assertGt(sliceAssets, 0, "setup: controller must quote a positive cut");
    }

    // ── The core refuses every settlement ──

    function testRevert_VaultSettle_SettlementDisabled() public {
        Market storage m = _m();
        uint256 shares = _seedSettleableBorrower();

        address[] memory borrowers = new address[](1);
        borrowers[0] = borrower;

        vm.prank(vaultLender);
        vm.expectRevert(SETTLEMENT_DISABLED);
        m.vault.settle(shares / 2, borrowers, vaultLender, vaultLender);
    }

    function testRevert_CoreSettle_SettlementDisabled() public {
        Market storage m = _m();
        _seedSettleableBorrower();
        m.coreSupply(coreLender, 500 ether);

        uint256 cutShares = m.core.position(m.id, borrower).borrowShares / 10;
        assertGt(cutShares, 0, "setup: borrower must carry debt to cut");

        vm.prank(coreLender);
        vm.expectRevert(SETTLEMENT_DISABLED);
        m.core.settle(m.params, cutShares, coreLender, borrower, coreLender);
    }

    // ── Fallback exit: only the settle leg is blocked ──

    /// @dev Free liquidity covers the whole request, so the settle leg is never entered and the disabled
    ///      flag is irrelevant. The oracle is not read on this path either.
    function test_FallbackExitCoveredByLiquidity_SucceedsWithoutSettleLeg() public {
        Market storage m = _m();
        uint256 shares = m.vaultDeposit(vaultLender, 1000 ether);

        uint256 request = shares / 4;
        assertGe(
            m.controller.maxWithdrawableAssets(address(m.vault)),
            m.vault.previewRedeem(request),
            "setup: liquidity must cover the whole request"
        );

        (uint256 burned, uint256 loanAssets, uint256 collateralSeized, uint256 debtCanceled) =
            m.fallbackExit(vaultLender, request, vaultLender, 0);

        assertEq(burned, request, "whole request burned by the liquid leg");
        assertGt(loanAssets, 0, "liquid leg paid loan assets");
        assertEq(collateralSeized, 0, "settle leg must not run");
        assertEq(debtCanceled, 0, "settle leg must not run");
    }

    /// @dev Liquidity falls short and the root quotes a positive cut, so the core is reached and refuses.
    ///      The liquid leg is rolled back with it — there is no partial payout.
    function testRevert_FallbackExitNeedingSettleLeg_RevertsWholeCall() public {
        Market storage m = _m();
        uint256 shares = _seedSettleableBorrower();

        uint256 liquid = m.controller.maxWithdrawableAssets(address(m.vault));
        assertLt(liquid, m.vault.previewRedeem(shares), "setup: request must outgrow free liquidity");

        (address root,) = m.controller.nextSettlementBorrower(0);
        assertEq(root, borrower, "setup: borrower must be the queue root");

        uint256 loanBefore = m.loanToken.balanceOf(vaultLender);

        vm.prank(vaultLender);
        vm.expectRevert(SETTLEMENT_DISABLED);
        m.vault.fallbackExit(shares, vaultLender, vaultLender, 0);

        assertEq(m.vault.balanceOf(vaultLender), shares, "no shares burned");
        assertEq(m.loanToken.balanceOf(vaultLender), loanBefore, "liquid leg rolled back with the settle leg");
    }

    /// @dev The consequence worth knowing: with any borrower in the queue, the root policy quotes a cut even
    ///      when nobody opted into a personal settlement LTV. So on a settlement-disabled market a lender whose
    ///      request exceeds free liquidity cannot exit at all — not even partially — until borrowers repay.
    ///      The liquid leg is rolled back with the settle leg rather than paid out.
    function testRevert_FallbackExitBeyondLiquidity_LenderIsStuckUntilRepayment() public {
        Market storage m = _m();
        uint256 shares = m.vaultDeposit(vaultLender, 1000 ether);

        // A borrower drains most of the liquidity and never opts into settlement.
        m.supplyCollateral(borrower, 100 ether);
        m.activateCollateral();
        uint256 maxBorrow = ((100 ether * oraclePrice) / 1e36) * 80 / 100;
        uint256 borrowed = (maxBorrow * 9900) / 10_000;
        m.borrow(borrower, borrowed);

        uint256 liquid = m.controller.maxWithdrawableAssets(address(m.vault));
        assertLt(liquid, m.vault.previewRedeem(shares), "setup: request must outgrow free liquidity");
        assertGt(liquid, 0, "setup: some liquidity must remain, so a partial payout would be possible");

        (uint256 personalLtv,) = m.controller.settlementLtv(borrower);
        assertEq(personalLtv, 0, "setup: borrower must not have opted into a personal LTV");

        (address root, SettlementSlice memory slice) = m.controller.nextSettlementBorrower(0);
        assertEq(root, borrower, "setup: root policy still names the borrower");
        assertGt(slice.borrowShares, 0, "setup: root policy quotes a cut even with no personal opt-in");

        uint256 loanBefore = m.loanToken.balanceOf(vaultLender);

        vm.prank(vaultLender);
        vm.expectRevert(SETTLEMENT_DISABLED);
        m.vault.fallbackExit(shares, vaultLender, vaultLender, 0);

        assertEq(m.vault.balanceOf(vaultLender), shares, "no shares burned");
        assertEq(m.loanToken.balanceOf(vaultLender), loanBefore, "no partial payout: liquid leg rolled back too");

        // Repayment restores liquidity, and the same exit now completes entirely through the liquid leg.
        _fund(m.loanToken, borrower, borrowed * 2);
        m.repay(borrower, m.core.position(m.id, borrower).borrowShares);

        (uint256 burned,, uint256 collateralSeized,) = m.fallbackExit(vaultLender, shares, vaultLender, 0);
        assertEq(burned, shares, "whole request exits once liquidity returns");
        assertEq(collateralSeized, 0, "settle leg still never runs");
    }

    // ── The controller's views do not know about the flag ──

    /// @dev The controller quotes settlement cuts from its own policy state and never reads the core's
    ///      enablement flag. An integrator that trusts these views on a disabled market gets a cut the core
    ///      will refuse, so the disagreement is pinned deliberately rather than left to be discovered.
    function test_ControllerViewsStillQuote_OnDisabledMarket() public {
        Market storage m = _m();
        _seedSettleableBorrower();

        (, uint256 sliceAssets) = m.controller.settlementLtv(borrower);
        assertGt(sliceAssets, 0, "settlementLtv quotes a cut the core would refuse");

        (address root, SettlementSlice memory slice) = m.controller.nextSettlementBorrower(0);
        assertEq(root, borrower, "nextSettlementBorrower still names a root");
        assertGt(slice.borrowShares, 0, "nextSettlementBorrower still quotes a positive cut");
    }

    // ── Ordinary lender exits are untouched ──

    function test_OrdinaryWithdraw_UnaffectedBySettlementFlag() public {
        Market storage m = _m();
        m.vaultDeposit(vaultLender, 1000 ether);
        m.vaultWithdraw(vaultLender, 400 ether);
    }

    function test_CoreLenderSupplyAndWithdraw_UnaffectedBySettlementFlag() public {
        Market storage m = _m();
        m.coreSupply(coreLender, 500 ether);
        m.coreWithdraw(coreLender, 200 ether);
    }
}
