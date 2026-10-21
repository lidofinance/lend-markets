// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {IMorphoVaultV2, IMorphoVaultV2Factory} from "../utils/IMorphoVaultV2.sol";
import {IIrmRouter} from "@lido-lend-irm/src/irm-router/interfaces/IIrmRouter.sol";
import {IAdaptiveCurveIrm} from "@lido-lend-irm/src/adaptive-curve-irm/interfaces/IAdaptiveCurveIrm.sol";
import {LinearKinkIrm} from "@lido-lend-irm/src/linear-kink-irm/LinearKinkIrm.sol";
import {LinearKinkConfig} from "@lido-lend-irm/src/linear-kink-irm/LinearKinkConfig.sol";
import {LinearKinkParams} from "@lido-lend-irm/src/linear-kink-irm/interfaces/ILinearKinkTypes.sol";
import {IIrm as RoutedIIrm} from "@lido-lend-irm/lib/lido-lend/src/interfaces/IIrm.sol";
import {Id as IrmId, MarketParams as IrmMarketParams} from "@lido-lend-irm/lib/lido-lend/src/interfaces/IMorpho.sol";

import {ILidoLend} from "@lido-lend/src/interfaces/ILidoLend.sol";
import {Id, MarketParams, Market} from "@lido-lend/src/interfaces/IMorpho.sol";
import {IIrm} from "@lido-lend/src/interfaces/IIrm.sol";
import {SharesMathLib} from "@lido-lend/src/libraries/SharesMathLib.sol";
import {ORACLE_PRICE_SCALE} from "@lido-lend/src/libraries/ConstantsLib.sol";

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ILidoLendMarketController} from "../../src/interfaces/ILidoLendMarketController.sol";
import {ILidoLendERC4626} from "../../src/interfaces/ILidoLendERC4626.sol";
import {ILidoLendOwner} from "../../src/interfaces/ILidoLendOwner.sol";
import {LidoLendMarketFactory} from "../../src/periphery/LidoLendMarketFactory.sol";
import {PausableUntil} from "../../src/utils/PausableUntil.sol";
import {SettlementSlice} from "../../src/types/SettlementTypes.sol";
import {WAD} from "../../src/libs/Constants.sol";
import {ForkStack} from "./helpers/ForkStack.sol";
import {IWETH, IWstETH} from "./helpers/ForkTokens.sol";
import {LidoLendV1AdapterV2, ILidoLendV1AdapterV2} from "./helpers/LidoLendV1AdapterV2.sol";

interface ICircuitBreakerPausers {
    function getPauser(address pausable) external view returns (address);
    function registerPauser(address pausable, address pauser) external;
}

/// @dev Test-only atomic composition, not a production solver. Uses prefunded liquidity, not a flash loan.
contract VaultV2AtomicExit {
    using SafeERC20 for IERC20;

    function exit(ILidoLend core, MarketParams calldata params, IMorphoVaultV2 vault, address adapter, uint256 assets)
        external
    {
        IERC20(params.loanToken).forceApprove(address(core), assets);
        core.supply(params, assets, 0, msg.sender, "");
        vault.forceDeallocate(adapter, abi.encode(params), assets, msg.sender);
        vault.withdraw(assets, address(this), msg.sender);
    }
}

