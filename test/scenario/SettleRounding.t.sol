// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {ILidoLend} from "@lido-lend/src/interfaces/ILidoLend.sol";
import {Id, MarketParams, Market} from "@lido-lend/src/interfaces/IMorpho.sol";
import {ORACLE_PRICE_SCALE} from "@lido-lend/src/libraries/ConstantsLib.sol";
import {SharesMathLib} from "@lido-lend/src/libraries/SharesMathLib.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Test} from "forge-std/Test.sol";

import {ILidoLendMarketController} from "../../src/interfaces/ILidoLendMarketController.sol";
import {SettlementConfig, SettlementSlice, SettlementQuote} from "../../src/types/SettlementTypes.sol";
import {LidoLendDeployer} from "../../script/lib/LidoLendDeployer.sol";
import {CollateralActivationConfig} from "../../src/types/CollateralActivationTypes.sol";

interface IOracle {
    function price() external view returns (uint256);
}

/// @dev Pins a fixed wstETH/WETH price so the math is deterministic and needs no fork.
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

/// @notice Rounding behavior of borrow-anchored `settle` through the real controller hook.
contract SettleRoundingTest is Test, LidoLendDeployer {
    uint256 internal constant LLTV = 0.945e18;
    uint256 internal constant PRICE = 1.2e36; // 1.2 WETH per wstETH (ORACLE_PRICE_SCALE = 1e36)

    address internal constant LENDER = address(0x9000);
    address internal constant BORROWER = address(0xB0B);
    address internal constant FILLER = address(0xF111);
    address internal constant RECEIVER = address(0x5EED);

    uint256 internal constant SUPPLY = 133e18; // == total borrows -> ~100% utilization, settle is the only exit
    uint256 internal constant COLLATERAL = 200e18; // value 240 WETH @ 1.2; ample headroom over the debt
    uint256 internal constant BORROW = 113e18;
    // A second borrower carrying part of the book, so closing BORROWER cancels less than the whole pool debt
    // and the lender has enough supply shares for the borrow-anchored close's one-unit round-up.
    uint256 internal constant FILLER_COLLATERAL = 100e18;
    uint256 internal constant FILLER_BORROW = 20e18;

    MockToken internal loan;
    MockToken internal collateral;
    ILidoLend internal core;
    ILidoLendMarketController internal controller;
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
                    sliceFloorBps: 100,
                    sliceFloorAssets: 0,
                    // The personal cut leaves less than 150e18 collateral. Personal cuts ignore this dust limit.
                    fullCutBelowCollateral: 150e18,
                    ltvStepBps: 100
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
        params = d.params;
        id = d.marketId;

        // Sole lender funds the whole book.
        loan.mint(LENDER, SUPPLY);
        vm.startPrank(LENDER);
        loan.approve(d.core, type(uint256).max);
        core.supply(params, SUPPLY, 0, LENDER, "");
        vm.stopPrank();

        // Borrower posts collateral, waits out activation, then borrows against it.
        collateral.mint(BORROWER, COLLATERAL);
        vm.startPrank(BORROWER);
        collateral.approve(d.core, type(uint256).max);
        core.supplyCollateral(params, COLLATERAL, BORROWER, "");
        vm.stopPrank();

        // A filler borrower carries the rest of the book.
        collateral.mint(FILLER, FILLER_COLLATERAL);
        vm.startPrank(FILLER);
        collateral.approve(d.core, type(uint256).max);
        core.supplyCollateral(params, FILLER_COLLATERAL, FILLER, "");
        vm.stopPrank();

        vm.warp(block.timestamp + 3 hours); // past maxActivationDelay -> collateral active
        vm.prank(BORROWER);
        core.borrow(params, BORROW, 0, BORROWER, BORROWER);
        vm.prank(FILLER);
        core.borrow(params, FILLER_BORROW, 0, FILLER, FILLER);

        // Borrower opts into settlement with a near-zero target LTV. The personal quote is intentionally
        // still partial: the collateral-dust sweep belongs only to queue-root policy.
        vm.prank(BORROWER);
        controller.setSettlementLtv(1);

        // Accrue interest so totalBorrow/totalSupply drift off the flat 1:1e6 mint ratio and the
        // share<->asset conversions actually round; realize the drift into storage before the reads.
        vm.warp(block.timestamp + 7 days);
        core.accrueInterest(params);

        (, uint256 sliceAssets) = controller.settlementLtv(BORROWER);
        assertGt(sliceAssets, 0, "borrower is settle-eligible");
    }

    /// @dev Root policy allows a full close by borrow shares. The derived lender share burn rounds up.
    function test_borrowAnchored_rootFullClose_roundsUpLenderBurn() public {
        controller.setSettlementConfig(
            SettlementConfig({sliceFloorBps: 10_000, sliceFloorAssets: 0, fullCutBelowCollateral: 0, ltvStepBps: 0})
        );

        uint256 borrowShares = core.position(id, BORROWER).borrowShares;
        (address root,) = controller.nextSettlementBorrower(0);
        SettlementQuote memory quote = controller.settlementFor(BORROWER, 0);
        assertEq(root, BORROWER, "borrower is the queue root");
        assertGt(quote.personal.remainingBorrowShares, 0, "personal cut is partial");
        assertEq(quote.queueRoot.remainingBorrowShares, 0, "root cut is a full close");
        assertEq(quote.queueRoot.borrowShares, borrowShares, "root cut uses all borrow shares");

        Market memory m = core.market(id);
        uint256 lenderBefore = core.position(id, LENDER).supplyShares;

        uint256 expDebt = SharesMathLib.toAssetsUp(borrowShares, m.totalBorrowAssets, m.totalBorrowShares);
        uint256 expSupplyBurn = SharesMathLib.toSharesUp(expDebt, m.totalSupplyAssets, m.totalSupplyShares);
        uint256 expSeized = SharesMathLib.toAssetsDown(borrowShares, m.totalBorrowAssets, m.totalBorrowShares)
            * ORACLE_PRICE_SCALE / PRICE;

        vm.prank(LENDER);
        (uint256 seized, uint256 debtCanceled,,) = core.settle(params, borrowShares, LENDER, BORROWER, RECEIVER);

        assertEq(debtCanceled, expDebt, "debt canceled = borrowShares valued up");
        assertEq(seized, expSeized, "collateral seized at oracle par");
        assertEq(core.position(id, BORROWER).borrowShares, 0, "borrower closed to zero");
        assertEq(lenderBefore - core.position(id, LENDER).supplyShares, expSupplyBurn, "lender supply burn rounded up");
        assertEq(collateral.balanceOf(RECEIVER), expSeized, "receiver got the seized collateral");
        // Settler-adverse: the burned lender shares are worth at least the debt they cancelled.
        assertGe(
            SharesMathLib.toAssetsDown(expSupplyBurn, m.totalSupplyAssets, m.totalSupplyShares),
            debtCanceled,
            "lender gave up supply worth >= debt cancelled"
        );
    }

    /// @dev A partial cut cancels exact borrow shares. The lender pays for the up-rounded debt amount.
    function test_borrowAnchored_partialCut_lenderBearsRounding() public {
        Market memory m = core.market(id);
        uint256 borrowBefore = core.position(id, BORROWER).borrowShares;
        uint256 lenderBefore = core.position(id, LENDER).supplyShares;

        uint256 borrowCut = borrowBefore / 3;

        uint256 expDebt = SharesMathLib.toAssetsUp(borrowCut, m.totalBorrowAssets, m.totalBorrowShares);
        uint256 expSupplyBurn = SharesMathLib.toSharesUp(expDebt, m.totalSupplyAssets, m.totalSupplyShares);
        uint256 expSeized = SharesMathLib.toAssetsDown(borrowCut, m.totalBorrowAssets, m.totalBorrowShares)
            * ORACLE_PRICE_SCALE / PRICE;

        vm.prank(LENDER);
        (uint256 seized, uint256 debtCanceled,,) = core.settle(params, borrowCut, LENDER, BORROWER, RECEIVER);

        assertEq(debtCanceled, expDebt, "debt uses the up-rounded share value");
        assertEq(seized, expSeized, "collateral seized at oracle par");
        assertEq(lenderBefore - core.position(id, LENDER).supplyShares, expSupplyBurn, "lender burn is rounded up");
        assertEq(borrowBefore - core.position(id, BORROWER).borrowShares, borrowCut, "exact borrow shares canceled");
    }

    function testRevert_zeroBorrowShares() public {
        vm.prank(LENDER);
        vm.expectRevert(bytes("settlement slice too small"));
        core.settle(params, 0, LENDER, BORROWER, RECEIVER);
    }

    function testRevert_positiveBorrowSharesWorthZeroAssets() public {
        Market memory m = core.market(id);
        uint256 minimum = SharesMathLib.toSharesUp(1, m.totalBorrowAssets, m.totalBorrowShares);
        assertGt(minimum, 1, "positive zero-value borrow shares exist");

        vm.prank(LENDER);
        vm.expectRevert(bytes("settlement slice too small"));
        core.settle(params, minimum - 1, LENDER, BORROWER, RECEIVER);
    }

    // ── Deploy (no fork): everything mocked, core deployed from out/
    // ──────────────────────

    /// @dev Override the deployer's wstETH rate oracle with a fixed-price one.
    function _deployOracle(address, address) internal override returns (address) {
        return address(new FixedPriceOracle(PRICE));
    }
}
