// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {ILidoLend, ILidoLendBase} from "@lido-lend/src/interfaces/ILidoLend.sol";
import {Id, MarketParams, Position, Market as MorphoMarket} from "@lido-lend/src/interfaces/IMorpho.sol";
import {SharesMathLib} from "@lido-lend/src/libraries/SharesMathLib.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {ILidoLendMarketController} from "../../src/interfaces/ILidoLendMarketController.sol";
import {ILidoLendERC4626} from "../../src/interfaces/ILidoLendERC4626.sol";
import {SettlementConfig} from "../../src/types/SettlementTypes.sol";
import {LidoLendDeployer} from "../../script/lib/LidoLendDeployer.sol";
import {CollateralActivationConfig} from "../../src/types/CollateralActivationTypes.sol";

interface IOracle {
    function price() external view returns (uint256);
}

contract FixedPriceOracle is IOracle {
    uint256 private immutable PRICE;

    constructor(uint256 price_) {
        PRICE = price_;
    }

    function price() external view returns (uint256) {
        return PRICE;
    }
}

contract MockToken is ERC20 {
    constructor(string memory n, string memory s) ERC20(n, s) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

interface IVault {
    function deposit(uint256 assets, address receiver) external returns (uint256);
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function previewRedeem(uint256 shares) external view returns (uint256);
    function previewWithdraw(uint256 assets) external view returns (uint256);
    function maxRedeem(address owner) external view returns (uint256);
    function maxWithdraw(address owner) external view returns (uint256);
    function fallbackExit(uint256 shares, address receiver, address owner, uint256 maxIterations)
        external
        returns (uint256 sharesBurned, uint256 loanAssets, uint256 collateralSeized, uint256 debtCanceled);
    function settle(uint256 shares, address[] calldata borrowers, address receiver, address owner)
        external
        returns (uint256 sharesBurned, uint256 loanAssets, uint256 collateralSeized, uint256 debtCanceled);
}

/// @notice The ERC4626 lender-exit waterfall against the core's borrow-anchored `settle`,
///         exercising both settle anchors the vault picks. With a `fullCutBelowCollateral` above the root's
///         collateral the queue opens a full cut, so the vault closes the riskiest borrower borrow-anchored
///         when its budget covers the quoted cost; smaller budgets force supply-anchored partial cuts. The vault is
///         the sole supplier. Targeted settlement is personal-LTV-gated and uses the request's gross supply claim.
contract SettleVaultDualAnchorTest is Test, LidoLendDeployer {
    uint256 internal constant LLTV = 0.945e18;
    uint256 internal constant PRICE = 1.2e36;

    address internal constant LENDER = address(0x9000);
    address internal constant BORROWER = address(0xB0B);
    address internal constant FILLER = address(0xF111);
    address internal constant THIRD = address(0x333);
    address internal constant RECEIVER = address(0x5EED);

    uint256 internal constant DEPOSIT = 200e18; // vault supply
    uint256 internal constant B_COLLATERAL = 50e18; // BORROWER: high LTV, the queue root
    uint256 internal constant B_BORROW = 47e18;
    uint256 internal constant F_COLLATERAL = 200e18; // FILLER: low LTV, carries slack so closing BORROWER fits
    uint256 internal constant F_BORROW = 80e18;
    uint256 internal constant T_COLLATERAL = 100e18;
    uint256 internal constant T_BORROW = 30e18;

    MockToken internal loan;
    MockToken internal collateral;
    ILidoLend internal core;
    ILidoLendMarketController internal controller;
    address internal vault;
    MarketParams internal params;
    Id internal id;

    struct TwoStepQuote {
        uint256 firstSupplyBurn;
        uint256 secondSupplyBurn;
        uint256 thirdBorrowShares;
        uint256 requestShares;
        uint256 quotedSettlementBudget;
        uint256 previousSettlementBudget;
    }

    function setUp() public {
        loan = new MockToken("Wrapped Ether", "WETH");
        collateral = new MockToken("Wrapped stETH", "wstETH");

        address[] memory guardians = new address[](1);
        guardians[0] = address(this);

        Deployed memory d = _deployForkStack(
            DeployConfig({
                admin: address(this),
                loanToken: address(loan),
                collateralToken: address(collateral),
                oracleSource: address(collateral),
                lltv: LLTV,
                enableSettlement: true,
                activation: CollateralActivationConfig({
                    minActivationDelay: 10 minutes,
                    maxActivationDelay: 2 hours,
                    activatingLockAmount: 0,
                    activatingLockDuration: 0,
                    maxDelayInflow: 100_000 ether,
                    minActivationAmount: 1e18,
                    maxGuardiansQuorumDelay: 0,
                    delayPerStrike: 0,
                    delayPerSuspect: 0
                }),
                settlementConfig: SettlementConfig({
                    sliceFloorBps: 100, sliceFloorAssets: 0, fullCutBelowCollateral: 0, ltvStepBps: 100
                }),
                guardians: guardians,
                quorum: 1,
                suspectWindow: 0,
                vaultName: "Lido WETH Vault",
                vaultSymbol: "lidoWETH"
            })
        );

        core = ILidoLend(d.core);
        controller = ILidoLendMarketController(d.controllerProxy);
        vault = d.vault;
        params = d.params;
        id = d.marketId;

        controller.grantRole(controller.MANAGER_ROLE(), address(this));

        // Sole lender funds the book through the vault.
        loan.mint(LENDER, DEPOSIT);
        vm.startPrank(LENDER);
        loan.approve(vault, type(uint256).max);
        IVault(vault).deposit(DEPOSIT, LENDER);
        vm.stopPrank();

        _seedBorrower(BORROWER, B_COLLATERAL);
        _seedBorrower(FILLER, F_COLLATERAL);
        _seedBorrower(THIRD, T_COLLATERAL);

        vm.warp(block.timestamp + 3 hours); // past maxActivationDelay -> collateral active

        vm.prank(BORROWER);
        core.borrow(params, B_BORROW, 0, BORROWER, BORROWER);
        vm.prank(FILLER);
        core.borrow(params, F_BORROW, 0, FILLER, FILLER);
        vm.prank(THIRD);
        core.borrow(params, T_BORROW, 0, THIRD, THIRD);
    }

    function _seedBorrower(address who, uint256 amount) internal {
        collateral.mint(who, amount);
        vm.startPrank(who);
        collateral.approve(address(core), type(uint256).max);
        core.supplyCollateral(params, amount, who, "");
        vm.stopPrank();
    }

    function _setFullCut() internal {
        // Above the root's collateral, so any slice strands "dust" and the queue lifts it to a whole close.
        controller.setSettlementConfig(
            SettlementConfig({sliceFloorBps: 100, sliceFloorAssets: 0, fullCutBelowCollateral: 100e18, ltvStepBps: 100})
        );
    }

    function _setWholeDebtSlice() internal {
        controller.setSettlementConfig(
            SettlementConfig({
                sliceFloorBps: 10_000, sliceFloorAssets: 0, fullCutBelowCollateral: 100e18, ltvStepBps: 0
            })
        );
    }

    function _setPersonalSettlementLtv(address borrower, uint256 ltv) internal {
        vm.prank(borrower);
        controller.setSettlementLtv(ltv);
    }

    function _repayAll(address borrower) internal {
        uint256 borrowShares = core.position(id, borrower).borrowShares;
        if (borrowShares == 0) return;

        loan.mint(borrower, type(uint128).max);
        vm.startPrank(borrower);
        loan.approve(address(core), type(uint256).max);
        core.repay(params, 0, borrowShares, borrower, "");
        vm.stopPrank();
    }

    function _repayAllButOneDebtAsset(address borrower) internal returns (uint256 dustDebtAssets) {
        uint256 totalBorrowAssets = core.market(id).totalBorrowAssets;
        assertGt(totalBorrowAssets, 1, "market has enough debt to leave dust");

        loan.mint(borrower, type(uint128).max);
        vm.startPrank(borrower);
        loan.approve(address(core), type(uint256).max);
        core.repay(params, totalBorrowAssets - 1, 0, borrower, "");
        vm.stopPrank();

        MorphoMarket memory mk = core.market(id);
        dustDebtAssets = SharesMathLib.toAssetsUp(
            core.position(id, borrower).borrowShares, mk.totalBorrowAssets, mk.totalBorrowShares
        );
        assertEq(mk.totalBorrowAssets, 1, "market left with one debt asset");
        assertGt(core.position(id, borrower).borrowShares, 0, "borrower left with borrow shares");
        assertEq(dustDebtAssets * 1e36 / PRICE, 0, "dust debt seizes zero collateral");
    }

    /// @dev After the liquid leg drains market free liquidity, the queue grants the root-policy full cut. The
    ///      remaining exit budget covers its cost, so the vault closes the riskiest borrower borrow-anchored.
    function test_fallbackExit_closesRootBorrowAnchored() public {
        _setFullCut();

        assertGt(core.position(id, BORROWER).borrowShares, 0, "borrower starts with debt");
        (address root,,,) = controller.nextSettlementBorrower();
        assertEq(root, BORROWER, "highest-LTV borrower is the queue root");

        uint256 shares = IVault(vault).balanceOf(LENDER);
        vm.prank(LENDER);
        (,, uint256 collateralSeized, uint256 debtCanceled) = IVault(vault).fallbackExit(shares, RECEIVER, LENDER, 0);

        assertEq(core.position(id, BORROWER).borrowShares, 0, "root closed to zero (borrow-anchored)");
        assertGe(debtCanceled, B_BORROW, "at least the root's debt cancelled");
        assertEq(collateral.balanceOf(RECEIVER), collateralSeized, "receiver got the seized collateral");
        assertGt(collateralSeized, 0, "collateral seized");
    }

    /// @dev A targeted personal-LTV full close whose quoted supply cost is one share above the request's gross
    ///      settlement budget is downgraded to an exact-budget supply-anchored partial cut.
    function test_settle_budgetBelowFullCloseFallsBackToPartial() public {
        // Leave BORROWER as the only debtor so the post-cut remainder is unambiguous.
        uint256 fillerShares = core.position(id, FILLER).borrowShares;
        uint256 thirdShares = core.position(id, THIRD).borrowShares;
        loan.mint(FILLER, F_BORROW * 2);
        loan.mint(THIRD, T_BORROW * 2);
        vm.startPrank(FILLER);
        loan.approve(address(core), type(uint256).max);
        core.repay(params, 0, fillerShares, FILLER, "");
        vm.stopPrank();
        vm.startPrank(THIRD);
        loan.approve(address(core), type(uint256).max);
        core.repay(params, 0, thirdShares, THIRD, "");
        vm.stopPrank();

        vm.warp(block.timestamp + 30 days); // accrue interest so the totals are not round
        core.accrueInterest(params);

        _setFullCut();
        _setPersonalSettlementLtv(BORROWER, 1);

        address[] memory borrowers = new address[](1);
        borrowers[0] = BORROWER;

        uint256 debtSharesBefore = core.position(id, BORROWER).borrowShares;
        uint256 vaultSupplySharesBefore = core.position(id, vault).supplyShares;
        uint256 vaultSharesBefore = IVault(vault).balanceOf(LENDER);
        // budget, debt canceled, borrow shares canceled, remaining debt assets.
        uint256[4] memory expected;
        uint256 shares;
        {
            MorphoMarket memory mk = core.market(id);
            (uint256 fullCloseSupplyShares,, uint256 remainingBorrowShares) = controller.settlementFor(BORROWER);
            assertEq(remainingBorrowShares, 0, "controller quotes a full close");

            shares = Math.mulDiv(fullCloseSupplyShares - 1, vaultSharesBefore, vaultSupplySharesBefore);
            expected[0] = Math.mulDiv(vaultSupplySharesBefore, shares, vaultSharesBefore);
            assertGt(expected[0], 0, "request has a positive gross settlement budget");
            assertLt(expected[0], fullCloseSupplyShares, "gross request budget cannot afford the full close");

            expected[1] = SharesMathLib.toAssetsDown(expected[0], mk.totalSupplyAssets, mk.totalSupplyShares);
            expected[2] = SharesMathLib.toSharesUp(expected[1], mk.totalBorrowAssets, mk.totalBorrowShares);
            expected[3] = SharesMathLib.toAssetsUp(
                debtSharesBefore - expected[2], mk.totalBorrowAssets - expected[1], mk.totalBorrowShares - expected[2]
            );
        }

        vm.prank(LENDER);
        (uint256 sharesBurned,, uint256 collateralSeized, uint256 debtCanceled) =
            IVault(vault).settle(shares, borrowers, RECEIVER, LENDER);

        uint256 debtSharesAfter = core.position(id, BORROWER).borrowShares;
        MorphoMarket memory mkAfter = core.market(id);
        uint256 debtAssetsAfter =
            SharesMathLib.toAssetsUp(debtSharesAfter, mkAfter.totalBorrowAssets, mkAfter.totalBorrowShares);
        assertGt(sharesBurned, 0, "some vault shares burned");
        assertGt(collateralSeized, 0, "collateral seized");
        assertGt(debtCanceled, 0, "some debt cancelled");
        assertEq(
            vaultSupplySharesBefore - core.position(id, vault).supplyShares,
            expected[0],
            "exact gross request budget consumed"
        );
        assertEq(debtCanceled, expected[1], "supply-anchor debt conversion");
        assertEq(debtSharesBefore - debtSharesAfter, expected[2], "supply-anchor borrow-share conversion");
        assertLt(debtSharesAfter, debtSharesBefore, "borrower debt reduced");
        assertGt(debtSharesAfter, 0, "borrower not fully closed");
        assertEq(debtAssetsAfter, expected[3], "borrower keeps only the independently modeled rounded remainder");
    }

    /// @dev A one-asset-wei debt against a normal collateral balance has an LTV below the minimum positive WAD target.
    ///      Even after setting the minimum personal LTV, targeted settlement has no positive slice and reverts
    ///      `NothingSettled`. The queue-driven fallback dust path is covered separately.
    function test_settle_dustBelowMinimumPersonalLtvRevertsNothingSettled() public {
        _repayAll(FILLER);
        _repayAll(THIRD);
        uint256 dustDebtAssets = _repayAllButOneDebtAsset(BORROWER);
        assertLe(dustDebtAssets, 1, "debt is actual dust");

        _setWholeDebtSlice();
        _setPersonalSettlementLtv(BORROWER, 1);

        (uint256 personalLtv, uint256 personalSlice) = controller.settlementLtv(BORROWER);
        assertEq(personalLtv, 1, "minimum positive personal LTV stored");
        assertEq(personalSlice, 0, "dust LTV is below the minimum representable target");

        address[] memory borrowers = new address[](1);
        borrowers[0] = BORROWER;
        uint256 shares = IVault(vault).balanceOf(LENDER);

        vm.prank(LENDER);
        vm.expectRevert(ILidoLendERC4626.NothingSettled.selector);
        IVault(vault).settle(shares, borrowers, RECEIVER, LENDER);

        _repayAll(BORROWER);
        assertEq(core.position(id, BORROWER).borrowShares, 0, "dust borrower repaid");

        vm.expectRevert(ILidoLendERC4626.NothingSettled.selector);
        vm.prank(LENDER);
        IVault(vault).settle(shares, borrowers, RECEIVER, LENDER);
    }

    /// @dev Targeted `settle` can close several opted-in borrowers to zero when every requested full close fits
    ///      the remaining gross request budget. This is the normal borrow-anchored path; no supply-anchored
    ///      downgrade is expected for either borrower.
    function test_settle_multipleBorrowersFullCloseToZero() public {
        controller.setSettlementConfig(
            SettlementConfig({sliceFloorBps: 100, sliceFloorAssets: 0, fullCutBelowCollateral: 300e18, ltvStepBps: 100})
        );
        _setPersonalSettlementLtv(BORROWER, 1);
        _setPersonalSettlementLtv(FILLER, 1);

        address[] memory borrowers = new address[](2);
        borrowers[0] = BORROWER;
        borrowers[1] = FILLER;

        assertGt(core.position(id, BORROWER).borrowShares, 0, "borrower starts with debt");
        assertGt(core.position(id, FILLER).borrowShares, 0, "filler starts with debt");

        uint256 shares = IVault(vault).balanceOf(LENDER);
        vm.prank(LENDER);
        (uint256 sharesBurned,, uint256 collateralSeized, uint256 debtCanceled) =
            IVault(vault).settle(shares, borrowers, RECEIVER, LENDER);

        uint256 remainingVaultSupplyShares = core.position(id, vault).supplyShares;
        uint256 remainingVaultShares = IVault(vault).balanceOf(LENDER);

        assertGt(sharesBurned, 0, "vault shares burned");
        assertGt(collateralSeized, 0, "collateral seized");
        assertEq(debtCanceled, B_BORROW + F_BORROW, "both debts cancelled");
        assertEq(core.position(id, BORROWER).borrowShares, 0, "borrower closed to zero");
        assertEq(core.position(id, FILLER).borrowShares, 0, "filler closed to zero");
        assertGt(remainingVaultSupplyShares, 0, "idle supply remains in the vault");
        assertGt(remainingVaultShares, 0, "lender keeps shares for idle supply");
        assertEq(collateral.balanceOf(RECEIVER), collateralSeized, "receiver got the seized collateral");
    }

    /// @dev Same as the two-borrower case, but with an additional listed borrower. This makes sure the normal
    ///      full-close path is not accidentally special-cased to one or two borrowers.
    function test_settle_threeBorrowersFullCloseToZero() public {
        controller.setSettlementConfig(
            SettlementConfig({sliceFloorBps: 100, sliceFloorAssets: 0, fullCutBelowCollateral: 300e18, ltvStepBps: 100})
        );
        _setPersonalSettlementLtv(BORROWER, 1);
        _setPersonalSettlementLtv(FILLER, 1);
        _setPersonalSettlementLtv(THIRD, 1);

        address[] memory borrowers = new address[](3);
        borrowers[0] = BORROWER;
        borrowers[1] = FILLER;
        borrowers[2] = THIRD;

        uint256 shares = IVault(vault).balanceOf(LENDER);

        vm.prank(LENDER);
        (uint256 sharesBurned,, uint256 collateralSeized, uint256 debtCanceled) =
            IVault(vault).settle(shares, borrowers, RECEIVER, LENDER);

        assertGt(sharesBurned, 0, "vault shares burned");
        assertGt(collateralSeized, 0, "collateral seized");
        assertEq(debtCanceled, B_BORROW + F_BORROW + T_BORROW, "whole book debt cancelled");
        assertEq(core.market(id).totalBorrowAssets, 0, "market debt closed to zero");
        assertEq(core.position(id, BORROWER).borrowShares, 0, "borrower closed to zero");
        assertEq(core.position(id, FILLER).borrowShares, 0, "filler closed to zero");
        assertEq(core.position(id, THIRD).borrowShares, 0, "third borrower closed to zero");
        assertGt(core.position(id, vault).supplyShares, 0, "idle supply remains in the vault");
        assertGt(IVault(vault).balanceOf(LENDER), 0, "lender keeps shares for idle supply");
        assertEq(collateral.balanceOf(RECEIVER), collateralSeized, "receiver got the seized collateral");
    }

    /// @dev With no full-cut lever the queue only grants the gradual policy slice, so a single waterfall
    ///      iteration cuts the root supply-anchored: its debt shrinks but the position is not closed. (Left
    ///      uncapped the loop would keep cutting the same root down to zero, so the iteration is bounded to one
    ///      to isolate the partial cut.)
    function test_fallbackExit_partialCutSupplyAnchored() public {
        // Default config (fullCutBelowCollateral = 0): no slice is ever lifted to a full close.
        uint256 rootDebtBefore = core.position(id, BORROWER).borrowShares;

        uint256 shares = IVault(vault).balanceOf(LENDER);
        vm.prank(LENDER);
        (,,, uint256 debtCanceled) = IVault(vault).fallbackExit(shares, RECEIVER, LENDER, 1);

        uint256 rootDebtAfter = core.position(id, BORROWER).borrowShares;
        assertGt(debtCanceled, 0, "some debt cancelled");
        assertLt(rootDebtAfter, rootDebtBefore, "root debt reduced");
        assertGt(rootDebtAfter, 0, "root not closed (supply-anchored partial)");
    }

    /// @dev A full-close-flagged root costing more supply than the exit's budget is downgraded to a supply-
    ///      anchored partial at budget: the root keeps debt instead of being closed at the other holders'
    ///      expense. Without the budget gate the close fires unconditionally and over-burns the shared supply.
    function test_fallbackExit_unaffordableFullCloseFallsBackToPartial() public {
        _setFullCut(); // root is in full-close mode

        (address root,,,) = controller.nextSettlementBorrower();
        assertEq(root, BORROWER, "highest-LTV borrower is the queue root");
        uint256 rootDebtBefore = core.position(id, BORROWER).borrowShares;

        // Exit a quarter of the position: the free-liquidity redeem leg consumes most of it, leaving a settle budget
        // smaller than the root's whole-debt close cost, so the full close is unaffordable.
        uint256 shares = IVault(vault).balanceOf(LENDER) / 4;
        vm.prank(LENDER);
        (,,, uint256 debtCanceled) = IVault(vault).fallbackExit(shares, RECEIVER, LENDER, 0);

        uint256 rootDebtAfter = core.position(id, BORROWER).borrowShares;
        assertGt(debtCanceled, 0, "some debt cancelled");
        assertLt(rootDebtAfter, rootDebtBefore, "root debt reduced");
        assertGt(rootDebtAfter, 0, "root NOT closed: unaffordable full close fell back to a partial");
    }

    /// @dev The closest public budget above `q1 + q2` admits THIRD's borrow-anchored full close after FILLER's
    ///      supply-anchored partial. The core's non-round full-close burn equals the controller quote and fits the
    ///      live remaining budget.
    function test_fallbackExit_budgetAboveSecondFullCloseUsesBorrowAnchor() public {
        TwoStepQuote memory quote = _prepareTwoStepFallbackExit();
        uint256 targetSettlementBudget = quote.firstSupplyBurn + quote.secondSupplyBurn;

        uint256 fillerDebtBefore = core.position(id, FILLER).borrowShares;
        assertLt(quote.previousSettlementBudget, targetSettlementBudget, "one raw share less is below the borrow close");
        assertGe(quote.quotedSettlementBudget, targetSettlementBudget, "chosen request can afford the borrow close");

        vm.expectCall(
            address(core),
            abi.encodeCall(ILidoLendBase.settle, (params, 0, quote.thirdBorrowShares, vault, THIRD, RECEIVER))
        );
        vm.recordLogs();
        vm.prank(LENDER);
        (uint256 sharesBurned,, uint256 collateralSeized, uint256 debtCanceled) =
            IVault(vault).fallbackExit(quote.requestShares, RECEIVER, LENDER, 2);

        assertGt(sharesBurned, 0, "vault shares burned");
        assertGt(collateralSeized, 0, "collateral seized");
        assertGt(debtCanceled, 0, "debt canceled");
        _assertFallbackExitTwoStepBurns(vm.getRecordedLogs(), quote, fillerDebtBefore);
        assertEq(core.position(id, THIRD).borrowShares, 0, "second borrower closed to zero");
        assertGt(core.position(id, FILLER).borrowShares, 0, "first borrower remains open");
    }

    /// @dev The closest public budget below `q1 + q2` leaves less than THIRD's quoted full-close cost after
    ///      FILLER's supply-anchored partial. The vault must therefore pass exactly the remaining budget as a second
    ///      supply-anchor: the core returns that exact burn, the checked decrement reaches zero, and THIRD stays open.
    function test_fallbackExit_budgetBelowSecondFullCloseUsesExactRemainingSupplyAnchor() public {
        TwoStepQuote memory quote = _prepareTwoStepFallbackExit();
        uint256 targetSettlementBudget = quote.firstSupplyBurn + quote.secondSupplyBurn;
        uint256 belowBudget = quote.previousSettlementBudget;

        assertGt(quote.requestShares, 1, "one raw share lower request exists");
        assertGt(belowBudget, quote.firstSupplyBurn, "below-boundary request reaches the second borrower");
        assertLt(belowBudget, targetSettlementBudget, "below-boundary request cannot afford the full close");
        uint256 secondRemainingBudget = belowBudget - quote.firstSupplyBurn;
        assertLt(secondRemainingBudget, quote.secondSupplyBurn, "second full-close quote exceeds the live budget");

        uint256 fillerDebtBefore = core.position(id, FILLER).borrowShares;
        uint256 thirdDebtBefore = core.position(id, THIRD).borrowShares;
        assertEq(thirdDebtBefore, quote.thirdBorrowShares, "full-close quote uses all second borrower shares");
        vm.expectCall(
            address(core),
            abi.encodeCall(ILidoLendBase.settle, (params, secondRemainingBudget, 0, vault, THIRD, RECEIVER))
        );
        vm.recordLogs();
        vm.prank(LENDER);
        (uint256 sharesBurned,, uint256 collateralSeized, uint256 debtCanceled) =
            IVault(vault).fallbackExit(quote.requestShares - 1, RECEIVER, LENDER, 2);

        assertGt(sharesBurned, 0, "vault shares burned");
        assertGt(collateralSeized, 0, "collateral seized");
        assertGt(debtCanceled, 0, "debt canceled");

        Vm.Log[] memory logs = vm.getRecordedLogs();
        (uint256 fillerSupplyBurn, uint256 fillerBorrowBurn) = _settleBurnsFor(logs, FILLER);
        (uint256 thirdSupplyBurn, uint256 thirdBorrowBurn) = _settleBurnsFor(logs, THIRD);
        assertEq(fillerSupplyBurn, quote.firstSupplyBurn, "first cut is supply-anchored at the quoted burn");
        assertGt(fillerBorrowBurn, 0, "first cut cancels debt");
        assertLt(fillerBorrowBurn, fillerDebtBefore, "first cut is partial");
        assertEq(thirdSupplyBurn, secondRemainingBudget, "second supply-anchor consumes the exact remaining budget");
        assertEq(fillerSupplyBurn + thirdSupplyBurn, belowBudget, "both cuts exhaust the public settlement budget");
        assertGt(thirdBorrowBurn, 0, "second cut cancels debt");
        assertLt(thirdBorrowBurn, quote.thirdBorrowShares, "second cut is partial, not the unaffordable full close");
        assertEq(
            core.position(id, THIRD).borrowShares,
            thirdDebtBefore - thirdBorrowBurn,
            "second borrower debt matches the supply-anchored cut"
        );
        assertGt(core.position(id, THIRD).borrowShares, 0, "second borrower remains open");
        assertGt(core.position(id, FILLER).borrowShares, 0, "first borrower remains open");
    }

    function _prepareTwoStepFallbackExit() internal returns (TwoStepQuote memory quote) {
        _repayAll(BORROWER);

        vm.warp(block.timestamp + 30 days);
        core.accrueInterest(params);
        _assertMarketOffParity();

        controller.setSettlementConfig(
            SettlementConfig({sliceFloorBps: 100, sliceFloorAssets: 0, fullCutBelowCollateral: 100e18, ltvStepBps: 100})
        );
        vm.prank(FILLER);
        controller.setSettlementLtv(0.2e18);

        quote = _quoteFallbackExitTwoStep();
    }

    function _assertFallbackExitTwoStepBurns(Vm.Log[] memory logs, TwoStepQuote memory quote, uint256 fillerDebtBefore)
        internal
        view
    {
        (uint256 fillerSupplyBurn, uint256 fillerBorrowBurn) = _settleBurnsFor(logs, FILLER);
        (uint256 thirdSupplyBurn, uint256 thirdBorrowBurn) = _settleBurnsFor(logs, THIRD);

        assertEq(fillerSupplyBurn, quote.firstSupplyBurn, "first cut is supply-anchored at the quoted burn");
        assertGt(fillerBorrowBurn, 0, "first cut cancels debt");
        assertLt(fillerBorrowBurn, fillerDebtBefore, "first cut is partial");
        assertEq(thirdBorrowBurn, quote.thirdBorrowShares, "second cut is borrow-anchored full close");
        assertEq(thirdSupplyBurn, quote.secondSupplyBurn, "second burn equals the quoted borrow close");
        assertLe(thirdSupplyBurn, quote.quotedSettlementBudget - fillerSupplyBurn, "second burn stays within budget");
    }

    /// @dev Queue-driven `fallbackExit` hits the same core guard when the root is only dust. Repaying the dust root
    ///      removes it from the queue, and the same fallback exit can then complete through the ordinary redeem leg.
    function test_fallbackExit_dustRootRevertsUntilDustIsRepaid() public {
        _repayAll(FILLER);
        _repayAll(THIRD);
        uint256 dustDebtAssets = _repayAllButOneDebtAsset(BORROWER);
        assertLe(dustDebtAssets, 1, "debt is actual dust");

        _setWholeDebtSlice();

        (address root,,,) = controller.nextSettlementBorrower();
        assertEq(root, BORROWER, "dust borrower is the queue root");

        uint256 shares = IVault(vault).balanceOf(LENDER);
        vm.prank(LENDER);
        vm.expectRevert(bytes("settlement slice too small"));
        IVault(vault).fallbackExit(shares, RECEIVER, LENDER, 0);

        _repayAll(BORROWER);
        assertEq(controller.settlementBorrowersCount(), 0, "dust borrower removed from queue");

        vm.prank(LENDER);
        (uint256 sharesBurned, uint256 loanAssets, uint256 collateralSeized, uint256 debtCanceled) =
            IVault(vault).fallbackExit(shares, RECEIVER, LENDER, 0);

        assertEq(sharesBurned, shares, "all shares redeemed after dust cleanup");
        assertGt(loanAssets, 0, "ordinary liquidity paid out");
        assertEq(collateralSeized, 0, "no settlement after dust cleanup");
        assertEq(debtCanceled, 0, "no debt canceled after dust cleanup");
    }

    function _assertMarketOffParity() internal view {
        MorphoMarket memory mk = core.market(id);
        assertNotEq(mk.totalSupplyAssets * 1e6, mk.totalSupplyShares, "supply share price moved off parity");
        assertNotEq(mk.totalBorrowAssets * 1e6, mk.totalBorrowShares, "borrow share price moved off parity");
    }

    function _quoteSupplyThenBorrowAnchoredBudget() internal returns (TwoStepQuote memory quote) {
        address root;
        uint256 fillerSupplyShares;
        uint256 fillerBorrowShares;
        uint256 fillerRemainingBorrowShares;
        (root, fillerSupplyShares, fillerBorrowShares, fillerRemainingBorrowShares) =
            controller.nextSettlementBorrower();
        assertEq(root, FILLER, "automatic quote is for the first queue root");
        assertGt(fillerSupplyShares, 0, "first cut has supply burn");
        assertGt(fillerBorrowShares, 0, "first cut has borrow burn");
        assertGt(fillerRemainingBorrowShares, 0, "first cut is partial");

        quote.firstSupplyBurn = fillerSupplyShares;
        uint256 snapshot = vm.snapshotState();

        vm.prank(vault);
        (,,, uint256 coreFirstSupplyBurn) = core.settle(params, fillerSupplyShares, 0, vault, FILLER, RECEIVER);
        assertEq(coreFirstSupplyBurn, quote.firstSupplyBurn, "supply-anchored core burn is exact");

        (root,,,) = controller.nextSettlementBorrower();
        assertEq(root, THIRD, "third is the second queue root");

        uint256 thirdRemainingBorrowShares;
        (root, quote.secondSupplyBurn, quote.thirdBorrowShares, thirdRemainingBorrowShares) =
            controller.nextSettlementBorrower();
        assertEq(root, THIRD, "automatic quote is for the second queue root");
        assertGt(quote.secondSupplyBurn, 0, "second cut has supply burn");
        assertGt(quote.thirdBorrowShares, 0, "second cut has borrow burn");
        assertEq(thirdRemainingBorrowShares, 0, "second cut is a full close");
        assertEq(
            quote.thirdBorrowShares, core.position(id, THIRD).borrowShares, "second cut uses all third debt shares"
        );
        _assertSecondCloseUsesNonRoundConversions(quote.thirdBorrowShares);

        assertTrue(vm.revertToState(snapshot), "snapshot revert");
    }

    function _assertSecondCloseUsesNonRoundConversions(uint256 thirdBorrowShares) internal view {
        MorphoMarket memory mk = core.market(id);
        assertNotEq(
            mulmod(thirdBorrowShares, mk.totalBorrowAssets + 1, mk.totalBorrowShares + 1e6),
            0,
            "borrow-share close conversion is non-round"
        );

        uint256 debtAssets = SharesMathLib.toAssetsUp(thirdBorrowShares, mk.totalBorrowAssets, mk.totalBorrowShares);
        assertNotEq(
            mulmod(debtAssets, mk.totalSupplyShares + 1e6, mk.totalSupplyAssets + 1),
            0,
            "supply-share burn conversion is non-round"
        );
    }

    function _quoteFallbackExitTwoStep() internal returns (TwoStepQuote memory quote) {
        uint256 snapshot = vm.snapshotState();

        uint256 liquidAssets = IVault(vault).maxWithdraw(LENDER);
        uint256 liquidShares = liquidAssets == 0 ? 0 : IVault(vault).previewWithdraw(liquidAssets);
        if (liquidAssets != 0) {
            vm.prank(LENDER);
            uint256 burned = IVault(vault).withdraw(liquidAssets, RECEIVER, LENDER);
            assertEq(burned, liquidShares, "liquid leg burn quote");
        }

        quote = _quoteSupplyThenBorrowAnchoredBudget();
        uint256 targetSettlementBudget = quote.firstSupplyBurn + quote.secondSupplyBurn;

        uint256 postLiquidVaultSupply = IVault(vault).totalSupply();
        uint256 postLiquidCoreSupplyShares = core.position(id, vault).supplyShares;
        uint256 settleLegShares =
            Math.mulDiv(targetSettlementBudget, postLiquidVaultSupply, postLiquidCoreSupplyShares, Math.Rounding.Ceil);
        quote.quotedSettlementBudget =
            Math.mulDiv(postLiquidCoreSupplyShares, settleLegShares, postLiquidVaultSupply, Math.Rounding.Floor);
        if (settleLegShares != 0) {
            quote.previousSettlementBudget = Math.mulDiv(
                postLiquidCoreSupplyShares, settleLegShares - 1, postLiquidVaultSupply, Math.Rounding.Floor
            );
        }
        quote.requestShares = liquidShares + settleLegShares;

        assertTrue(vm.revertToState(snapshot), "snapshot revert");
    }

    function _settleBurnsFor(Vm.Log[] memory logs, address borrower)
        internal
        view
        returns (uint256 supplySharesBurned, uint256 borrowSharesCanceled)
    {
        bytes32 settleSig = keccak256("Settle(bytes32,address,address,address,address,uint256,uint256,uint256,uint256)");

        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(core) || logs[i].topics[0] != settleSig) continue;
            if (address(uint160(uint256(logs[i].topics[3]))) != borrower) continue;

            (,, supplySharesBurned,, borrowSharesCanceled,) =
                abi.decode(logs[i].data, (address, address, uint256, uint256, uint256, uint256));
            return (supplySharesBurned, borrowSharesCanceled);
        }

        assertTrue(false, "core Settle event not found");
    }

    /// @dev The borrow handle `settlementSlice` returns for a partial is usable: settling borrow-anchored with it
    ///      cuts up to the slice without tripping the policy cap. The +1h accrual makes the slice's handle value
    ///      back one wei above the slice — the case the old asset-denominated cap rejected, the share cap admits.
    function test_partialBorrowAnchored_cutsUpToSlice() public {
        _setPersonalSettlementLtv(BORROWER, 0.7e18);
        vm.warp(block.timestamp + 1 hours);
        core.accrueInterest(params);
        uint256 ba = core.market(id).totalBorrowAssets;
        uint256 bs = core.market(id).totalBorrowShares;
        uint256 slice = controller.positionOf(BORROWER).slice;
        uint256 handle = SharesMathLib.toSharesUp(slice, ba, bs);
        assertGt(SharesMathLib.toAssetsUp(handle, ba, bs), slice, "handle values back above the slice (rejected case)");

        uint256 debtBefore = core.position(id, BORROWER).borrowShares;
        vm.prank(vault);
        (, uint256 debtCanceled,,) = core.settle(params, 0, handle, vault, BORROWER, RECEIVER);

        assertEq(debtBefore - core.position(id, BORROWER).borrowShares, handle, "exact handle shares burned");
        assertGe(debtCanceled, slice, "cancels at least the slice");
        assertLe(debtCanceled, slice + 1, "cancels at most the slice plus the one-wei round-up");
        assertGt(core.position(id, BORROWER).borrowShares, 0, "partial: borrower keeps debt");
    }

    /// @dev The share cap still rejects a genuine over-cut: one borrow share past the slice's share worth reverts.
    function testRevert_partialBorrowAnchored_aboveSliceShares() public {
        _setPersonalSettlementLtv(BORROWER, 0.7e18);
        vm.warp(block.timestamp + 1 hours);
        core.accrueInterest(params);
        uint256 ba = core.market(id).totalBorrowAssets;
        uint256 bs = core.market(id).totalBorrowShares;
        uint256 handle = SharesMathLib.toSharesUp(controller.positionOf(BORROWER).slice, ba, bs);

        vm.prank(vault);
        vm.expectRevert(ILidoLendMarketController.SettlementExceedsAllowed.selector);
        core.settle(params, 0, handle + 1, vault, BORROWER, RECEIVER);
    }

    // ── Deploy (no fork): core deployed from out/
    // ──────────────────────

    function _deployOracle(address, address) internal override returns (address) {
        return address(new FixedPriceOracle(PRICE));
    }
}
