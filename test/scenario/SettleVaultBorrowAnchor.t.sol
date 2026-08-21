// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {ILidoLend, ILidoLendBase} from "@lido-lend/src/interfaces/ILidoLend.sol";
import {Id, MarketParams, Position, Market as MorphoMarket} from "@lido-lend/src/interfaces/IMorpho.sol";
import {SharesMathLib} from "@lido-lend/src/libraries/SharesMathLib.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {ILidoLendMarketController} from "../../src/interfaces/ILidoLendMarketController.sol";
import {ILidoLendERC4626} from "../../src/interfaces/ILidoLendERC4626.sol";
import {SettlementConfig, SettlementSlice, SettlementQuote} from "../../src/types/SettlementTypes.sol";
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

/// @notice ERC4626 settlement and fallback exits against borrow-anchored core settlement.
contract SettleVaultBorrowAnchorTest is Test, LidoLendDeployer {
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
        uint256 firstBorrowShares;
        uint256 firstSupplyBurn;
        uint256 secondSupplyBurn;
        uint256 thirdBorrowShares;
        uint256 requestShares;
        uint256 quotedSettlementBudget;
        uint256 previousSettlementBudget;
    }

    struct CutExpectation {
        uint256 borrowShares;
        uint256 supplyBurn;
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
                    activatingLockDuration: 0,
                    maxDelayInflow: 100_000 ether,
                    minActivationAmount: 1e18,
                    minDepositAmount: 0,
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
        (address root,) = controller.nextSettlementBorrower(0);
        assertEq(root, BORROWER, "highest-LTV borrower is the queue root");

        uint256 shares = IVault(vault).balanceOf(LENDER);
        vm.prank(LENDER);
        (,, uint256 collateralSeized, uint256 debtCanceled) = IVault(vault).fallbackExit(shares, RECEIVER, LENDER, 0);

        assertEq(core.position(id, BORROWER).borrowShares, 0, "root closed to zero (borrow-anchored)");
        assertGe(debtCanceled, B_BORROW, "at least the root's debt cancelled");
        assertEq(collateral.balanceOf(RECEIVER), collateralSeized, "receiver got the seized collateral");
        assertGt(collateralSeized, 0, "collateral seized");
    }

    /// @dev A small request caps a personal cut without exceeding its supply-share budget.
    function test_settle_budgetBelowPersonalQuoteCapsBorrowCut() public {
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
        // Gross budget, borrow cut, debt canceled, supply burn, remaining debt assets.
        uint256[5] memory expected;
        uint256 shares;
        {
            MorphoMarket memory mk = core.market(id);
            SettlementQuote memory settlementQuote = controller.settlementFor(BORROWER, 0);
            uint256 personalSupplyShares = settlementQuote.personal.supplyShares;
            assertGt(settlementQuote.personal.remainingBorrowShares, 0, "personal quote ignores the dust sweep");
            assertEq(settlementQuote.queueRoot.remainingBorrowShares, 0, "queue-root quote is dust-promoted");

            shares = Math.mulDiv(personalSupplyShares - 1, vaultSharesBefore, vaultSupplySharesBefore);
            expected[0] = Math.mulDiv(vaultSupplySharesBefore, shares, vaultSharesBefore);
            assertGt(expected[0], 0, "request has a positive gross settlement budget");
            assertLt(expected[0], personalSupplyShares, "gross request budget is below the personal quote");

            uint256 budgetAssets = SharesMathLib.toAssetsDown(expected[0], mk.totalSupplyAssets, mk.totalSupplyShares);
            expected[1] = Math.min(
                settlementQuote.personal.borrowShares,
                SharesMathLib.toSharesDown(budgetAssets, mk.totalBorrowAssets, mk.totalBorrowShares)
            );
            expected[2] = SharesMathLib.toAssetsUp(expected[1], mk.totalBorrowAssets, mk.totalBorrowShares);
            expected[3] = SharesMathLib.toSharesUp(expected[2], mk.totalSupplyAssets, mk.totalSupplyShares);
            // The core floors the book's borrow assets at zero, because the up-rounded cancelation may exceed
            // them by one. Mirror that here rather than subtracting straight, or this recompute panics instead
            // of asserting whenever the cut spans the whole book.
            expected[4] = SharesMathLib.toAssetsUp(
                debtSharesBefore - expected[1],
                Math.saturatingSub(mk.totalBorrowAssets, expected[2]),
                mk.totalBorrowShares - expected[1]
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
            expected[3],
            "supply burn matches the borrow cut"
        );
        assertLe(expected[3], expected[0], "supply burn stays within the request budget");
        assertEq(debtCanceled, expected[2], "debt matches the borrow cut");
        assertEq(debtSharesBefore - debtSharesAfter, expected[1], "exact borrow shares canceled");
        assertLt(debtSharesAfter, debtSharesBefore, "borrower debt reduced");
        assertGt(debtSharesAfter, 0, "borrower not fully closed");
        assertEq(debtAssetsAfter, expected[4], "borrower keeps the modeled remainder");
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

    /// @dev A large collateral-dust threshold does not promote personal cuts in a multi-borrower targeted settle.
    ///      Both opted-in positions are reduced toward their targets and remain open.
    function test_settle_multipleBorrowersStopAtPersonalTargets() public {
        controller.setSettlementConfig(
            SettlementConfig({sliceFloorBps: 100, sliceFloorAssets: 0, fullCutBelowCollateral: 300e18, ltvStepBps: 100})
        );
        _setPersonalSettlementLtv(BORROWER, 1);
        _setPersonalSettlementLtv(FILLER, 1);

        address[] memory borrowers = new address[](2);
        borrowers[0] = BORROWER;
        borrowers[1] = FILLER;

        uint256 borrowerDebtBefore = core.position(id, BORROWER).borrowShares;
        uint256 fillerDebtBefore = core.position(id, FILLER).borrowShares;
        SettlementQuote memory borrowerQuote = controller.settlementFor(BORROWER, 0);
        SettlementQuote memory fillerQuote = controller.settlementFor(FILLER, 0);
        assertGt(borrowerQuote.personal.remainingBorrowShares, 0, "borrower personal quote remains partial");
        assertGt(fillerQuote.personal.remainingBorrowShares, 0, "filler personal quote remains partial");
        assertEq(borrowerQuote.queueRoot.remainingBorrowShares, 0, "borrower root quote is dust-promoted");
        assertEq(fillerQuote.queueRoot.remainingBorrowShares, 0, "filler prospective root quote is dust-promoted");

        uint256 shares = IVault(vault).balanceOf(LENDER);
        vm.prank(LENDER);
        (uint256 sharesBurned,, uint256 collateralSeized, uint256 debtCanceled) =
            IVault(vault).settle(shares, borrowers, RECEIVER, LENDER);

        uint256 remainingVaultSupplyShares = core.position(id, vault).supplyShares;
        uint256 remainingVaultShares = IVault(vault).balanceOf(LENDER);

        assertGt(sharesBurned, 0, "vault shares burned");
        assertGt(collateralSeized, 0, "collateral seized");
        assertGt(debtCanceled, 0, "both personal cuts cancel debt");
        assertLt(debtCanceled, B_BORROW + F_BORROW, "personal cuts do not close both debts");
        assertLt(core.position(id, BORROWER).borrowShares, borrowerDebtBefore, "borrower debt reduced");
        assertGt(core.position(id, BORROWER).borrowShares, 0, "borrower remains open");
        assertLt(core.position(id, FILLER).borrowShares, fillerDebtBefore, "filler debt reduced");
        assertGt(core.position(id, FILLER).borrowShares, 0, "filler remains open");
        assertGt(remainingVaultSupplyShares, 0, "idle supply remains in the vault");
        assertGt(remainingVaultShares, 0, "lender keeps shares for idle supply");
        assertEq(collateral.balanceOf(RECEIVER), collateralSeized, "receiver got the seized collateral");
    }

    /// @dev The same personal-only dust behavior holds across three requested borrowers: every target cut executes,
    ///      but none inherits its prospective queue-root full close.
    function test_settle_threeBorrowersStopAtPersonalTargets() public {
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

        uint256 borrowerDebtBefore = core.position(id, BORROWER).borrowShares;
        uint256 fillerDebtBefore = core.position(id, FILLER).borrowShares;
        uint256 thirdDebtBefore = core.position(id, THIRD).borrowShares;
        assertGt(controller.settlementFor(BORROWER, 0).personal.remainingBorrowShares, 0, "borrower quote is partial");
        assertGt(controller.settlementFor(FILLER, 0).personal.remainingBorrowShares, 0, "filler quote is partial");
        assertGt(controller.settlementFor(THIRD, 0).personal.remainingBorrowShares, 0, "third quote is partial");

        uint256 shares = IVault(vault).balanceOf(LENDER);

        vm.prank(LENDER);
        (uint256 sharesBurned,, uint256 collateralSeized, uint256 debtCanceled) =
            IVault(vault).settle(shares, borrowers, RECEIVER, LENDER);

        assertGt(sharesBurned, 0, "vault shares burned");
        assertGt(collateralSeized, 0, "collateral seized");
        assertGt(debtCanceled, 0, "personal cuts cancel debt");
        assertLt(debtCanceled, B_BORROW + F_BORROW + T_BORROW, "personal cuts do not close the whole book");
        assertGt(core.market(id).totalBorrowAssets, 0, "market keeps the target remainders");
        assertLt(core.position(id, BORROWER).borrowShares, borrowerDebtBefore, "borrower debt reduced");
        assertGt(core.position(id, BORROWER).borrowShares, 0, "borrower remains open");
        assertLt(core.position(id, FILLER).borrowShares, fillerDebtBefore, "filler debt reduced");
        assertGt(core.position(id, FILLER).borrowShares, 0, "filler remains open");
        assertLt(core.position(id, THIRD).borrowShares, thirdDebtBefore, "third debt reduced");
        assertGt(core.position(id, THIRD).borrowShares, 0, "third borrower remains open");
        assertGt(core.position(id, vault).supplyShares, 0, "idle supply remains in the vault");
        assertGt(IVault(vault).balanceOf(LENDER), 0, "lender keeps shares for idle supply");
        assertEq(collateral.balanceOf(RECEIVER), collateralSeized, "receiver got the seized collateral");
    }

    /// @dev One fallback iteration executes a partial borrow-share cut.
    function test_fallbackExit_partialCutUsesBorrowShares() public {
        // Default config (fullCutBelowCollateral = 0): no slice is ever lifted to a full close.
        uint256 rootDebtBefore = core.position(id, BORROWER).borrowShares;

        uint256 shares = IVault(vault).balanceOf(LENDER);
        vm.prank(LENDER);
        (,,, uint256 debtCanceled) = IVault(vault).fallbackExit(shares, RECEIVER, LENDER, 1);

        uint256 rootDebtAfter = core.position(id, BORROWER).borrowShares;
        assertGt(debtCanceled, 0, "some debt cancelled");
        assertLt(rootDebtAfter, rootDebtBefore, "root debt reduced");
        assertGt(rootDebtAfter, 0, "root remains open");
    }

    /// @dev An unaffordable full-close quote is capped to a partial borrow-share cut.
    function test_fallbackExit_unaffordableFullCloseFallsBackToPartial() public {
        _setFullCut(); // root is in full-close mode

        (address root,) = controller.nextSettlementBorrower(0);
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

    /// @dev A budget above both cuts closes the second borrower.
    function test_fallbackExit_budgetAboveSecondFullCloseUsesBorrowAnchor() public {
        TwoStepQuote memory quote = _prepareTwoStepFallbackExit();
        uint256 targetSettlementBudget = quote.firstSupplyBurn + quote.secondSupplyBurn;

        uint256 fillerDebtBefore = core.position(id, FILLER).borrowShares;
        assertLt(quote.previousSettlementBudget, targetSettlementBudget, "one raw share less is below the borrow close");
        assertGe(quote.quotedSettlementBudget, targetSettlementBudget, "chosen request can afford the borrow close");

        vm.expectCall(
            address(core),
            abi.encodeCall(ILidoLendBase.settle, (params, quote.thirdBorrowShares, vault, THIRD, RECEIVER))
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

    /// @dev A budget below the second full close caps that cut and leaves the borrower open.
    function test_fallbackExit_budgetBelowSecondFullCloseCapsBorrowCut() public {
        TwoStepQuote memory quote = _prepareTwoStepFallbackExit();
        uint256 belowBudget = quote.previousSettlementBudget;

        assertGt(quote.requestShares, 1, "one raw share lower request exists");
        assertGt(belowBudget, quote.firstSupplyBurn, "below-boundary request reaches the second borrower");
        assertLt(
            belowBudget,
            quote.firstSupplyBurn + quote.secondSupplyBurn,
            "below-boundary request cannot afford the full close"
        );
        uint256 secondRemainingBudget = belowBudget - quote.firstSupplyBurn;
        assertLt(secondRemainingBudget, quote.secondSupplyBurn, "second full-close quote exceeds the live budget");

        uint256 fillerDebtBefore = core.position(id, FILLER).borrowShares;
        assertLt(quote.firstBorrowShares, fillerDebtBefore, "first cut is partial");
        assertEq(
            core.position(id, THIRD).borrowShares, quote.thirdBorrowShares, "full-close quote uses all second debt"
        );

        CutExpectation memory expected = _quoteCappedSecondCut(quote, secondRemainingBudget);
        vm.expectCall(
            address(core), abi.encodeCall(ILidoLendBase.settle, (params, expected.borrowShares, vault, THIRD, RECEIVER))
        );
        vm.recordLogs();
        vm.prank(LENDER);
        (uint256 sharesBurned,, uint256 collateralSeized, uint256 debtCanceled) =
            IVault(vault).fallbackExit(quote.requestShares - 1, RECEIVER, LENDER, 2);

        assertGt(sharesBurned, 0, "vault shares burned");
        assertGt(collateralSeized, 0, "collateral seized");
        assertGt(debtCanceled, 0, "debt canceled");
        _assertCappedSecondCut(vm.getRecordedLogs(), quote, secondRemainingBudget, expected);
    }

    function _quoteCappedSecondCut(TwoStepQuote memory quote, uint256 budget)
        internal
        returns (CutExpectation memory expected)
    {
        uint256 snapshot = vm.snapshotState();
        vm.prank(vault);
        core.settle(params, quote.firstBorrowShares, vault, FILLER, RECEIVER);
        MorphoMarket memory mk = core.market(id);
        uint256 budgetAssets = SharesMathLib.toAssetsDown(budget, mk.totalSupplyAssets, mk.totalSupplyShares);
        expected.borrowShares = Math.min(
            quote.thirdBorrowShares,
            SharesMathLib.toSharesDown(budgetAssets, mk.totalBorrowAssets, mk.totalBorrowShares)
        );
        uint256 debtAssets = SharesMathLib.toAssetsUp(expected.borrowShares, mk.totalBorrowAssets, mk.totalBorrowShares);
        expected.supplyBurn = SharesMathLib.toSharesUp(debtAssets, mk.totalSupplyAssets, mk.totalSupplyShares);
        assertTrue(vm.revertToState(snapshot), "snapshot revert");
    }

    function _assertCappedSecondCut(
        Vm.Log[] memory logs,
        TwoStepQuote memory quote,
        uint256 budget,
        CutExpectation memory expected
    ) internal view {
        (uint256 fillerSupplyBurn, uint256 fillerBorrowBurn) = _settleBurnsFor(logs, FILLER);
        (uint256 thirdSupplyBurn, uint256 thirdBorrowBurn) = _settleBurnsFor(logs, THIRD);
        assertEq(fillerSupplyBurn, quote.firstSupplyBurn, "first supply burn matches");
        assertEq(fillerBorrowBurn, quote.firstBorrowShares, "first borrow cut matches");
        assertEq(thirdSupplyBurn, expected.supplyBurn, "second supply burn matches");
        assertLe(thirdSupplyBurn, budget, "second supply burn stays within budget");
        assertEq(thirdBorrowBurn, expected.borrowShares, "second borrow cut matches");
        assertLt(thirdBorrowBurn, quote.thirdBorrowShares, "second cut is partial");
        assertEq(
            core.position(id, THIRD).borrowShares,
            quote.thirdBorrowShares - thirdBorrowBurn,
            "second borrower debt matches"
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

        assertEq(fillerSupplyBurn, quote.firstSupplyBurn, "first supply burn matches");
        assertEq(fillerBorrowBurn, quote.firstBorrowShares, "first borrow cut matches");
        assertLt(fillerBorrowBurn, fillerDebtBefore, "first cut is partial");
        assertEq(thirdBorrowBurn, quote.thirdBorrowShares, "second cut closes all debt shares");
        assertEq(thirdSupplyBurn, quote.secondSupplyBurn, "second supply burn matches");
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

        (address root,) = controller.nextSettlementBorrower(0);
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

    function _quoteBorrowAnchoredBudget() internal returns (TwoStepQuote memory quote) {
        address root;
        SettlementSlice memory slice;
        (root, slice) = controller.nextSettlementBorrower(0);
        assertEq(root, FILLER, "automatic quote is for the first queue root");
        assertGt(slice.supplyShares, 0, "first cut has supply burn");
        assertGt(slice.borrowShares, 0, "first cut has borrow burn");
        assertGt(slice.remainingBorrowShares, 0, "first cut is partial");

        quote.firstBorrowShares = slice.borrowShares;
        uint256 snapshot = vm.snapshotState();

        vm.prank(vault);
        (,,, quote.firstSupplyBurn) = core.settle(params, quote.firstBorrowShares, vault, FILLER, RECEIVER);
        assertGt(quote.firstSupplyBurn, 0, "first cut burns supply");

        (root,) = controller.nextSettlementBorrower(0);
        assertEq(root, THIRD, "third is the second queue root");

        (root, slice) = controller.nextSettlementBorrower(0);
        quote.secondSupplyBurn = slice.supplyShares;
        quote.thirdBorrowShares = slice.borrowShares;
        assertEq(root, THIRD, "automatic quote is for the second queue root");
        assertGt(quote.secondSupplyBurn, 0, "second cut has supply burn");
        assertGt(quote.thirdBorrowShares, 0, "second cut has borrow burn");
        assertEq(slice.remainingBorrowShares, 0, "second cut is a full close");
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

        quote = _quoteBorrowAnchoredBudget();
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
        ILidoLendMarketController.BorrowerPosition memory dashboard = controller.positionOf(BORROWER);
        uint256 slice = Math.max(dashboard.personalSliceAssets, dashboard.queueRootSliceAssets);
        uint256 handle = SharesMathLib.toSharesUp(slice, ba, bs);
        assertGt(SharesMathLib.toAssetsUp(handle, ba, bs), slice, "handle values back above the slice (rejected case)");

        uint256 debtBefore = core.position(id, BORROWER).borrowShares;
        vm.prank(vault);
        (, uint256 debtCanceled,,) = core.settle(params, handle, vault, BORROWER, RECEIVER);

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
        ILidoLendMarketController.BorrowerPosition memory dashboard = controller.positionOf(BORROWER);
        uint256 slice = Math.max(dashboard.personalSliceAssets, dashboard.queueRootSliceAssets);
        uint256 handle = SharesMathLib.toSharesUp(slice, ba, bs);

        vm.prank(vault);
        vm.expectRevert(ILidoLendMarketController.SettlementExceedsAllowed.selector);
        core.settle(params, handle + 1, vault, BORROWER, RECEIVER);
    }

    // ── Deploy (no fork): core deployed from out/
    // ──────────────────────

    function _deployOracle(address, address) internal override returns (address) {
        return address(new FixedPriceOracle(PRICE));
    }
}
