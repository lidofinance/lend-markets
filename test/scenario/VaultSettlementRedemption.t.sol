// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ORACLE_PRICE_SCALE} from "@lido-lend/src/libraries/ConstantsLib.sol";

import {ILidoLendERC4626} from "../../src/interfaces/ILidoLendERC4626.sol";
import {LidoLendSetup} from "../setup/LidoLendSetup.sol";
import {MarketActions} from "../setup/MarketActions.sol";
import {MockERC20, MockPriceOracle} from "../setup/Mocks.sol";
import {IrmKind, Market} from "../setup/Types.sol";

/// @notice Settlement receipts fit the pre-call redemption value of the shares actually burned.
contract VaultSettlementRedemptionTest is LidoLendSetup {
    using MarketActions for Market;

    struct ExitSnapshot {
        uint256 assets;
        uint256 supply;
        uint256 ownerShares;
        uint256 receiverLoan;
        uint256 receiverCollateral;
        uint256 price;
    }

    address internal owner;
    address internal receiver;
    address internal borrowerA;
    address internal borrowerB;
    uint256 internal loanUnit;

    function _loanDecimals() internal pure virtual returns (uint8) {
        return 18;
    }

    function setUp() public {
        loanUnit = 10 ** _loanDecimals();
        irmKind = IrmKind.Fixed;
        fixedBorrowRate = uint256(2e18) / 365 days;
        _initSeed();
        oraclePrice = oraclePrice * loanUnit / 1 ether;
        MockERC20 loan = new MockERC20("Loan", "LOAN", _loanDecimals());
        MockERC20 collateral = new MockERC20("Collateral", "COLL", 18);
        _deployProtocol(_defaultConfig(address(loan), address(collateral), address(collateral)));

        owner = _actor("owner");
        receiver = _actor("receiver");
        borrowerA = _actor("borrower-a");
        borrowerB = _actor("borrower-b");
        Market storage m = protocol.markets[0];
        _fund(m.loanToken, owner, 1_000 * loanUnit);
        m.vaultDeposit(owner, 1_000 * loanUnit);
        _fund(m.collateralToken, borrowerA, 1_000_000 ether);
        _fund(m.collateralToken, borrowerB, 1_000_000 ether);
        m.supplyCollateral(borrowerA, 1_000_000 ether);
        m.supplyCollateral(borrowerB, 1_000_000 ether);
        m.activateCollateral();
        m.borrow(borrowerA, 500 * loanUnit);
        m.borrow(borrowerB, 500 * loanUnit);
        m.setSettlementLtv(borrowerA, 1);
        m.setSettlementLtv(borrowerB, 1);
        // Appreciation makes omitting virtual shares observable above the core/oracle rounding loss.
        m.warpAndAccrue(2 * 365 days);
        assertGt(m.vault.previewRedeem(1 ether), 10 * loanUnit, "share price has appreciated");
    }

    function test_settle_budgetLimitedPayoutFitsRedeem() public {
        Market storage m = protocol.markets[0];
        ExitSnapshot memory before = _snapshot();
        address[] memory borrowers = _borrowers(false);
        m.settle(owner, before.ownerShares / 4, borrowers, receiver);
        _assertPayout(before);
        assertGt(m.core.position(m.id, borrowerA).borrowShares, 0, "budget stops before the borrower's full slice");
    }

    function test_settle_borrowerLimitedPayoutUsesActualBurn() public {
        Market storage m = protocol.markets[0];
        ExitSnapshot memory before = _snapshot();
        (uint256 burned,,) = m.settle(owner, before.ownerShares, _borrowers(false), receiver);
        assertLt(burned, before.ownerShares, "borrower list produces a partial fill");
        _assertPayout(before);
    }

    function test_settle_multipleBorrowersPayoutFitsRedeem() public {
        Market storage m = protocol.markets[0];
        uint256 debtABefore = m.core.position(m.id, borrowerA).borrowShares;
        uint256 debtBBefore = m.core.position(m.id, borrowerB).borrowShares;
        ExitSnapshot memory before = _snapshot();
        m.settle(owner, before.ownerShares * 3 / 4, _borrowers(true), receiver);
        assertLt(m.core.position(m.id, borrowerA).borrowShares, debtABefore, "first borrower cut");
        assertLt(m.core.position(m.id, borrowerB).borrowShares, debtBBefore, "second borrower cut");
        _assertPayout(before);
    }

    function test_fallbackExit_illiquidPayoutFitsRedeem() public {
        Market storage m = protocol.markets[0];
        ExitSnapshot memory before = _snapshot();
        (, uint256 loanAssets,,) = m.fallbackExit(owner, before.ownerShares * 3 / 4, receiver, 2);
        assertEq(loanAssets, 0, "fully borrowed market has no liquid leg");
        _assertPayout(before);
    }

    function test_fallbackExit_mixedPartialPayoutUsesWholeCallQuote() public {
        Market storage m = protocol.markets[0];
        _fund(m.loanToken, borrowerB, 100_000 * loanUnit);
        m.repay(borrowerB, m.core.position(m.id, borrowerB).borrowShares / 4);
        ExitSnapshot memory before = _snapshot();
        (uint256 burned, uint256 loanAssets, uint256 collateralSeized,) =
            m.fallbackExit(owner, before.ownerShares, receiver, 1);
        assertGt(loanAssets, 0, "liquid leg paid loan tokens");
        assertGt(collateralSeized, 0, "settlement leg paid collateral");
        assertLt(burned, before.ownerShares, "iteration cap produces a partial exit");
        _assertPayout(before);
    }

    function testFuzz_settle_payoutFitsRedeem(uint256 shareSeed, bool bothBorrowers) public {
        Market storage m = protocol.markets[0];
        ExitSnapshot memory before = _snapshot();
        uint256 requested = bound(shareSeed, before.ownerShares / 100, before.ownerShares);
        m.settle(owner, requested, _borrowers(bothBorrowers), receiver);
        _assertPayout(before);
    }

    function _snapshot() internal view returns (ExitSnapshot memory state) {
        Market storage m = protocol.markets[0];
        state = ExitSnapshot({
            assets: m.vault.totalAssets(),
            supply: m.vault.totalSupply(),
            ownerShares: m.vault.balanceOf(owner),
            receiverLoan: m.loanToken.balanceOf(receiver),
            receiverCollateral: m.collateralToken.balanceOf(receiver),
            price: m.oracle.price()
        });
    }

    function _assertPayout(ExitSnapshot memory before) internal view {
        Market storage m = protocol.markets[0];
        uint256 actualBurn = before.ownerShares - m.vault.balanceOf(owner);
        assertGt(actualBurn, 0, "a real exit was exercised");
        uint256 receivedLoan = m.loanToken.balanceOf(receiver) - before.receiverLoan;
        uint256 receivedCollateral = m.collateralToken.balanceOf(receiver) - before.receiverCollateral;
        uint256 virtualShares = 10 ** (18 - _loanDecimals());
        uint256 redeem = Math.mulDiv(actualBurn, before.assets + 1, before.supply + virtualShares);
        // Compare the exact oracle fraction without rounding a sub-unit overpayment away.
        assertLe(receivedLoan, redeem, "loan payout fits redemption");
        assertLe(
            receivedCollateral * before.price, (redeem - receivedLoan) * ORACLE_PRICE_SCALE, "payout fits redemption"
        );
    }

    function _borrowers(bool both) internal view returns (address[] memory borrowers) {
        borrowers = new address[](both ? 2 : 1);
        borrowers[0] = borrowerA;
        if (both) borrowers[1] = borrowerB;
    }
}

