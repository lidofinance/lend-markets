// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {ILidoLend} from "@lido-lend/src/interfaces/ILidoLend.sol";
import {Id, MarketParams} from "@lido-lend/src/interfaces/IMorpho.sol";
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
    function fallbackExit(uint256 shares, address receiver, address owner, uint256 maxIterations)
        external
        returns (uint256 sharesBurned, uint256 loanAssets, uint256 collateralSeized, uint256 debtCanceled);
}

/// @notice The fully-utilised pool edge: the vault is the sole lender with no free-liquidity surplus (100%
///         utilisation), and its whole supply backs the whole book debt. The settle waterfall closes borrowers
///         borrow-anchored to zero as long as the lender's residual settleable supply covers them — until the
///         LAST one, where the residual debt valued up exceeds the residual settleable supply valued down by the
///         one-wei virtual-share buffer. A borrow-anchored close there reverts on the core's settleable cap, so
///         the vault's budget gate must divert to a supply-anchored close: that borrower keeps the unbacked dust,
///         everyone before it is closed to zero, and the lender's exit never gets stuck.
contract SettleWholePoolFullCloseTest is Test, LidoLendDeployer {
    uint256 internal constant LLTV = 0.945e18;
    uint256 internal constant PRICE = 1.2e36;

    address internal constant LENDER = address(0x9000);
    address internal constant RISKY = address(0xA1); // higher LTV -> settled first -> closed to zero
    address internal constant TAIL = address(0xB2); // lower LTV -> settled last -> keeps the buffer dust
    address internal constant RECEIVER = address(0x5EED);

    uint256 internal constant DEPOSIT = 100e18; // vault supply

    uint256 internal constant RISKY_COLLATERAL = 30e18;
    uint256 internal constant RISKY_BORROW = 30e18; // LTV 83%

    uint256 internal constant TAIL_COLLATERAL = 100e18;
    uint256 internal constant TAIL_BORROW = 70e18; // LTV 58%; RISKY_BORROW + TAIL_BORROW == DEPOSIT -> util 100%

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
                // fullCutBelowCollateral above both collaterals, so any partial slice strands dust and the queue
                // lifts every cut to a whole close.
                settlementConfig: SettlementConfigParams({
                    sliceFloorBps: 100, sliceFloorAssets: 0, fullCutBelowCollateral: 200e18, ltvStepBps: 100
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

        // Sole lender funds the book through the vault.
        loan.mint(LENDER, DEPOSIT);
        vm.startPrank(LENDER);
        loan.approve(vault, type(uint256).max);
        IVault(vault).deposit(DEPOSIT, LENDER);
        vm.stopPrank();

        _seedBorrower(RISKY, RISKY_COLLATERAL);
        _seedBorrower(TAIL, TAIL_COLLATERAL);

        vm.warp(block.timestamp + 3 hours); // past maxActivationDelay -> collateral active

        // The two borrows together drain the whole supply -> 100% utilisation, no free liquidity.
        vm.prank(RISKY);
        core.borrow(params, RISKY_BORROW, 0, RISKY, RISKY);
        vm.prank(TAIL);
        core.borrow(params, TAIL_BORROW, 0, TAIL, TAIL);

        // Accrue: totalSupplyAssets and totalBorrowAssets lift equally (fee 0), so the last close's debt valued up
        // exceeds the residual settleable supply valued down by the one-wei buffer.
        vm.warp(block.timestamp + 1 days);
    }

    function _seedBorrower(address who, uint256 amount) internal {
        collateral.mint(who, amount);
        vm.startPrank(who);
        collateral.approve(address(core), type(uint256).max);
        core.supplyCollateral(params, amount, who, "");
        vm.stopPrank();
    }

    /// @dev The lender exits the whole position. RISKY (higher LTV, root first) is fully closed borrow-anchored;
    ///      TAIL (settled last, residual supply == residual debt minus the buffer) cannot be closed borrow-
    ///      anchored without tripping the core's settleable cap, so the vault diverts to supply-anchored and TAIL
    ///      keeps the unbacked one-wei dust. The exit completes and the lender fully exits.
    function test_fallbackExit_fullPool_closesAllButTheBufferDustOnTheTail() public {
        assertEq(core.market(id).totalSupplyAssets, core.market(id).totalBorrowAssets, "100% utilisation (no free)");
        (address root,,,) = controller.nextSettlementBorrower();
        assertEq(root, RISKY, "highest-LTV borrower is the queue root");

        // Pin accrual so the book delta below is exact within this block (fallbackExit's own accrual is then a
        // no-op), letting us check debtCanceled share-for-share against the debt it removes from the book.
        core.accrueInterest(params);
        uint256 bookDebtBefore = core.market(id).totalBorrowAssets;

        uint256 shares = IVault(vault).balanceOf(LENDER);
        vm.prank(LENDER);
        // Must NOT revert: a borrow-anchored close of the tail would trip SETTLEMENT_LIQUIDITY_AVAILABLE.
        (,,, uint256 debtCanceled) = IVault(vault).fallbackExit(shares, RECEIVER, LENDER, 0);

        uint256 bookDebtAfter = core.market(id).totalBorrowAssets;
        assertEq(core.position(id, RISKY).borrowShares, 0, "RISKY closed to exactly zero (borrow-anchored)");
        assertGt(core.position(id, TAIL).borrowShares, 0, "TAIL kept the unbacked dust (supply-anchored)");
        // The whole book debt is cancelled down to the unbacked one-wei virtual-share buffer — share-for-share,
        // not a partial sweep. The residue is TAIL's dust, worth at most one wei of debt assets.
        assertLe(bookDebtAfter, 1, "only the unbacked one-wei buffer of debt remains in the whole book");
        assertEq(debtCanceled, bookDebtBefore - bookDebtAfter, "debtCanceled == the exact book debt removed");
        assertEq(_lidoLendSupplyShares(), 0, "lender fully exited (vault supply position drained)");
    }

    function _lidoLendSupplyShares() internal view returns (uint256) {
        return core.position(id, vault).supplyShares;
    }

    // ── Deploy (no fork): core deployed from out/
    // ──────────────────────

    function _deployOracle(address, address) internal override returns (address) {
        return address(new FixedPriceOracle(PRICE));
    }
}