/// @notice Vault V2 integration against the deployed Lido market, including pending interest and IRM changes.
/// @dev WARNING: the test-local LidoLendV1AdapterV2 is an unaudited compatibility fork, not a production adapter.
///      Creates the external vault through Morpho's onchain factory, on the test fork only.
///      Core, primary controller, oracle and router remain bound to the deployment. The multi-market scenario
///      creates a disposable second market through the deployed Lido factory and governance facade.
///      The full-liquidity exit requires the test borrower to be the settlement-queue root.
/// forge-config: default.isolate = true
contract MetaMorphoV2IntegrationTest is ForkStack {
    using SafeERC20 for IERC20;

    event Deallocate(address indexed sender, address indexed adapter, uint256 assets, bytes32[] ids, int256 change);

    BoundMarket internal m;

    // Rebound from the bound market in `setUp` so the flow reads like the freshly-deployed variant did.
    ILidoLend internal core;
    MarketParams internal params;
    Id internal marketId;
    address internal irmRouter;

    // The upstream vault and a fresh router-compatible adapter over the bound core.
    IMorphoVaultV2 internal vault2;
    LidoLendV1AdapterV2 internal adapter;
    address internal adapterAddr;

    // Role-only actors (curator/allocator hold no market position or vault shares).
    address internal CURATOR;
    address internal ALLOCATOR;

    // Market-participating actors — fresh and market-clean, so per-actor reads double as deltas.
    address internal USER;
    address internal BORROWER;
    address internal SOLVER;
    address internal DIRECT_LENDER;
    address internal LOW_LTV_BORROWER;

    uint256 internal constant PERFORMANCE_FEE = 0.2e18;
    uint256 internal constant MANAGEMENT_FEE = uint256(0.01e18) / 365 days;
    address internal PERFORMANCE_RECIPIENT = makeAddr("metaMorphoV2.performance");
    address internal MANAGEMENT_RECIPIENT = makeAddr("metaMorphoV2.management");
    address internal CORE_FEE_RECIPIENT = makeAddr("metaMorphoV2.coreFee");

    struct VaultQuote {
        uint256 assets;
        uint256 supply;
        uint256 performanceShares;
        uint256 managementShares;
    }

    struct DeallocationState {
        Market accrued;
        bytes32 marketState;
        uint256 trackedShares;
        uint256 coreShares;
        uint256 idle;
        uint256 adapterBalance;
        uint256[3] allocations;
        uint256 vaultAssets;
        uint256 vaultShares;
        uint256 vaultLastUpdate;
    }

    struct VaultActionState {
        uint256 balance;
        uint256 shares;
        uint256 tracked;
        uint256 idle;
        uint256 coreUpdated;
        uint256 performance;
        uint256 management;
    }

    function setUp() public {
        _fork();
        string memory market_ = _marketForRole("weth-wsteth");
        if (bytes(market_).length == 0) return; // not applicable to this deployment
        // Vault V2 is an external, per-network integration: a network config that records no factory (e.g. a
        // testnet) has nothing to integrate with, so the suite does not apply there.
        if (!_hasExt("morphoVaultV2Factory")) {
            vm.skip(true, "MetaMorphoV2: network config records no morphoVaultV2Factory");
            return;
        }
        m = _bindMarket(market_);
        _pokeAccrue(m); // fold in pending interest up front so the exact liquidity math below holds

        core = m.core;
        params = m.params;
        marketId = m.id;

        irmRouter = _protocol("irm_router");
        assertEq(params.irm, irmRouter, "bound market uses the recorded router");
        _createVaultFromFactory();

        CURATOR = makeAddr("metaMorphoV2.curator");
        ALLOCATOR = makeAddr("metaMorphoV2.allocator");
        USER = _freshActor(m, "metaMorphoV2.user");
        BORROWER = _freshActor(m, "metaMorphoV2.borrower");
        SOLVER = _freshActor(m, "metaMorphoV2.solver");
        DIRECT_LENDER = _freshActor(m, "metaMorphoV2.directLender");
        LOW_LTV_BORROWER = _freshActor(m, "metaMorphoV2.lowLtvBorrower");

        _configureVault();
    }

    /// @notice Pending interest is valued through the router, and vault deposits and withdrawals still work.
    function test_metaMorphoV2_pendingInterestUsesRouter() public {
        _seedInterestPosition(5 ether);
        uint256 assetsBefore = adapter.realAssets();
        vm.warp(block.timestamp + 1 days);

        assertGt(_assertPendingQuoteMatchesAccrual(), assetsBefore, "adapter includes pending interest");
        _depositAndWithdrawWithPendingInterest();
    }

    /// @notice Across debt sizes and time gaps, the adapter's interest quote matches actual core accrual.
    function testFuzz_metaMorphoV2_pendingInterestMatchesAccrual(uint256 debt, uint256 elapsed) public {
        debt = bound(debt, 1 ether, 9 ether);
        elapsed = bound(elapsed, 1 hours, 7 days);
        _seedInterestPosition(debt);
        uint256 assetsBefore = adapter.realAssets();
        vm.warp(block.timestamp + elapsed);

        assertGt(_assertPendingQuoteMatchesAccrual(), assetsBefore, "positive debt accrues interest");
        _depositAndWithdrawWithPendingInterest();
    }

    /// @notice Allocation and deallocation reuse supplied market parameters, including for zero-amount updates.
    function testFuzz_metaMorphoV2_adapterUpdateReusesMarketParams(uint256 assets, bool withdrawing, bool zeroAssets)
        public
    {
        assets = zeroAssets ? 0 : bound(assets, 1, 1 ether);
        _seedInterestPosition(5 ether);
        vm.warp(block.timestamp + 1 days);
        _assertAdapterUpdateReusesParams(assets, withdrawing);
    }

    /// @notice Switching the routed IRM to Linear Kink preserves interest quotes, deposits and withdrawals.
    function test_metaMorphoV2_pendingInterestSurvivesLinearKinkRoute() public {
        _seedInterestPosition(5 ether);
        vm.warp(block.timestamp + 1 days);
        _assertPendingQuoteMatchesAccrual();
        _depositAndWithdrawWithPendingInterest();

        LinearKinkIrm linear = new LinearKinkIrm(address(this), address(this));
        LinearKinkConfig config = new LinearKinkConfig(
            LinearKinkParams({
                optimalUtilization: uint64(0.8e18),
                baseRate: uint64(uint256(0.02e18) / 365 days),
                slope1: uint64(uint256(0.04e18) / 365 days),
                slope2: uint64(uint256(0.8e18) / 365 days)
            })
        );
        // The IRM dependency has its own ABI-identical core types.
        IrmMarketParams memory routedParams = abi.decode(abi.encode(params), (IrmMarketParams));
        linear.applyIrmConfig(routedParams, address(config));
        IIrmRouter router = IIrmRouter(irmRouter);
        assertEq(address(router.marketIrm(IrmId.wrap(Id.unwrap(marketId)))), _protocol("adaptive_curve_irm"));
        vm.prank(router.manager());
        router.setMarketIrm(routedParams, RoutedIIrm(address(linear)));
        assertEq(address(router.marketIrm(IrmId.wrap(Id.unwrap(marketId)))), address(linear));
        assertEq(core.market(marketId).lastUpdate, block.timestamp, "route change accrues the old model");

        uint256 assetsBefore = adapter.realAssets();
        vm.warp(block.timestamp + 1 days);
        assertGt(_assertPendingQuoteMatchesAccrual(), assetsBefore, "new model contributes interest");
        _depositAndWithdrawWithPendingInterest();
    }

    /// @notice An empty adapter reports zero assets, even when asked to value an unknown market.
    function test_metaMorphoV2_emptyAdapterNeedsNoMarketLookup() public view {
        assertEq(adapter.expectedSupplyAssets(keccak256("uncreated market")), 0);
        assertEq(adapter.realAssets(), 0);
    }

    /// @notice Deposit, mint, withdraw and redeem match the share/asset model with core and vault fees enabled.
    function testFuzz_metaMorphoV2_erc4626WithCoreAndVaultFees(uint256 amount, uint256 elapsed) public {
        amount = bound(amount, 0.1 ether, 1 ether);
        elapsed = bound(elapsed, 1 hours, 7 days);
        _seedInterestPosition(5 ether);
        _configureFees();

        for (uint8 action; action < 4; ++action) {
            vm.warp(block.timestamp + elapsed);
            _assertPendingQuoteMatchesAccrual();
            _assertVaultAction(action, amount);
        }
        assertGt(core.position(marketId, CORE_FEE_RECIPIENT).supplyShares, 0, "core fee minted real supply shares");
        assertGt(vault2.balanceOf(PERFORMANCE_RECIPIENT), 0, "performance fee minted real vault shares");
        assertGt(vault2.balanceOf(MANAGEMENT_RECIPIENT), 0, "management fee minted real vault shares");
    }

    /// @notice An oracle outage blocks borrowing but leaves vault accounting and liquid ERC-4626 operations usable.
    function test_metaMorphoV2_oracleOutageBlocksBorrowButNotVaultAccounting() public {
        _seedInterestPosition(5 ether);
        _configureFees();
        // Fail the live oracle's upstream read, not the vault or adapter. No price mock is used in the happy path.
        bytes memory rateCall = abi.encodeCall(IWstETH.getStETHByWstETH, (ORACLE_PRICE_SCALE));
        vm.mockCallRevert(address(m.collateralToken), rateCall, bytes("rate unavailable"));
        vm.expectRevert(bytes("rate unavailable"));
        vm.prank(BORROWER);
        core.borrow(params, 1, 0, BORROWER, BORROWER);

        for (uint8 action; action < 4; ++action) {
            vm.warp(block.timestamp + 1 days);
            _assertVaultAction(action, 0.1 ether);
        }
        vm.clearMockedCalls();
        assertGt(m.oracle.price(), 0, "live oracle restored");
    }

    /// @notice Bad debt from liquidation lowers vault asset value and the amount a user receives on redemption.
    function test_metaMorphoV2_liquidationLossReachesVaultSharePrice() public {
        _seedInterestPosition(5 ether);
        vm.warp(block.timestamp + 1 days);
        vault2.accrueInterest();
        uint256 vaultAssetsBefore = vault2.totalAssets();
        uint256 userQuoteBefore = vault2.previewRedeem(vault2.balanceOf(USER));
        uint256 livePrice = m.oracle.price();
        uint256 collateral = core.position(marketId, BORROWER).collateral;
        // A simulated severe accounting-rate loss causes bad debt. The deployed oracle still executes normally.
        uint256 shockedPrice = Math.mulDiv(1 ether, ORACLE_PRICE_SCALE, collateral);
        assertLt(shockedPrice, livePrice);
        vm.mockCall(
            address(m.collateralToken),
            abi.encodeCall(IWstETH.getStETHByWstETH, (ORACLE_PRICE_SCALE)),
            abi.encode(shockedPrice)
        );
        assertEq(m.oracle.price(), shockedPrice);
        _fundLoan(SOLVER, 5 ether);
        vm.prank(SOLVER);
        m.loanToken.approve(address(core), type(uint256).max);
        uint256 supplyBefore = core.market(marketId).totalSupplyAssets;
        uint256 collateralBefore = m.collateralToken.balanceOf(SOLVER);
        vm.expectCall(address(m.oracle), abi.encodeCall(m.oracle.price, ()));
        vm.prank(SOLVER);
        (uint256 seized, uint256 repaid) = core.liquidate(params, BORROWER, collateral, 0, "");
        assertEq(seized, collateral);
        assertGt(repaid, 0);
        assertEq(m.collateralToken.balanceOf(SOLVER), collateralBefore + seized);
        assertEq(m.loanToken.balanceOf(SOLVER), 5 ether - repaid);
        assertEq(core.position(marketId, BORROWER).borrowShares, 0);
        assertLt(core.market(marketId).totalSupplyAssets, supplyBefore, "bad debt reduces supplier assets");

        assertLt(vault2.totalAssets(), vaultAssetsBefore, "loss is visible without waiting for a new timestamp");
        uint256 assets = vault2.previewRedeem(vault2.balanceOf(USER));
        assertLt(assets, userQuoteBefore, "user bears the adapter's share of bad debt");
        uint256 balanceBefore = m.loanToken.balanceOf(USER);
        uint256 userShares = vault2.balanceOf(USER);
        vm.prank(USER);
        assertEq(vault2.redeem(userShares, USER, USER), assets);
        assertEq(m.loanToken.balanceOf(USER), balanceBefore + assets);
        assertEq(vault2.balanceOf(USER), 0);
        vm.clearMockedCalls();
    }

    /// @notice Force deallocation burns the configured penalty shares and makes assets available for withdrawal.
    function test_metaMorphoV2_forceDeallocateChargesConfiguredPenalty() public {
        _seedInterestPosition(5 ether);
        uint256 penalty = 0.01e18;
        _executeTimelocked(abi.encodeCall(vault2.setForceDeallocatePenalty, (adapterAddr, penalty)));
        vm.warp(block.timestamp + 1 days);
        uint256 penaltyAssets = Math.mulDiv(1 ether, penalty, WAD, Math.Rounding.Ceil);
        uint256 expectedBurn = vault2.previewWithdraw(penaltyAssets);
        uint256 sharesBefore = vault2.balanceOf(USER);
        uint256 adapterBefore = adapter.realAssets();
        uint256 idleBefore = m.loanToken.balanceOf(address(vault2));
        vm.prank(USER);
        uint256 burned = vault2.forceDeallocate(adapterAddr, abi.encode(params), 1 ether, USER);
        assertEq(burned, expectedBurn);
        assertEq(vault2.balanceOf(USER), sharesBefore - expectedBurn);
        assertApproxEqAbs(adapter.realAssets(), adapterBefore - 1 ether, 1);
        assertEq(m.loanToken.balanceOf(address(vault2)), idleBefore + 1 ether, "penalty stays inside vault");
        uint256 quote = vault2.previewWithdraw(0.5 ether);
        vm.prank(USER);
        assertEq(vault2.withdraw(0.5 ether, USER, USER), quote);
        assertEq(m.loanToken.balanceOf(USER), 0.5 ether);
    }

    /// @notice A zero adapter allocation cap rejects deposits without changing balances or blocking withdrawals.
    function testRevert_metaMorphoV2_capBlocksDepositButNotExit() public {
        _seedInterestPosition(5 ether);
        vm.prank(CURATOR);
        vault2.decreaseAbsoluteCap(abi.encode("this", adapterAddr), 0);
        _fundLoan(USER, 1 ether);
        uint256 sharesBefore = vault2.balanceOf(USER);
        uint256 trackedBefore = adapter.supplyShares(Id.unwrap(marketId));
        vm.expectRevert(bytes4(keccak256("ZeroAbsoluteCap()")));
        vm.prank(USER);
        vault2.deposit(1 ether, USER);
        assertEq(m.loanToken.balanceOf(USER), 1 ether, "reverted deposit returns funds");
        assertEq(vault2.balanceOf(USER), sharesBefore);
        assertEq(adapter.supplyShares(Id.unwrap(marketId)), trackedBefore);
        vm.prank(USER);
        vault2.withdraw(1 ether, USER, USER);
        assertEq(m.loanToken.balanceOf(USER), 2 ether, "zero supply cap does not block exit");
    }

    /// @notice Allocator and sentinel deallocations reconcile every allocation ID, including zero-amount updates.
    function testFuzz_metaMorphoV2_directDeallocateReconcilesVault(uint256 assets, bool sentinel, bool zeroAssets)
        public
    {
        _seedInterestPosition(5 ether);
        _configureFees();
        vm.warp(block.timestamp + 1 days);
        address caller = sentinel ? makeAddr("metaMorphoV2.sentinel") : ALLOCATOR;
        if (sentinel) vault2.setIsSentinel(caller, true);
        _assertDirectDeallocation(params, zeroAssets ? 0 : bound(assets, 1, 3 ether), caller);
        _assertVaultAction(2, 0.1 ether);
    }

    /// @notice Fully unwinding, removing and re-adding the adapter permits re-entry without stale allocations.
    function test_metaMorphoV2_fullUnwindRemoveAndReenter() public {
        _seedInterestPosition(5 ether);
        vm.warp(block.timestamp + 1 days);
        _repayBorrower(m, BORROWER);
        uint256 allAssets = adapter.expectedSupplyAssets(Id.unwrap(marketId));
        _assertDirectDeallocation(params, allAssets, ALLOCATOR);
        assertEq(adapter.realAssets(), 0);
        assertEq(adapter.marketIdsLength(), 0);
        _assertAllocations(params, 0);
        // Asset-denominated exits may leave shares worth less than one smallest loan-token unit.
        assertEq(_shareValue(core.market(marketId), adapter.supplyShares(Id.unwrap(marketId))), 0);

        vm.prank(ALLOCATOR);
        vault2.setLiquidityAdapterAndData(address(0), "");
        vm.prank(CURATOR);
        vault2.decreaseAbsoluteCap(abi.encode("this", adapterAddr), 0);
        _executeTimelocked(abi.encodeCall(vault2.removeAdapter, (adapterAddr)));
        assertFalse(vault2.isAdapter(adapterAddr));
        assertEq(vault2.adaptersLength(), 0);
        uint256 assetsBefore = vault2.totalAssets();
        vm.prank(USER);
        vault2.withdraw(1 ether, USER, USER);
        assertEq(vault2.totalAssets(), assetsBefore - 1 ether);

        _registerAdapter();
        vm.prank(ALLOCATOR);
        vault2.allocate(adapterAddr, abi.encode(params), 1 ether);
        assertEq(vault2.adaptersLength(), 1);
        assertEq(adapter.marketIdsLength(), 1);
        assertEq(adapter.marketIds(0), Id.unwrap(marketId));
        _assertAllocations(params, adapter.realAssets());
        vm.prank(ALLOCATOR);
        vault2.setLiquidityAdapterAndData(adapterAddr, abi.encode(params));
        _depositAndWithdrawWithPendingInterest();
    }

    /// @notice An IRM write-off restores idle withdrawals without recovering the abandoned market position.
    function test_metaMorphoV2_failedIrmCanBeWrittenOffWithoutCallingIt() public {
        _seedInterestPosition(5 ether);
        _assertDirectDeallocation(params, 2 ether, ALLOCATOR);
        bytes4 burnSelector = ILidoLendV1AdapterV2.burnShares.selector;
        _executeAdapterTimelocked(abi.encodeCall(adapter.increaseTimelock, (burnSelector, 1 days)));
        vm.warp(block.timestamp + 1 days);
        vm.mockCallRevert(irmRouter, abi.encodePacked(IIrm.borrowRateView.selector), bytes("IRM unavailable"));
        vm.mockCallRevert(irmRouter, abi.encodePacked(IIrm.borrowRate.selector), bytes("IRM unavailable"));
        vm.expectRevert(bytes("IRM unavailable"));
        vault2.totalAssets();
        vm.expectRevert(bytes("IRM unavailable"));
        vm.prank(USER);
        vault2.forceDeallocate(adapterAddr, abi.encode(params), 1 ether, USER);

        bytes memory burnData = abi.encodeCall(adapter.burnShares, (Id.unwrap(marketId)));
        vm.prank(CURATOR);
        adapter.submit(burnData);
        vm.expectRevert(ILidoLendV1AdapterV2.TimelockNotExpired.selector);
        adapter.burnShares(Id.unwrap(marketId));
        vm.warp(block.timestamp + 1 days);
        uint256 coreSharesBefore = core.position(marketId, adapterAddr).supplyShares;
        adapter.burnShares(Id.unwrap(marketId));
        vm.prank(ALLOCATOR);
        vault2.deallocate(adapterAddr, abi.encode(params), 0);
        _assertAllocations(params, 0);
        assertEq(adapter.marketIdsLength(), 0);
        assertEq(adapter.realAssets(), 0);
        assertEq(
            core.position(marketId, adapterAddr).supplyShares, coreSharesBefore, "write-off does not recover funds"
        );
        vault2.accrueInterest();
        assertEq(vault2.totalAssets(), 2 ether, "only previously withdrawn idle assets survive");
        uint256 shares = vault2.balanceOf(USER);
        uint256 quote = vault2.previewRedeem(shares);
        uint256 beforeBalance = m.loanToken.balanceOf(USER);
        vm.prank(USER);
        assertEq(vault2.redeem(shares, USER, USER), quote);
        assertEq(m.loanToken.balanceOf(USER), beforeBalance + quote);
        assertEq(vault2.balanceOf(USER), 0);
        vm.clearMockedCalls();
    }

    /// @notice Absolute and relative caps on each allocation ID reject excessive deposits but still allow exits.
    function testFuzz_metaMorphoV2_finiteCapsUseEveryAllocationId(uint8 idIndex, bool relative) public {
        idIndex = uint8(bound(idIndex, 0, 2));
        _seedInterestPosition(5 ether);
        vm.warp(block.timestamp + 1 days);
        _assertDirectDeallocation(params, 5 ether, ALLOCATOR);
        bytes memory idData = _idData(params, idIndex);
        vm.prank(CURATOR);
        if (relative) vault2.decreaseRelativeCap(idData, 0.6e18);
        else vault2.decreaseAbsoluteCap(idData, 6 ether);
        vm.prank(ALLOCATOR);
        vault2.allocate(adapterAddr, abi.encode(params), 0.5 ether);
        _assertAllocations(params, adapter.realAssets());

        _fundLoan(USER, 2 ether);
        bytes32 beforeState = _vaultState();
        vm.expectRevert(bytes4(keccak256(bytes(relative ? "RelativeCapExceeded()" : "AbsoluteCapExceeded()"))));
        vm.prank(USER);
        vault2.deposit(2 ether, USER);
        assertEq(_vaultState(), beforeState, "cap failure rolls back shares, allocations and transfers");
        vm.prank(CURATOR);
        if (relative) vault2.decreaseRelativeCap(idData, 0);
        else vault2.decreaseAbsoluteCap(idData, 1);
        _assertDirectDeallocation(params, 1 ether, ALLOCATOR);
        vm.prank(USER);
        vault2.withdraw(1 ether, USER, USER);
    }

    /// @notice Batched force deallocation and withdrawal charge the penalty correctly and collect vault fees once.
    function test_metaMorphoV2_multicallForceExitChargesFeesOnce() public {
        _seedInterestPosition(5 ether);
        _configureFees();
        _executeTimelocked(abi.encodeCall(vault2.setForceDeallocatePenalty, (adapterAddr, 0.01e18)));
        vm.warp(block.timestamp + 1 days);
        // Model the deallocation's rounding before quoting the fees collected by forceDeallocate's withdrawal.
        Market memory accrued = _accruedMarket(params);
        uint256 burned = _sharesUp(accrued, 1 ether);
        uint256 beforeValue = _shareValue(accrued, adapter.supplyShares(Id.unwrap(marketId)));
        accrued.totalSupplyAssets -= uint128(1 ether);
        accrued.totalSupplyShares -= uint128(burned);
        uint256 afterValue = _shareValue(accrued, adapter.supplyShares(Id.unwrap(marketId)) - burned);
        VaultQuote memory q = _vaultQuoteForAssets(m.loanToken.balanceOf(address(vault2)) + 1 ether + afterValue);
        uint256 penaltyAssets = 0.01 ether;
        uint256 penaltyShares =
            Math.mulDiv(penaltyAssets, q.supply + vault2.virtualShares(), q.assets + 1, Math.Rounding.Ceil);
        uint256 exitShares = Math.mulDiv(
            0.5 ether,
            q.supply - penaltyShares + vault2.virtualShares(),
            q.assets - penaltyAssets + 1,
            Math.Rounding.Ceil
        );
        uint256 userShares = vault2.balanceOf(USER);
        uint256 performanceBefore = vault2.balanceOf(PERFORMANCE_RECIPIENT);
        uint256 managementBefore = vault2.balanceOf(MANAGEMENT_RECIPIENT);
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(vault2.forceDeallocate, (adapterAddr, abi.encode(params), 1 ether, USER));
        calls[1] = abi.encodeCall(vault2.withdraw, (0.5 ether, USER, USER));
        vm.prank(USER);
        vault2.multicall(calls);
        assertEq(vault2.balanceOf(USER), userShares - penaltyShares - exitShares);
        assertEq(vault2.balanceOf(PERFORMANCE_RECIPIENT), performanceBefore + q.performanceShares);
        assertEq(vault2.balanceOf(MANAGEMENT_RECIPIENT), managementBefore + q.managementShares);
        assertEq(m.loanToken.balanceOf(USER), 0.5 ether);
        assertEq(vault2._totalAssets(), q.assets - penaltyAssets - 0.5 ether);
        assertApproxEqAbs(beforeValue, afterValue + 1 ether, 1, "only bounded share-conversion dust is lost");
    }

    /// @notice A prefunded solver swaps vault shares for core shares atomically and recovers its capital.
    function test_metaMorphoV2_atomicSolverExitsFullyUtilizedMarket() public {
        _seedVaultAndDirectLender();
        _seedBorrowersAndDrainLiquidity();
        vm.prank(ALLOCATOR);
        vault2.setLiquidityAdapterAndData(adapterAddr, abi.encode(params));
        vm.expectRevert(bytes("insufficient liquidity"));
        vm.prank(USER);
        vault2.withdraw(10 ether, USER, USER);

        VaultV2AtomicExit solver = new VaultV2AtomicExit();
        _fundLoan(address(solver), 10 ether);
        vm.prank(USER);
        vault2.approve(address(solver), type(uint256).max);
        uint256 debtBefore = core.market(marketId).totalBorrowAssets;
        vm.prank(USER);
        solver.exit(core, params, vault2, adapterAddr, 10 ether);
        assertEq(m.loanToken.balanceOf(address(solver)), 10 ether, "solver recovers its prefunded capital atomically");
        assertEq(m.loanToken.balanceOf(address(vault2)), 0);
        assertEq(vault2.balanceOf(USER), 0);
        assertEq(adapter.realAssets(), 0);
        assertEq(adapter.marketIdsLength(), 0);
        _assertAllocations(params, 0);
        assertEq(_shareValue(core.market(marketId), core.position(marketId, USER).supplyShares), 10 ether);
        assertEq(core.market(marketId).totalBorrowAssets, debtBefore, "exit transfers exposure, not borrowed funds");
    }

    /// @notice The market supply cap blocks deposits, not withdrawals; lifting it restores deposits.
    function test_metaMorphoV2_lidoSupplyCapBlocksEntryButNotExit() public {
        _seedInterestPosition(5 ether);
        _setSupplyCap(m, core.market(marketId).totalSupplyAssets);
        _fundLoan(USER, 1 ether);
        bytes32 beforeState = _vaultState();
        vm.expectRevert(
            abi.encodeWithSelector(
                ILidoLendMarketController.SupplyCapExceeded.selector,
                core.market(marketId).totalSupplyAssets,
                uint256(core.market(marketId).totalSupplyAssets) + 1 ether
            )
        );
        vm.prank(USER);
        vault2.deposit(1 ether, USER);
        assertEq(_vaultState(), beforeState);
        vm.prank(USER);
        vault2.withdraw(1 ether, USER, USER);
        _setSupplyCap(m, 0);
        vm.prank(USER);
        vault2.deposit(1 ether, USER);
    }

    /// @notice Freezing the Lido market blocks new borrowing while all four ERC-4626 operations remain available.
    function test_metaMorphoV2_freezePreservesLenderOperations() public {
        _seedInterestPosition(5 ether);
        _configureFees();
        _freezeViaSteward(m, _appointSteward(m, "metaMorphoV2.steward"));
        vm.expectRevert(ILidoLendMarketController.MarketIsFrozen.selector);
        vm.prank(BORROWER);
        core.borrow(params, 1 ether, 0, BORROWER, BORROWER);
        for (uint8 action; action < 4; ++action) {
            vm.warp(block.timestamp + 1 days);
            _assertVaultAction(action, 0.1 ether);
        }
    }

    /// @notice Pause preserves idle exits but blocks core-dependent transfers; resume restores normal use.
    function test_metaMorphoV2_pauseBlocksCoreButPreservesIdleExit() public {
        _seedInterestPosition(5 ether);
        _assertDirectDeallocation(params, 1 ether, ALLOCATOR);
        _pauseViaResealManager(m, 7 days);
        vm.warp(block.timestamp + 1 days);
        assertGt(vault2.totalAssets(), 0, "read-only interest quote does not call controller hooks");
        _fundLoan(USER, 1 ether);
        bytes32 beforeState = _vaultState();
        vm.expectRevert(PausableUntil.ResumedExpected.selector);
        vm.prank(USER);
        vault2.deposit(1 ether, USER);
        assertEq(_vaultState(), beforeState);
        vm.expectRevert(PausableUntil.ResumedExpected.selector);
        vm.prank(USER);
        vault2.withdraw(2 ether, USER, USER);
        vm.expectRevert(PausableUntil.ResumedExpected.selector);
        vm.prank(USER);
        vault2.forceDeallocate(adapterAddr, abi.encode(params), 1 ether, USER);
        assertEq(_vaultState(), beforeState);
        vm.prank(USER);
        vault2.withdraw(0.5 ether, USER, USER);
        assertEq(m.loanToken.balanceOf(USER), 1.5 ether);
        vm.prank(_resealManager());
        m.controller.resume();
        _depositAndWithdrawWithPendingInterest();
    }

    /// @notice A USDT/USDY vault handles 6-decimal, no-return USDT with fees and rejects other loan tokens.
    function test_metaMorphoV2_usdtVaultHandlesSixDecimalsAndNoReturnToken() public {
        MarketParams memory wethParams = params;
        m = _bindMarket(_marketForRole("usdy-usdt"));
        core = m.core;
        params = m.params;
        marketId = m.id;
        assertEq(params.loanToken, _ext("usdt"));
        _createVaultFromFactory();
        _configureVault();
        _fundLoan(USER, 10_000e6);
        vm.prank(USER);
        m.loanToken.forceApprove(address(vault2), type(uint256).max);
        vm.prank(USER);
        vault2.deposit(10_000e6, USER);
        vm.prank(ALLOCATOR);
        vault2.allocate(adapterAddr, abi.encode(params), 10_000e6);
        _openBorrowInMarket(m, BORROWER, 5_000e6);
        vm.prank(ALLOCATOR);
        vault2.setLiquidityAdapterAndData(adapterAddr, abi.encode(params));
        _configureFees();
        assertEq(vault2.virtualShares(), 1e12);
        for (uint8 action; action < 4; ++action) {
            vm.warp(block.timestamp + 1 days);
            _assertPendingQuoteMatchesAccrual();
            _assertVaultAction(action, action == 1 || action == 3 ? 100e18 : 100e6);
        }
        _assertDirectDeallocation(params, 100e6, ALLOCATOR);
        vm.expectRevert(ILidoLendV1AdapterV2.LoanAssetMismatch.selector);
        vm.prank(ALLOCATOR);
        vault2.allocate(adapterAddr, abi.encode(wethParams), 0);
    }

    /// @notice Two WETH markets keep correct accounting through rebalancing, route changes and re-entry.
    function testFuzz_metaMorphoV2_multiMarketRebalancesAndClosesOneMarket(uint256 shifted, uint256 elapsed) public {
        shifted = bound(shifted, 0.1 ether, 2 ether);
        elapsed = bound(elapsed, 1 hours, 7 days);
        BoundMarket memory second = _createSecondaryMarket();
        assertEq(second.params.loanToken, params.loanToken);
        assertEq(second.params.collateralToken, params.collateralToken);
        assertEq(address(second.core), address(core));
        assertTrue(Id.unwrap(second.id) != Id.unwrap(marketId));
        _enableCap(_idData(second.params, 2));
        _seedInterestPosition(5 ether);
        _fundLoan(USER, 10 ether);
        vm.prank(USER);
        vault2.deposit(10 ether, USER);
        _assertDirectDeallocation(params, 6 ether, ALLOCATOR);
        vm.prank(ALLOCATOR);
        vault2.allocate(adapterAddr, abi.encode(second.params), 6 ether);
        address secondBorrower = _freshActor(second, "metaMorphoV2.secondBorrower");
        _openBorrowInMarket(second, secondBorrower, 3 ether);
        vm.warp(block.timestamp + elapsed);
        _assertTwoMarketAccounting(second.params);

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(vault2.deallocate, (adapterAddr, abi.encode(params), shifted));
        calls[1] = abi.encodeCall(vault2.allocate, (adapterAddr, abi.encode(second.params), shifted));
        uint256 idleBefore = m.loanToken.balanceOf(address(vault2));
        uint256 firstShares = adapter.supplyShares(Id.unwrap(marketId));
        uint256 secondShares = adapter.supplyShares(Id.unwrap(second.id));
        vm.prank(ALLOCATOR);
        vault2.multicall(calls);
        assertEq(m.loanToken.balanceOf(address(vault2)), idleBefore);
        assertLt(adapter.supplyShares(Id.unwrap(marketId)), firstShares);
        assertGt(adapter.supplyShares(Id.unwrap(second.id)), secondShares);
        _assertTwoMarketAccounting(second.params);

        vm.prank(ALLOCATOR);
        vault2.setLiquidityAdapterAndData(adapterAddr, abi.encode(second.params));
        firstShares = adapter.supplyShares(Id.unwrap(marketId));
        _fundLoan(USER, 1 ether);
        vm.prank(USER);
        vault2.deposit(1 ether, USER);
        vm.prank(USER);
        vault2.withdraw(0.5 ether, USER, USER);
        assertEq(adapter.supplyShares(Id.unwrap(marketId)), firstShares, "liquidity route changes only its market");
        _assertTwoMarketAccounting(second.params);

        _repayBorrower(second, secondBorrower);
        _assertDirectDeallocation(second.params, adapter.expectedSupplyAssets(Id.unwrap(second.id)), ALLOCATOR);
        assertEq(adapter.marketIdsLength(), 1);
        assertEq(adapter.marketIds(0), Id.unwrap(marketId));
        assertEq(vault2.allocation(keccak256(_idData(second.params, 2))), 0);
        assertEq(adapter.realAssets(), adapter.expectedSupplyAssets(Id.unwrap(marketId)));
        vm.prank(ALLOCATOR);
        vault2.allocate(adapterAddr, abi.encode(second.params), 1 ether);
        _assertTwoMarketAccounting(second.params);
        assertEq(adapter.marketIdsLength(), 2);
        assertTrue(adapter.marketIds(0) != adapter.marketIds(1), "re-entry does not duplicate a market");
    }

    /// @notice At full utilization, a solver exits into core shares and a direct lender settles into collateral.
    function test_metaMorphoV2_allocatesIntoForkAndForceDeallocates() public {
        uint256 directSupplyShares = _seedVaultAndDirectLender();
        _seedBorrowersAndDrainLiquidity();

        // The vault-allocate + direct-lender supply are now fully borrowed out. Read the market's own free
        // liquidity, not the core's token balance: one core hosts many markets, so its balance is not this
        // market's liquidity.
        assertEq(_freeLiquidity(m), 0, "Lido market fully utilized");

        // Point the vault's exit path at the adapter. Without this, `exit` never consults the Lido market at all
        // — it transfers from its own idle balance and fails there — so the revert below would say nothing about
        // the market being drained. Set here rather than in `_configureVault` because a liquidity adapter also
        // auto-allocates on deposit, which would collide with the explicit allocate in the seeding step.
        vm.prank(ALLOCATOR);
        vault2.setLiquidityAdapterAndData(adapterAddr, abi.encode(params));

        // Now the withdraw reaches the core, and the core refuses: the market has nothing to lend back.
        vm.expectRevert(bytes("insufficient liquidity"));
        vm.prank(USER);
        vault2.withdraw(10 ether, USER, USER);

        _forceDeallocateVaultUser();
        _settleDirectLenderAndAssert(directSupplyShares);

        assertGt(core.position(marketId, USER).supplyShares, 0, "direct market position remains with user");
        assertEq(vault2.balanceOf(USER), 0, "user exited vault shares");
        assertEq(m.loanToken.balanceOf(SOLVER), 10 ether, "solver can repay temporary liquidity");
    }

    /// @dev USER deposits into the vault, the allocator routes it into the Lido market via the adapter, and a
    ///      direct lender supplies straight into the core. Returns that lender's shares for the fallback settle.
    function _seedVaultAndDirectLender() internal returns (uint256 directSupplyShares) {
        uint256 vaultIdleBefore = m.loanToken.balanceOf(address(vault2));
        _fundLoan(USER, 10 ether);
        vm.prank(USER);
        m.loanToken.approve(address(vault2), type(uint256).max);
        vm.prank(USER);
        uint256 vaultShares = vault2.deposit(10 ether, USER);
        assertGt(vaultShares, 0, "vault shares minted");

        uint256 adapterSupplyBefore = adapter.expectedSupplyAssets(Id.unwrap(marketId));
        vm.prank(ALLOCATOR);
        vault2.allocate(adapterAddr, abi.encode(params), 10 ether);

        assertEq(m.loanToken.balanceOf(address(vault2)), vaultIdleBefore, "vault allocated the deposited idle assets");
        assertEq(
            adapter.expectedSupplyAssets(Id.unwrap(marketId)) - adapterSupplyBefore,
            10 ether,
            "adapter supplied into Lido fork"
        );

        _fundLoan(DIRECT_LENDER, 5 ether);
        vm.prank(DIRECT_LENDER);
        m.loanToken.approve(address(core), type(uint256).max);
        vm.prank(DIRECT_LENDER);
        core.supply(params, 5 ether, 0, DIRECT_LENDER, "");

        directSupplyShares = core.position(marketId, DIRECT_LENDER).supplyShares;
        assertGt(directSupplyShares, 0, "direct lender supplied into Lido fork");
    }

    /// @dev Both borrowers supply live-price-sized collateral; only BORROWER draws debt, borrowing exactly the
    ///      measured free liquidity so the core empties. LOW_LTV_BORROWER stays a collateral-only participant the
    ///      settle never touches. Requires BORROWER to be the settle-queue root (see the settle helper).
    function _seedBorrowersAndDrainLiquidity() internal {
        // Measure everything the vault + direct lender put in; the loan token is WETH, so the collateral supplies
        // below do not move it. Borrowing exactly this empties the core at whatever the live level is.
        uint256 drain = _freeLiquidity(m);
        uint256 collateral = _collateralFor(drain);

        _supplyCollateral(BORROWER, collateral);
        _supplyCollateral(LOW_LTV_BORROWER, collateral);

        _warpPastActivation(m);

        uint256 borrowerLoanBefore = m.loanToken.balanceOf(BORROWER);
        vm.prank(BORROWER);
        core.borrow(params, drain, 0, BORROWER, BORROWER);
        assertEq(m.loanToken.balanceOf(BORROWER) - borrowerLoanBefore, drain, "borrower received borrowed liquidity");

        // The direct-lender fallback settle names BORROWER, but the policy only cuts the settlement-queue ROOT
        // (a non-root borrower gets a zero allowed slice). On this quiet market BORROWER is the sole debtor, so it
        // must be the root; assert it so a pre-existing riskier borrower cannot silently starve the cut.
        (address root,) = m.controller.nextSettlementBorrower(0);
        require(
            root == BORROWER,
            "MetaMorphoV2Integration: a pre-existing borrower outranks the test borrower in the settle queue"
        );
    }

    /// @dev Injects temporary market liquidity so the fully-utilized vault user can be force-deallocated: SOLVER
    ///      supplies 10 WETH on USER's behalf (giving USER a direct supply position and the core 10 WETH to
    ///      withdraw), then forceDeallocate pulls the adapter's 10 WETH back to the vault (asserted as deltas)
    ///      and USER withdraws it to SOLVER so the temporary liquidity can be repaid.
    function _forceDeallocateVaultUser() internal {
        _fundLoan(SOLVER, 10 ether);
        vm.prank(SOLVER);
        m.loanToken.approve(address(core), type(uint256).max);
        vm.prank(SOLVER);
        core.supply(params, 10 ether, 0, USER, "");

        assertGt(core.position(marketId, USER).supplyShares, 0, "user got direct Lido market supply shares");

        uint256 adapterSupplyBefore = adapter.expectedSupplyAssets(Id.unwrap(marketId));
        uint256 vaultIdleBefore = m.loanToken.balanceOf(address(vault2));
        vault2.forceDeallocate(adapterAddr, abi.encode(params), 10 ether, USER);

        assertEq(
            adapterSupplyBefore - adapter.expectedSupplyAssets(Id.unwrap(marketId)),
            10 ether,
            "adapter deallocated from Lido fork"
        );
        assertEq(
            m.loanToken.balanceOf(address(vault2)) - vaultIdleBefore, 10 ether, "vault received deallocated assets"
        );

        vm.prank(USER);
        vault2.withdraw(10 ether, SOLVER, USER);
    }

    /// @dev The direct lender settles against BORROWER for exactly the cut the DEPLOYED settlement policy quotes.
    ///      That cut is a slice of the debt, not the lender's whole position — `sliceFloorAssets` is 0 on this
    ///      market, so the root cut comes from `sliceFloorBps` / `ltvStepBps` alone. The outputs are recomputed
    ///      from the pre-call market totals rather than compared against a hardcoded band, so the assertion
    ///      tracks whatever the committed policy says.
    function _settleDirectLenderAndAssert(uint256 supplyShares) internal {
        uint256 directCollateralBefore = m.collateralToken.balanceOf(DIRECT_LENDER);
        uint256 borrowerRawCollateralBefore = core.position(marketId, BORROWER).collateral;
        uint256 directSupplySharesBefore = core.position(marketId, DIRECT_LENDER).supplyShares;
        (, SettlementSlice memory slice) = m.controller.nextSettlementBorrower(supplyShares);
        require(slice.borrowShares != 0, "MetaMorphoV2Integration: policy quotes no cut for the direct lender");

        Market memory marketBefore = core.market(marketId);
        uint256 price = m.oracle.price();

        vm.prank(DIRECT_LENDER);
        (uint256 collateralSeized, uint256 debtCanceled,,) =
            core.settle(params, slice.borrowShares, DIRECT_LENDER, BORROWER, DIRECT_LENDER);

        assertEq(
            debtCanceled,
            SharesMathLib.toAssetsUp(
                slice.borrowShares, marketBefore.totalBorrowAssets, marketBefore.totalBorrowShares
            ),
            "debt canceled is the up-rounded value of the quoted cut"
        );
        assertEq(
            collateralSeized,
            Math.mulDiv(
                SharesMathLib.toAssetsDown(
                    slice.borrowShares, marketBefore.totalBorrowAssets, marketBefore.totalBorrowShares
                ),
                ORACLE_PRICE_SCALE,
                price
            ),
            "collateral seized is the down-rounded cut priced at the oracle"
        );
        assertEq(
            directSupplySharesBefore - core.position(marketId, DIRECT_LENDER).supplyShares,
            slice.supplyShares,
            "direct lender burned exactly the supply shares the policy sized"
        );
        assertEq(
            m.collateralToken.balanceOf(DIRECT_LENDER),
            directCollateralBefore + collateralSeized,
            "direct lender received collateral"
        );
        assertEq(
            core.position(marketId, BORROWER).collateral,
            borrowerRawCollateralBefore - collateralSeized,
            "settle debited borrower collateral"
        );
    }

    // ---
    // SETUP HELPERS
    // ---

    function _configureFees() internal {
        vm.startPrank(core.owner());
        core.setFeeRecipient(CORE_FEE_RECIPIENT);
        if (core.market(marketId).fee != 0.1e18) core.setFee(params, 0.1e18);
        vm.stopPrank();
        _executeTimelocked(abi.encodeCall(vault2.setPerformanceFeeRecipient, (PERFORMANCE_RECIPIENT)));
        _executeTimelocked(abi.encodeCall(vault2.setManagementFeeRecipient, (MANAGEMENT_RECIPIENT)));
        _executeTimelocked(abi.encodeCall(vault2.setPerformanceFee, (PERFORMANCE_FEE)));
        _executeTimelocked(abi.encodeCall(vault2.setManagementFee, (MANAGEMENT_FEE)));
    }

    /// @dev Independent ERC-4626 and fee model: distributed assets are rate-capped, fees dilute vault shares.
    function _vaultQuote() internal view returns (VaultQuote memory q) {
        return _vaultQuoteForAssets(m.loanToken.balanceOf(address(vault2)) + adapter.realAssets());
    }

    function _vaultQuoteForAssets(uint256 realAssets) internal view returns (VaultQuote memory q) {
        assertEq(vault2.firstTotalAssets(), 0, "separate user transaction must re-read the adapter");
        uint256 elapsed = block.timestamp - vault2.lastUpdate();
        uint256 previousAssets = vault2._totalAssets();
        uint256 ceiling = previousAssets + Math.mulDiv(previousAssets * elapsed, vault2.maxRate(), WAD);
        q.assets = Math.min(realAssets, ceiling);
        uint256 interest = q.assets > previousAssets ? q.assets - previousAssets : 0;
        uint256 performanceAssets = Math.mulDiv(interest, PERFORMANCE_FEE, WAD);
        uint256 managementAssets = Math.mulDiv(q.assets * elapsed, MANAGEMENT_FEE, WAD);
        uint256 numerator = vault2.totalSupply() + vault2.virtualShares();
        uint256 denominator = q.assets - performanceAssets - managementAssets + 1;
        q.performanceShares = Math.mulDiv(performanceAssets, numerator, denominator);
        q.managementShares = Math.mulDiv(managementAssets, numerator, denominator);
        q.supply = vault2.totalSupply() + q.performanceShares + q.managementShares;
    }

    /// @dev Actions are deposit, mint, withdraw and redeem, each with fresh pending interest and nonzero fees.
    function _assertVaultAction(uint8 action, uint256 amount) internal {
        VaultQuote memory q = _vaultQuote();
        (uint256 total, uint256 performance, uint256 management) = vault2.accrueInterestView();
        assertEq(total, q.assets);
        assertEq(performance, q.performanceShares);
        assertEq(management, q.managementShares);
        assertEq(vault2.totalAssets(), q.assets);
        bool entering = action < 2;
        uint256 assets = amount;
        uint256 shares = amount;
        if (action == 0 || action == 2) {
            shares = Math.mulDiv(
                amount,
                q.supply + vault2.virtualShares(),
                q.assets + 1,
                action == 0 ? Math.Rounding.Floor : Math.Rounding.Ceil
            );
            assertEq(action == 0 ? vault2.previewDeposit(amount) : vault2.previewWithdraw(amount), shares);
        } else {
            assets = Math.mulDiv(
                amount,
                q.assets + 1,
                q.supply + vault2.virtualShares(),
                action == 1 ? Math.Rounding.Ceil : Math.Rounding.Floor
            );
            assertEq(action == 1 ? vault2.previewMint(amount) : vault2.previewRedeem(amount), assets);
        }
        if (entering) _fundLoan(USER, assets);
        VaultActionState memory before_ = VaultActionState({
            balance: m.loanToken.balanceOf(USER),
            shares: vault2.balanceOf(USER),
            tracked: adapter.supplyShares(Id.unwrap(marketId)),
            idle: m.loanToken.balanceOf(address(vault2)),
            coreUpdated: core.market(marketId).lastUpdate,
            performance: vault2.balanceOf(PERFORMANCE_RECIPIENT),
            management: vault2.balanceOf(MANAGEMENT_RECIPIENT)
        });
        vm.expectCall(adapterAddr, abi.encodeCall(adapter.realAssets, ()));
        vm.prank(USER);
        if (action == 0) assertEq(vault2.deposit(assets, USER), shares);
        else if (action == 1) assertEq(vault2.mint(shares, USER), assets);
        else if (action == 2) assertEq(vault2.withdraw(assets, USER, USER), shares);
        else assertEq(vault2.redeem(shares, USER, USER), assets);
        assertEq(m.loanToken.balanceOf(USER), entering ? before_.balance - assets : before_.balance + assets);
        assertEq(vault2.balanceOf(USER), entering ? before_.shares + shares : before_.shares - shares);
        assertEq(vault2.balanceOf(PERFORMANCE_RECIPIENT), before_.performance + q.performanceShares);
        assertEq(vault2.balanceOf(MANAGEMENT_RECIPIENT), before_.management + q.managementShares);
        assertEq(vault2.totalSupply(), entering ? q.supply + shares : q.supply - shares);
        assertEq(vault2._totalAssets(), entering ? q.assets + assets : q.assets - assets);
        if (entering) {
            assertGt(adapter.supplyShares(Id.unwrap(marketId)), before_.tracked);
        } else if (assets > before_.idle) {
            assertLt(adapter.supplyShares(Id.unwrap(marketId)), before_.tracked);
        } else {
            assertEq(adapter.supplyShares(Id.unwrap(marketId)), before_.tracked, "idle exit leaves adapter unchanged");
        }
        assertEq(
            core.market(marketId).lastUpdate, entering || assets > before_.idle ? block.timestamp : before_.coreUpdated
        );
    }

    function _configureVault() internal {
        assertEq(vault2.owner(), address(this), "factory assigns the requested owner");
        assertEq(vault2.curator(), address(0), "factory creates an unconfigured vault");
        vault2.setCurator(CURATOR);

        _executeTimelocked(abi.encodeCall(vault2.setIsAllocator, (ALLOCATOR, true)));
        _registerAdapter();
        vm.prank(ALLOCATOR);
        vault2.setMaxRate(2e18 / uint256(365 days));
    }

    function _registerAdapter() internal {
        _executeTimelocked(abi.encodeCall(vault2.addAdapter, (adapterAddr)));

        _enableCap(abi.encode("this", adapterAddr));
        _enableCap(abi.encode("collateralToken", params.collateralToken));
        _enableCap(abi.encode("this/marketParams", adapterAddr, params));
    }

    function _createVaultFromFactory() internal {
        IMorphoVaultV2Factory factory = IMorphoVaultV2Factory(_ext("morphoVaultV2Factory"));
        require(address(factory).code.length != 0, "Morpho Vault V2 factory missing at the fork block");
        vault2 =
            IMorphoVaultV2(factory.createVaultV2(address(this), params.loanToken, keccak256("lido-lend-v2-example")));
        assertTrue(factory.isVaultV2(address(vault2)), "vault was created by the real external factory");
        assertGt(address(vault2).code.length, 0);
        assertEq(vault2.asset(), params.loanToken, "vault asset matches the bound market");
        adapterAddr = address(new LidoLendV1AdapterV2(address(vault2), address(core), irmRouter));
        adapter = LidoLendV1AdapterV2(adapterAddr);
        assertEq(adapter.parentVault(), address(vault2));
        assertEq(adapter.morpho(), address(core));
        assertEq(adapter.asset(), params.loanToken);
        assertEq(adapter.irm(), params.irm);
        assertEq(m.loanToken.allowance(adapterAddr, address(core)), type(uint256).max);
        assertEq(m.loanToken.allowance(adapterAddr, address(vault2)), type(uint256).max);
    }

    function _accruedMarket(MarketParams memory marketParams) internal returns (Market memory accrued) {
        uint256 snapshot = vm.snapshotState();
        core.accrueInterest(marketParams);
        accrued = core.market(Id.wrap(keccak256(abi.encode(marketParams))));
        assertTrue(vm.revertToStateAndDelete(snapshot));
    }

    function _shareValue(Market memory totals, uint256 shares) internal pure returns (uint256) {
        return Math.mulDiv(
            shares,
            uint256(totals.totalSupplyAssets) + SharesMathLib.VIRTUAL_ASSETS,
            uint256(totals.totalSupplyShares) + SharesMathLib.VIRTUAL_SHARES
        );
    }

    function _sharesUp(Market memory totals, uint256 assets) internal pure returns (uint256) {
        return Math.mulDiv(
            assets,
            uint256(totals.totalSupplyShares) + SharesMathLib.VIRTUAL_SHARES,
            uint256(totals.totalSupplyAssets) + SharesMathLib.VIRTUAL_ASSETS,
            Math.Rounding.Ceil
        );
    }

    function _idData(MarketParams memory marketParams, uint256 index) internal view returns (bytes memory) {
        if (index == 0) return abi.encode("this", adapterAddr);
        if (index == 1) return abi.encode("collateralToken", marketParams.collateralToken);
        return abi.encode("this/marketParams", adapterAddr, marketParams);
    }

    function _assertAllocations(MarketParams memory marketParams, uint256 expected) internal view {
        for (uint256 i; i < 3; ++i) {
            assertEq(vault2.allocation(keccak256(_idData(marketParams, i))), expected);
        }
    }

    function _assertDirectDeallocation(MarketParams memory marketParams, uint256 assets, address caller) internal {
        Id id = Id.wrap(keccak256(abi.encode(marketParams)));
        DeallocationState memory before_;
        before_.accrued = _accruedMarket(marketParams);
        before_.marketState = keccak256(abi.encode(core.market(id)));
        before_.trackedShares = adapter.supplyShares(Id.unwrap(id));
        before_.coreShares = core.position(id, adapterAddr).supplyShares;
        before_.idle = m.loanToken.balanceOf(address(vault2));
        before_.adapterBalance = m.loanToken.balanceOf(adapterAddr);
        before_.vaultAssets = vault2._totalAssets();
        before_.vaultShares = vault2.totalSupply();
        before_.vaultLastUpdate = vault2.lastUpdate();
        bytes32[] memory ids = new bytes32[](3);
        for (uint256 i; i < 3; ++i) {
            ids[i] = keccak256(_idData(marketParams, i));
            before_.allocations[i] = vault2.allocation(ids[i]);
        }
        uint256 burned = assets == 0 ? 0 : _sharesUp(before_.accrued, assets);
        before_.accrued.totalSupplyAssets -= uint128(assets);
        before_.accrued.totalSupplyShares -= uint128(burned);
        uint256 expectedValue = _shareValue(before_.accrued, before_.trackedShares - burned);
        int256 change = int256(expectedValue) - int256(before_.allocations[2]);
        vm.expectEmit(true, true, false, true, address(vault2));
        emit Deallocate(caller, adapterAddr, assets, ids, change);
        vm.prank(caller);
        vault2.deallocate(adapterAddr, abi.encode(marketParams), assets);
        for (uint256 i; i < 3; ++i) {
            assertEq(vault2.allocation(ids[i]), uint256(int256(before_.allocations[i]) + change));
        }
        assertEq(adapter.supplyShares(Id.unwrap(id)), before_.trackedShares - burned);
        assertEq(core.position(id, adapterAddr).supplyShares, before_.coreShares - burned);
        assertEq(m.loanToken.balanceOf(address(vault2)), before_.idle + assets);
        assertEq(m.loanToken.balanceOf(adapterAddr), before_.adapterBalance);
        assertEq(adapter.expectedSupplyAssets(Id.unwrap(id)), expectedValue);
        assertEq(vault2._totalAssets(), before_.vaultAssets, "direct deallocation does not accrue the vault");
        assertEq(vault2.totalSupply(), before_.vaultShares);
        assertEq(vault2.lastUpdate(), before_.vaultLastUpdate);
        if (assets == 0) assertEq(keccak256(abi.encode(core.market(id))), before_.marketState);
        else assertEq(abi.encode(core.market(id)), abi.encode(before_.accrued));
    }

    function _vaultState() internal view returns (bytes32) {
        uint256[3] memory allocations;
        for (uint256 i; i < 3; ++i) {
            allocations[i] = vault2.allocation(keccak256(_idData(params, i)));
        }
        return keccak256(
            abi.encode(
                core.market(marketId),
                core.position(marketId, adapterAddr),
                adapter.supplyShares(Id.unwrap(marketId)),
                allocations,
                vault2._totalAssets(),
                vault2.totalSupply(),
                vault2.balanceOf(USER),
                m.loanToken.balanceOf(USER),
                m.loanToken.balanceOf(address(vault2)),
                m.loanToken.balanceOf(adapterAddr)
            )
        );
    }

    function _executeAdapterTimelocked(bytes memory data) internal {
        vm.prank(CURATOR);
        adapter.submit(data);
        (bool success, bytes memory result) = address(adapter).call(data);
        if (!success) assembly ("memory-safe") { revert(add(result, 32), mload(result)) }
    }

    /// @dev Reuse the primary market's dependencies and policy on the same core. A one-unit LLTV difference
    ///      gives this disposable fixture its own id without requiring a separately provisioned market.
    function _createSecondaryMarket() internal returns (BoundMarket memory second) {
        second = m;
        assertGt(second.params.lltv, 1);
        second.params.lltv -= 1;
        second.id = Id.wrap(keccak256(abi.encode(second.params)));
        assertEq(core.market(second.id).lastUpdate, 0, "secondary fixture market must not already exist");

        LidoLendMarketFactory.MarketSpec memory spec = LidoLendMarketFactory.MarketSpec({
            loanToken: second.params.loanToken,
            collateralToken: second.params.collateralToken,
            oracle: second.params.oracle,
            lltv: second.params.lltv,
            guardianSignals: address(second.guardianSignals),
            supplyCap: m.controller.supplyCap(),
            activationConfig: second.activation,
            settlementConfig: m.controller.settlementConfig()
        });
        LidoLendMarketFactory factory = LidoLendMarketFactory(_protocol("factory"));
        LidoLendMarketFactory.ERC4626WrapperSpec memory wrapperSpec = LidoLendMarketFactory.ERC4626WrapperSpec({
            name: "Lido Vault V2 Secondary Test Market", symbol: "lidoV2-SECONDARY"
        });
        (Id deployedId, address controller, address wrapper) = factory.deployMarketComponents(spec, wrapperSpec);
        assertEq(Id.unwrap(deployedId), Id.unwrap(second.id), "factory derives the expected market id");
        second.controller = ILidoLendMarketController(controller);
        second.vault = ILidoLendERC4626(wrapper);
        _activateSecondaryMarket(second);

        assertEq(abi.encode(core.idToMarketParams(second.id)), abi.encode(second.params));
        assertEq(core.marketController(second.id), controller);
        assertEq(core.market(second.id).lastUpdate, block.timestamp);
        assertEq(core.isSettlementEnabled(second.id), core.isSettlementEnabled(marketId));
        assertEq(second.controller.supplyCap(), spec.supplyCap);
        assertEq(abi.encode(second.controller.collateralActivationConfig()), abi.encode(spec.activationConfig));
        assertEq(abi.encode(second.controller.settlementConfig()), abi.encode(spec.settlementConfig));
        factory.validateERC4626Wrapper(wrapper, controller, second.params);
    }

    /// @dev Apply the existing immutable curve config before routing and creation: createMarket pings the IRM.
    ///      Privileged calls use the deployed executor, and the new controller inherits the primary pauser.
    function _activateSecondaryMarket(BoundMarket memory second) internal {
        IIrmRouter router = IIrmRouter(irmRouter);
        IAdaptiveCurveIrm curve = IAdaptiveCurveIrm(_protocol("adaptive_curve_irm"));
        IrmId primaryId = IrmId.wrap(Id.unwrap(marketId));
        assertEq(address(router.marketIrm(primaryId)), address(curve));
        address config = address(curve.marketCurveConfig(primaryId));
        assertNotEq(config, address(0), "primary market has an adaptive curve config");
        IrmMarketParams memory routedParams = abi.decode(abi.encode(second.params), (IrmMarketParams));
        ICircuitBreakerPausers breaker = ICircuitBreakerPausers(_protocol("circuit_breaker"));
        address pauser = breaker.getPauser(address(m.controller));
        assertNotEq(pauser, address(0), "primary controller has a pauser committee");
        ILidoLendOwner owner = _facade();
        bool settlementEnabled = core.isSettlementEnabled(marketId);

        vm.startPrank(_executor());
        curve.applyIrmConfig(routedParams, config);
        router.setMarketIrm(routedParams, RoutedIIrm(address(curve)));
        owner.createMarket(second.params, address(second.controller), settlementEnabled);
        breaker.registerPauser(address(second.controller), pauser);
        vm.stopPrank();

        IrmId secondaryId = IrmId.wrap(Id.unwrap(second.id));
        assertEq(address(router.marketIrm(secondaryId)), address(curve));
        assertEq(address(curve.marketCurveConfig(secondaryId)), config);
        assertEq(breaker.getPauser(address(second.controller)), pauser);
    }

    function _openBorrowInMarket(BoundMarket memory target, address borrower, uint256 debt) internal {
        uint256 valueNeeded = Math.mulDiv(debt, 2 * WAD, target.params.lltv, Math.Rounding.Ceil);
        uint256 collateral = Math.max(
            Math.mulDiv(valueNeeded, ORACLE_PRICE_SCALE, target.oracle.price(), Math.Rounding.Ceil),
            2 * uint256(target.activation.minActivationAmount)
        );
        deal(address(target.collateralToken), borrower, collateral);
        vm.startPrank(borrower);
        target.collateralToken.forceApprove(address(core), collateral);
        core.supplyCollateral(target.params, collateral, borrower, "");
        vm.stopPrank();
        _warpPastActivation(target);
        vm.expectCall(address(target.oracle), abi.encodeCall(target.oracle.price, ()));
        vm.prank(borrower);
        core.borrow(target.params, debt, 0, borrower, borrower);
    }

    function _repayBorrower(BoundMarket memory target, address borrower) internal {
        uint256 shares = core.position(target.id, borrower).borrowShares;
        Market memory totals = _accruedMarket(target.params);
        uint256 assets = Math.mulDiv(
            shares,
            uint256(totals.totalBorrowAssets) + SharesMathLib.VIRTUAL_ASSETS,
            uint256(totals.totalBorrowShares) + SharesMathLib.VIRTUAL_SHARES,
            Math.Rounding.Ceil
        );
        _fundLoan(borrower, assets);
        vm.startPrank(borrower);
        target.loanToken.forceApprove(address(core), assets);
        (uint256 repaid, uint256 burned) = core.repay(target.params, 0, shares, borrower, "");
        vm.stopPrank();
        assertEq(repaid, assets);
        assertEq(burned, shares);
        assertEq(core.position(target.id, borrower).borrowShares, 0);
    }

    function _assertTwoMarketAccounting(MarketParams memory secondParams) internal {
        Id secondId = Id.wrap(keccak256(abi.encode(secondParams)));
        uint256 first = _shareValue(_accruedMarket(params), adapter.supplyShares(Id.unwrap(marketId)));
        uint256 second = _shareValue(_accruedMarket(secondParams), adapter.supplyShares(Id.unwrap(secondId)));
        assertEq(adapter.realAssets(), first + second);
        uint256 real = m.loanToken.balanceOf(address(vault2)) + first + second;
        uint256 ceiling = vault2._totalAssets()
            + Math.mulDiv(
                uint256(vault2._totalAssets()) * (block.timestamp - vault2.lastUpdate()), vault2.maxRate(), WAD
            );
        assertEq(vault2.totalAssets(), Math.min(real, ceiling));
        _assertDirectDeallocation(params, 0, ALLOCATOR);
        _assertDirectDeallocation(secondParams, 0, ALLOCATOR);
        assertEq(vault2.allocation(keccak256(_idData(params, 0))), first + second);
        assertEq(vault2.allocation(keccak256(_idData(params, 1))), first + second);
        assertEq(vault2.allocation(keccak256(_idData(params, 2))), first);
        assertEq(vault2.allocation(keccak256(_idData(secondParams, 2))), second);
    }

    function _seedInterestPosition(uint256 debt) internal {
        _seedVaultAndDirectLender();
        _supplyCollateral(BORROWER, _collateralFor(debt));
        _warpPastActivation(m);
        vm.expectCall(address(m.oracle), abi.encodeCall(m.oracle.price, ()));
        vm.prank(BORROWER);
        core.borrow(params, debt, 0, BORROWER, BORROWER);
        assertGt(core.position(marketId, BORROWER).borrowShares, 0, "borrower has debt");
        assertGt(adapter.supplyShares(Id.unwrap(marketId)), 0, "adapter owns tracked supply");
        vm.prank(ALLOCATOR);
        vault2.setLiquidityAdapterAndData(adapterAddr, abi.encode(params));
    }

    /// @dev Call at the adapter boundary: the vault's own realAssets query legitimately loads parameters.
    function _assertAdapterUpdateReusesParams(uint256 assets, bool withdrawing) internal {
        LidoLendV1AdapterV2 localAdapter = LidoLendV1AdapterV2(adapterAddr);
        uint256 allocationBefore = localAdapter.allocation(params);
        uint256 sharesBefore = adapter.supplyShares(Id.unwrap(marketId));
        uint256 coreSharesBefore = core.position(marketId, adapterAddr).supplyShares;
        if (!withdrawing && assets != 0) _fundLoan(adapterAddr, assets);
        uint256 balanceBefore = m.loanToken.balanceOf(adapterAddr);
        Market memory beforeMarket = core.market(marketId);

        vm.mockCallRevert(
            address(core), abi.encodeCall(core.idToMarketParams, (marketId)), bytes("unexpected params lookup")
        );
        if (assets == 0) vm.expectCall(irmRouter, abi.encodeCall(IIrm.borrowRateView, (params, beforeMarket)));
        vm.prank(address(vault2));
        (bytes32[] memory returnedIds, int256 change) = withdrawing
            ? localAdapter.deallocate(abi.encode(params), assets, bytes4(0), ALLOCATOR)
            : localAdapter.allocate(abi.encode(params), assets, bytes4(0), ALLOCATOR);
        vm.clearMockedCalls();

        assertEq(returnedIds, localAdapter.ids(params), "allocation identifiers unchanged");
        uint256 sharesAfter = adapter.supplyShares(Id.unwrap(marketId));
        assertEq(
            int256(sharesAfter) - int256(sharesBefore),
            int256(core.position(marketId, adapterAddr).supplyShares) - int256(coreSharesBefore),
            "tracked shares follow actual minted or burned shares"
        );
        assertEq(
            m.loanToken.balanceOf(adapterAddr),
            withdrawing ? balanceBefore + assets : balanceBefore - assets,
            "adapter transfers exactly the requested assets"
        );
        if (assets == 0) {
            assertEq(sharesAfter, sharesBefore, "zero amount preserves shares");
            assertEq(abi.encode(core.market(marketId)), abi.encode(beforeMarket), "zero amount only quotes interest");
        } else {
            assertEq(core.market(marketId).lastUpdate, block.timestamp, "nonzero amount accrues interest");
            if (withdrawing) assertLt(sharesAfter, sharesBefore);
            else assertGt(sharesAfter, sharesBefore);
        }

        _pokeAccrue(m);
        Market memory accruedMarket = core.market(marketId);
        uint256 expectedAssets = Math.mulDiv(
            sharesAfter,
            uint256(accruedMarket.totalSupplyAssets) + SharesMathLib.VIRTUAL_ASSETS,
            uint256(accruedMarket.totalSupplyShares) + SharesMathLib.VIRTUAL_SHARES
        );
        assertEq(change, int256(expectedAssets) - int256(allocationBefore), "delta equals accrued share value");
        assertEq(adapter.expectedSupplyAssets(Id.unwrap(marketId)), expectedAssets, "public quote agrees");
        assertEq(adapter.realAssets(), expectedAssets, "total quote agrees");
    }

    /// @dev Compare a read-only quote with actual core accrual on a snapshot, then restore pending interest.
    function _assertPendingQuoteMatchesAccrual() internal returns (uint256 quotedAssets) {
        Market memory beforeMarket = core.market(marketId);
        assertGt(beforeMarket.totalBorrowAssets, 0, "pending branch requires debt");
        assertGt(block.timestamp, beforeMarket.lastUpdate, "pending branch requires elapsed time");

        vm.expectCall(irmRouter, abi.encodeCall(IIrm.borrowRateView, (params, beforeMarket)));
        quotedAssets = adapter.realAssets();
        assertEq(adapter.expectedSupplyAssets(Id.unwrap(marketId)), quotedAssets, "one tracked market");
        assertEq(abi.encode(core.market(marketId)), abi.encode(beforeMarket), "quote leaves core unchanged");

        uint256 snapshot = vm.snapshotState();
        _pokeAccrue(m);
        Market memory afterMarket = core.market(marketId);
        uint256 expectedAssets = Math.mulDiv(
            adapter.supplyShares(Id.unwrap(marketId)),
            uint256(afterMarket.totalSupplyAssets) + SharesMathLib.VIRTUAL_ASSETS,
            uint256(afterMarket.totalSupplyShares) + SharesMathLib.VIRTUAL_SHARES
        );
        assertEq(quotedAssets, expectedAssets, "quote equals actual accrued share value");
        assertGt(afterMarket.totalSupplyAssets, beforeMarket.totalSupplyAssets, "core accrues positive interest");
        assertTrue(vm.revertToStateAndDelete(snapshot), "restore pending interest");
    }

    /// @dev Isolation resets Vault V2's transient firstTotalAssets between calls, as separate user transactions do.
    function _depositAndWithdrawWithPendingInterest() internal {
        uint256 loanBalance = m.loanToken.balanceOf(USER);
        _fundLoan(USER, 1 ether);
        uint256 userShares = vault2.balanceOf(USER);
        uint256 adapterShares = adapter.supplyShares(Id.unwrap(marketId));
        assertEq(vault2.firstTotalAssets(), 0, "vault must re-read adapters for this transaction");
        vm.expectCall(adapterAddr, abi.encodeCall(adapter.realAssets, ()));
        vm.prank(USER);
        uint256 minted = vault2.deposit(1 ether, USER);
        assertEq(vault2.balanceOf(USER), userShares + minted);
        assertGt(minted, 0);
        assertGt(adapter.supplyShares(Id.unwrap(marketId)), adapterShares, "deposit reaches adapter");
        assertEq(m.loanToken.balanceOf(USER), loanBalance, "deposit transfers the loan assets");
        assertEq(core.market(marketId).lastUpdate, block.timestamp);

        // A separate timestamp forces fresh valuation; available idle assets need not touch core.
        vm.warp(block.timestamp + 1 days);
        loanBalance = m.loanToken.balanceOf(USER);
        adapterShares = adapter.supplyShares(Id.unwrap(marketId));
        uint256 idleBefore = m.loanToken.balanceOf(address(vault2));
        uint256 coreUpdatedBefore = core.market(marketId).lastUpdate;
        assertEq(vault2.firstTotalAssets(), 0, "withdrawal must also re-read adapters");
        vm.expectCall(adapterAddr, abi.encodeCall(adapter.realAssets, ()));
        vm.prank(USER);
        uint256 burned = vault2.withdraw(1 ether, USER, USER);
        assertEq(vault2.balanceOf(USER), userShares + minted - burned);
        assertGt(burned, 0);
        if (idleBefore < 1 ether) {
            assertLt(adapter.supplyShares(Id.unwrap(marketId)), adapterShares, "withdrawal pulls from adapter");
        } else {
            assertEq(adapter.supplyShares(Id.unwrap(marketId)), adapterShares, "withdrawal uses idle assets");
        }
        assertEq(m.loanToken.balanceOf(USER), loanBalance + 1 ether);
        assertEq(core.market(marketId).lastUpdate, idleBefore < 1 ether ? block.timestamp : coreUpdatedBefore);
    }

    function _enableCap(bytes memory idData) internal {
        _executeTimelocked(abi.encodeCall(vault2.increaseAbsoluteCap, (idData, type(uint128).max)));
        _executeTimelocked(abi.encodeCall(vault2.increaseRelativeCap, (idData, WAD)));
    }

    /// @dev Submit a curator action (zero timelock on the factory-created vault) as the curator, then execute it.
    ///      The timelocked curator functions gate only on the submission, so this contract can execute them.
    function _executeTimelocked(bytes memory data) internal {
        vm.prank(CURATOR);
        vault2.submit(data);
        (bool success, bytes memory returnData) = address(vault2).call(data);
        if (!success) {
            assembly ("memory-safe") {
                revert(add(returnData, 0x20), mload(returnData))
            }
        }
    }

    // ---
    // ACTION HELPERS
    // ---

    /// @dev Collateral (in collateral units) that backs `loanAssets` at ~2x the LLTV requirement from the live
    ///      oracle price, floored at twice the activation dust threshold so the lot both activates and holds ample
    ///      borrow capacity. Mirrors {ForkStack} `_pinFreeLiquidity`'s sizing.
    function _collateralFor(uint256 loanAssets) internal view returns (uint256 collateral) {
        uint256 price = m.oracle.price();
        uint256 valueNeeded = Math.mulDiv(loanAssets, 2 * WAD, params.lltv, Math.Rounding.Ceil);
        collateral = Math.mulDiv(valueNeeded, ORACLE_PRICE_SCALE, price, Math.Rounding.Ceil);
        uint256 dustFloor = 2 * uint256(m.activation.minActivationAmount);
        if (collateral < dustFloor) collateral = dustFloor;
    }

    /// @dev Supply `collateral` (collateral units) for `who`. wstETH is non-rebasing, so `deal` sets the exact
    ///      balance the sizing computed (the same approach {ForkStack} uses for its pin borrower).
    function _supplyCollateral(address who, uint256 collateral) internal {
        deal(address(m.collateralToken), who, collateral);
        vm.startPrank(who);
        m.collateralToken.approve(address(core), collateral);
        core.supplyCollateral(params, collateral, who, "");
        vm.stopPrank();
    }

    function _fundLoan(address user, uint256 amount) internal {
        if (address(m.loanToken) == _ext("weth")) {
            vm.deal(user, amount);
            vm.prank(user);
            IWETH(address(m.loanToken)).deposit{value: amount}();
        } else {
            deal(address(m.loanToken), user, m.loanToken.balanceOf(user) + amount);
        }
    }
}