contract VaultSettlementRedemptionSixDecimalsTest is VaultSettlementRedemptionTest {
    function _loanDecimals() internal pure override returns (uint8) {
        return 6;
    }
}

/// @notice Dust boundaries after realized losses, with another supplier sharing the same core market.
contract VaultSettlementLossBoundaryTest is LidoLendSetup {
    using MarketActions for Market;

    address internal constant OWNER = address(0x9001);
    address internal constant DIRECT = address(0x9002);
    address internal constant BAD_BORROWER = address(0x9003);
    address internal constant GOOD_BORROWER = address(0x9004);
    address internal constant KEEPER = address(0x9005);
    address internal constant CALLER = address(0x9006);
    address internal constant RECEIVER = address(0x9007);

    function setUp() public {
        irmKind = IrmKind.Fixed;
        fixedBorrowRate = 0;
        MockERC20 loan = new MockERC20("Loan", "LOAN", 18);
        MockERC20 collateral = new MockERC20("Collateral", "COLL", 18);
        DeployConfig memory cfg = _defaultConfig(address(loan), address(collateral), address(collateral));
        cfg.activation.minDepositAmount = 0;
        cfg.activation.minActivationAmount = 1;
        _deployProtocol(cfg);
    }

    function testRevert_fallbackExit_zeroBudgetRollsBackLiquidLeg() public {
        _seedLoss(2, 1, 2);
        Market storage m = protocol.markets[0];
        _fund(m.loanToken, OWNER, 2);
        m.vaultDeposit(OWNER, 2);
        MockPriceOracle(address(m.oracle)).setPrice(1e35);
        m.borrow(GOOD_BORROWER, 2);
        assertEq(m.vault.totalAssets(), 3, "three raw loan units of managed backing");
        assertEq(m.vault.totalSupply(), 5, "five raw vault shares");
        assertEq(m.vault.previewRedeem(3), 2, "request needs settlement after one liquid unit");
        assertEq(m.controller.maxWithdrawableAssets(address(m.vault)), 1, "one liquid unit");
        uint256 managedBefore = m.vault.managedSupplyShares();
        uint256 coreLoanBefore = m.loanToken.balanceOf(address(m.core));
        vm.prank(OWNER);
        m.vault.approve(CALLER, 3);
        vm.expectRevert(ILidoLendERC4626.ZeroMorphoSupplyShares.selector);
        vm.prank(CALLER);
        m.vault.fallbackExit(3, RECEIVER, OWNER, 1);
        assertEq(m.vault.balanceOf(OWNER), 5, "liquid share burn rolled back");
        assertEq(m.vault.allowance(OWNER, CALLER), 3, "allowance spend rolled back");
        assertEq(m.vault.managedSupplyShares(), managedBefore, "core withdrawal rolled back");
        assertEq(m.loanToken.balanceOf(address(m.core)), coreLoanBefore, "core retained the loan tokens");
        assertEq(m.loanToken.balanceOf(RECEIVER), 0, "receiver retained no provisional payout");
    }

    function _seedLoss(uint256 vaultDeposit, uint256 directSupply, uint256 badBorrow) internal {
        Market storage m = protocol.markets[0];
        _fund(m.loanToken, OWNER, vaultDeposit);
        m.vaultDeposit(OWNER, vaultDeposit);
        _fund(m.loanToken, DIRECT, directSupply);
        vm.startPrank(DIRECT);
        m.loanToken.approve(address(m.core), directSupply);
        m.core.supply(m.params, directSupply, 0, DIRECT, "");
        vm.stopPrank();
        _fund(m.collateralToken, BAD_BORROWER, 100);
        _fund(m.collateralToken, GOOD_BORROWER, 100);
        m.supplyCollateral(BAD_BORROWER, 100);
        m.supplyCollateral(GOOD_BORROWER, 100);
        m.activateCollateral();
        m.borrow(BAD_BORROWER, badBorrow);
        m.borrow(GOOD_BORROWER, 1);
        MockPriceOracle(address(m.oracle)).setPrice(1e34);
        _fund(m.loanToken, KEEPER, 1);
        (, uint256 repaid) = m.liquidateBadDebt(KEEPER, BAD_BORROWER, 100, 0);
        assertEq(repaid, 1, "one unit repaid; the rest is socialized");
    }
}
