// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {ILidoLend} from "@lido-lend/src/interfaces/ILidoLend.sol";
import {Id, MarketParams} from "@lido-lend/src/interfaces/IMorpho.sol";
import {SharesMathLib} from "@lido-lend/src/libraries/SharesMathLib.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Test} from "forge-std/Test.sol";

import {ILidoLendMarketController} from "../../src/interfaces/ILidoLendMarketController.sol";
import {SettlementConfig} from "../../src/types/SettlementTypes.sol";
import {LidoLendDeployer} from "../../script/lib/LidoLendDeployer.sol";

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
}

/// @notice The ERC4626 lender-exit waterfall against the core's borrow-anchored `settle`,
///         exercising both settle anchors the vault picks. With a `fullCutBelowCollateral` above the root's
///         collateral the queue opens a full cut, so the vault closes the riskiest borrower borrow-anchored
///         (a filler borrower leaves the settleable-supply slack the close needs); shrinking that lever forces
///         supply-anchored partial cuts. The vault is the sole lender, so its settleable supply is the whole
///         book debt.
contract SettleVaultDualAnchorTest is Test, LidoLendDeployer {
    uint256 internal constant LLTV = 0.945e18;
    uint256 internal constant PRICE = 1.2e36;

    address internal constant LENDER = address(0x9000);
    address internal constant BORROWER = address(0xB0B);
    address internal constant FILLER = address(0xF111);
    address internal constant RECEIVER = address(0x5EED);

    uint256 internal constant DEPOSIT = 200e18; // vault supply
    uint256 internal constant B_COLLATERAL = 50e18; // BORROWER: high LTV, the queue root
    uint256 internal constant B_BORROW = 47e18;
    uint256 internal constant F_COLLATERAL = 200e18; // FILLER: low LTV, carries slack so closing BORROWER fits
    uint256 internal constant F_BORROW = 80e18;

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
                activation: CollateralActivationConfigParams({
                    minActivationDelay: 10 minutes,
                    maxActivationDelay: 2 hours,
                    activatingLockAmount: 0,
                    activatingLockDuration: 0,
                    maxDelayInflow: 100_000 ether,
                    minActivationAmount: 1e18,
                    maxGuardiansQuorumDelay: 0
                }),
                settlementConfig: SettlementConfigParams({
                    sliceFloorBps: 100, sliceFloorAssets: 0, fullCutBelowCollateral: 0, ltvStepBps: 100
                }),
                guardians: guardians,
                quorum: 1,
                guardianConfig: GuardianConfigParams({delayPerStrike: 2 hours, delayPerSuspect: 0, maxDelay: 0, suspectWindow: 0}),
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

        vm.warp(block.timestamp + 3 hours); // past maxActivationDelay -> collateral active

        vm.prank(BORROWER);
        core.borrow(params, B_BORROW, 0, BORROWER, BORROWER);
        vm.prank(FILLER);
        core.borrow(params, F_BORROW, 0, FILLER, FILLER);
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

        // Exit half the position: the free-liquidity redeem leg consumes most of it, leaving a settle budget
        // smaller than the root's whole-debt close cost, so the full close is unaffordable.
        uint256 shares = IVault(vault).balanceOf(LENDER) / 2;
        vm.prank(LENDER);
        (,,, uint256 debtCanceled) = IVault(vault).fallbackExit(shares, RECEIVER, LENDER, 0);

        uint256 rootDebtAfter = core.position(id, BORROWER).borrowShares;
        assertGt(debtCanceled, 0, "some debt cancelled");
        assertLt(rootDebtAfter, rootDebtBefore, "root debt reduced");
        assertGt(rootDebtAfter, 0, "root NOT closed: unaffordable full close fell back to a partial");
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
        (, uint256 debtCanceled) = core.settle(params, 0, handle, vault, BORROWER, RECEIVER);

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
