// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {ILidoLend} from "@lido-lend/src/interfaces/ILidoLend.sol";
import {Id, MarketParams, Position, Market as MorphoMarket} from "@lido-lend/src/interfaces/IMorpho.sol";
import {SharesMathLib} from "@lido-lend/src/libraries/SharesMathLib.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Test} from "forge-std/Test.sol";

import {ILidoLendMarketController} from "../../src/interfaces/ILidoLendMarketController.sol";
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
    function balanceOf(address account) external view returns (uint256);
    function maxRedeem(address owner) external view returns (uint256);
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
///         (a filler borrower leaves the settleable-supply slack the close needs); shrinking that lever forces
///         supply-anchored partial cuts. The vault is the sole supplier, while free liquidity remains excluded
///         from the liquidity-neutral settlement budget.
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

    /// @dev The waterfall closes the riskiest borrower borrow-anchored: with the queue granting a full cut and
    ///      the filler leaving settleable-supply slack, the vault passes the borrower's whole borrow shares and
    ///      the position goes to zero.
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

    /// @dev Targeted `settle` on the last remaining borrower, with free liquidity still in the book. The vault
    ///      budgets only the settleable tail, so the one-wei full-close overshoot is downgraded to a partial
    ///      supply-anchored cut instead of reverting in the core.
    function test_settle_soleBorrowerFullCloseOvershootFallsBackToPartial() public {
        // Leave BORROWER as the only debtor, so a full close consumes the entire settleable supply.
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

        address[] memory borrowers = new address[](1);
        borrowers[0] = BORROWER;
        uint256 shares = IVault(vault).balanceOf(LENDER);

        // The gap is exactly one wei: the cap floors the vault's supply, the close ceils the borrower's debt.
        MorphoMarket memory mk = core.market(id);
        uint256 vaultSupplyAssets = SharesMathLib.toAssetsDown(
            core.position(id, vault).supplyShares, mk.totalSupplyAssets, mk.totalSupplyShares
        );
        uint256 settleable = vaultSupplyAssets - (mk.totalSupplyAssets - mk.totalBorrowAssets);
        uint256 wouldCancel = SharesMathLib.toAssetsUp(
            core.position(id, BORROWER).borrowShares, mk.totalBorrowAssets, mk.totalBorrowShares
        );
        assertEq(wouldCancel - settleable, 1, "the full close overshoots the cap by exactly one wei");

        uint256 debtSharesBefore = core.position(id, BORROWER).borrowShares;

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
        assertLt(debtSharesAfter, debtSharesBefore, "borrower debt reduced");
        assertGt(debtSharesAfter, 0, "borrower not fully closed");
        assertEq(debtAssetsAfter, 2, "borrower left with two wei debt");
    }

    /// @dev A dust borrower whose full-close debt maps to zero collateral is rejected by the core. Repaying that
    ///      debt makes `settlementFor` return a zero cut, so the same targeted call becomes a no-op.
    function test_settle_dustSliceRevertsUntilDustIsRepaid() public {
        _repayAll(FILLER);
        _repayAll(THIRD);
        uint256 dustDebtAssets = _repayAllButOneDebtAsset(BORROWER);
        assertLe(dustDebtAssets, 1, "debt is actual dust");

        _setWholeDebtSlice();

        address[] memory borrowers = new address[](1);
        borrowers[0] = BORROWER;
        uint256 shares = IVault(vault).balanceOf(LENDER);

        vm.prank(LENDER);
        vm.expectRevert(bytes("settlement slice too small"));
        IVault(vault).settle(shares, borrowers, RECEIVER, LENDER);

        _repayAll(BORROWER);
        assertEq(core.position(id, BORROWER).borrowShares, 0, "dust borrower repaid");

        vm.prank(LENDER);
        (uint256 sharesBurned,, uint256 collateralSeized, uint256 debtCanceled) =
            IVault(vault).settle(shares, borrowers, RECEIVER, LENDER);

        assertEq(sharesBurned, 0, "no shares burned after dust is gone");
        assertEq(collateralSeized, 0, "no collateral seized after dust is gone");
        assertEq(debtCanceled, 0, "no debt canceled after dust is gone");
    }

    /// @dev Targeted `settle` can close several borrowers to zero when every requested full close fits the
    ///      remaining settleable supply budget. This is the normal borrow-anchored path; no supply-anchored
    ///      downgrade is expected for either borrower.
    function test_settle_multipleBorrowersFullCloseToZero() public {
        controller.setSettlementConfig(
            SettlementConfig({sliceFloorBps: 100, sliceFloorAssets: 0, fullCutBelowCollateral: 300e18, ltvStepBps: 100})
        );

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

    /// @dev The borrow handle `settlementSlice` returns for a partial is usable: settling borrow-anchored with it
    ///      cuts up to the slice without tripping the policy cap. The +1h accrual makes the slice's handle value
    ///      back one wei above the slice — the case the old asset-denominated cap rejected, the share cap admits.
    function test_partialBorrowAnchored_cutsUpToSlice() public {
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
