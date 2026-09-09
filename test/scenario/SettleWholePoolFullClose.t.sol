// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {ILidoLend} from "@lido-lend/src/interfaces/ILidoLend.sol";
import {Id, MarketParams, Market} from "@lido-lend/src/interfaces/IMorpho.sol";
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
    function totalSupply() external view returns (uint256);
    function totalAssets() external view returns (uint256);
    function previewRedeem(uint256 shares) external view returns (uint256);
    function fallbackExit(uint256 shares, address receiver, address owner, uint256 maxIterations)
        external
        returns (uint256 sharesBurned, uint256 loanAssets, uint256 collateralSeized, uint256 debtCanceled);
}

/// @notice A full-pool fallback exit reserves the value assigned to virtual shares.
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
                supplyCap: 0,
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
                // fullCutBelowCollateral above both collaterals, so any partial slice strands dust and the queue
                // lifts every cut to a whole close.
                settlementConfig: SettlementConfig({
                    sliceFloorBps: 100, sliceFloorAssets: 0, fullCutBelowCollateral: 200e18, ltvStepBps: 100
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

        // Accrue: totalSupplyAssets and totalBorrowAssets lift equally (fee 0), while virtual-share rounding makes
        // the last borrow-anchored full-close cost exceed the vault's residual core-share budget by one share.
        vm.warp(block.timestamp + 1 days);
    }

    function _seedBorrower(address who, uint256 amount) internal {
        collateral.mint(who, amount);
        vm.startPrank(who);
        collateral.approve(address(core), type(uint256).max);
        core.supplyCollateral(params, amount, who, "");
        vm.stopPrank();
    }

    /// @dev All real vault shares burn, but the redemption budget leaves backing for virtual shares.
    function test_fallbackExit_fullPool_preservesVirtualBacking() public {
        assertEq(core.market(id).totalSupplyAssets, core.market(id).totalBorrowAssets, "100% utilisation (no free)");
        (address root,) = controller.nextSettlementBorrower(0);
        assertEq(root, RISKY, "highest-LTV borrower is the queue root");

        // Pin accrual so the book delta below is exact within this block (fallbackExit's own accrual is then a
        // no-op), letting us check debtCanceled share-for-share against the debt it removes from the book.
        core.accrueInterest(params);
        uint256 bookDebtBefore = core.market(id).totalBorrowAssets;

        uint256 shares = IVault(vault).balanceOf(LENDER);
        uint256 redeemAssets = IVault(vault).previewRedeem(shares);
        Market memory marketBefore = core.market(id);
        uint256 supplyBefore = _lidoLendSupplyShares();
        uint256 budget =
            SharesMathLib.toSharesDown(redeemAssets, marketBefore.totalSupplyAssets, marketBefore.totalSupplyShares);
        assertLt(budget, supplyBefore, "virtual shares reserve part of the managed supply");
        (uint256 expectedDebtCanceled, uint256 expectedSupplyBurn) = _expectedFullPoolSettlement(budget, marketBefore);
        vm.prank(LENDER);
        (,,, uint256 debtCanceled) = IVault(vault).fallbackExit(shares, RECEIVER, LENDER, 0);

        Market memory marketAfter = core.market(id);
        uint256 bookDebtAfter = marketAfter.totalBorrowAssets;
        uint256 supplyDust = _lidoLendSupplyShares();
        assertEq(core.position(id, RISKY).borrowShares, 0, "RISKY closed to zero");
        assertGt(core.position(id, TAIL).borrowShares, 0, "TAIL keeps debt dust");
        assertLe(debtCanceled, redeemAssets, "canceled debt fits the pre-call redemption value");
        assertEq(debtCanceled, expectedDebtCanceled, "both cuts cancel the debt affordable by the redemption budget");
        assertEq(debtCanceled, bookDebtBefore - bookDebtAfter, "debtCanceled == the exact book debt removed");
        assertEq(IVault(vault).balanceOf(LENDER), 0, "lender has no vault shares");
        assertEq(IVault(vault).totalSupply(), 0, "all real vault shares burned");
        assertEq(supplyBefore - supplyDust, expectedSupplyBurn, "both cuts consume the modeled core supply shares");
        assertGt(IVault(vault).totalAssets(), 0, "virtual backing need not have zero asset value");
    }

    /// @dev Both root policies request full closes; only the remaining supply budget limits the second cut.
    function _expectedFullPoolSettlement(uint256 budget, Market memory market_)
        internal
        view
        returns (uint256 debtCanceled, uint256 supplyBurned)
    {
        for (uint256 i; i < 2; ++i) {
            uint256 assets = SharesMathLib.toAssetsDown(budget, market_.totalSupplyAssets, market_.totalSupplyShares);
            uint256 borrowShares =
                SharesMathLib.toSharesDown(assets, market_.totalBorrowAssets, market_.totalBorrowShares);
            uint256 borrowerShares = core.position(id, i == 0 ? RISKY : TAIL).borrowShares;
            if (borrowShares > borrowerShares) borrowShares = borrowerShares;
            uint256 debt = SharesMathLib.toAssetsUp(borrowShares, market_.totalBorrowAssets, market_.totalBorrowShares);
            uint256 supply = SharesMathLib.toSharesUp(debt, market_.totalSupplyAssets, market_.totalSupplyShares);
            debtCanceled += debt;
            supplyBurned += supply;
            budget -= supply;
            market_.totalSupplyAssets -= uint128(debt);
            market_.totalSupplyShares -= uint128(supply);
            market_.totalBorrowAssets -= uint128(debt);
            market_.totalBorrowShares -= uint128(borrowShares);
        }
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
