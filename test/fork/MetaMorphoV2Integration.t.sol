// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {IVaultV2} from "@vault-v2/src/interfaces/IVaultV2.sol";
import {IMorphoMarketV1AdapterLike} from "../utils/IMorphoMarketV1AdapterLike.sol";
import {
    Id as AdapterId,
    MarketParams as AdapterMarketParams
} from "@vault-v2/lib/morpho-blue/src/interfaces/IMorpho.sol";
import {MarketParamsLib as AdapterMarketParamsLib} from "@vault-v2/lib/morpho-blue/src/libraries/MarketParamsLib.sol";

import {ILidoLend} from "@lido-lend/src/interfaces/ILidoLend.sol";
import {Id, MarketParams} from "@lido-lend/src/interfaces/IMorpho.sol";
import {ORACLE_PRICE_SCALE} from "@lido-lend/src/libraries/ConstantsLib.sol";

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {SettlementConfig} from "../../src/types/SettlementTypes.sol";
import {WAD} from "../../src/libs/Constants.sol";
import {ForkStack} from "./helpers/ForkStack.sol";

interface IWETH {
    function deposit() external payable;
}

/// @notice Mainnet-fork integration of the external vault-v2 stack with the ALREADY-DEPLOYED
///         `fork-weth-wsteth` market: a vault-v2 allocator routes deposits through the deployed Morpho adapter
///         into the Lido fork core, borrowers drain every last unit of liquidity so a plain vault withdraw
///         reverts, then `forceDeallocate` exits the vault user and a direct-lender fallback `settle` seizes the
///         borrower's collateral to exit the direct lender.
///
///         The suite deploys nothing. It binds the Lido stack via {ForkStack} and the vault-v2 pair from the
///         run's `vaults/` + `adapters/` artifacts, which the deploy leaves UNCONFIGURED (no curator, adapter,
///         or caps). Because that vault is SHARED, the suite configures it for this run against fresh test-actor
///         roles and refuses (loudly) to run against an already-configured vault.
///
///         State-robustness contract (a shared deployed market may already carry supply/borrow):
///         the drain borrows exactly the MEASURED free liquidity (`_freeLiquidity`) so the core is emptied at
///         any live level, collateral is sized from the live oracle price, adapter allocations are asserted as
///         deltas, and the fallback settle loudly requires the test borrower to be the settlement-queue root so
///         a pre-existing riskier borrower cannot starve the cut.
contract MetaMorphoV2IntegrationTest is ForkStack {
    using AdapterMarketParamsLib for AdapterMarketParams;

    BoundMarket internal m;

    // Rebound from the bound market in `setUp` so the flow reads like the freshly-deployed variant did.
    ILidoLend internal core;
    MarketParams internal params;
    Id internal marketId;

    // The deployed vault-v2 pair, and the adapter's params rebuilt from the live market params.
    IVaultV2 internal vault2;
    IMorphoMarketV1AdapterLike internal adapter;
    address internal adapterAddr;
    AdapterMarketParams internal adapterParams;

    IWETH internal WETH;

    // Role-only actors (curator/allocator hold no market position or vault shares).
    address internal CURATOR;
    address internal ALLOCATOR;

    // Market-participating actors — fresh and market-clean, so per-actor reads double as deltas.
    address internal USER;
    address internal BORROWER;
    address internal SOLVER;
    address internal DIRECT_LENDER;
    address internal LOW_LTV_BORROWER;

    /// @dev The direct-lender fallback exit cancels the direct lender's whole ~5 WETH supply in ONE settle. The
    ///      committed settlement config sizes the root cut from `sliceFloorBps` / `ltvStepBps` alone
    ///      (`sliceFloorAssets == 0`), which caps a single cut far below 5 WETH; the test raises the absolute
    ///      floor to 20 WETH at runtime, as self-granted manager, so the exit clears in one cut.
    uint96 internal constant SLICE_FLOOR_ASSETS = 20 ether;

    function setUp() public {
        _fork();
        m = _bindMarket("fork-weth-wsteth");
        _pokeAccrue(m); // fold in pending interest up front so the exact liquidity math below holds

        core = m.core;
        params = m.params;
        marketId = m.id;

        vault2 = IVaultV2(_artifactAddr("vaults/fork-weth-wsteth.toml", "vault.address"));
        adapterAddr = _artifactAddr("adapters/fork-weth-wsteth.toml", "adapter.address");
        adapter = IMorphoMarketV1AdapterLike(adapterAddr);

        // The adapter drives the SAME market the suite is bound to. The two param structs are ABI-identical
        // (both `{address loanToken, collateralToken, oracle, irm; uint256 lltv}`), so rebuild the adapter's from
        // the live core params and assert the derived id matches the bound market — a mismatch means the
        // run's vault-v2 pieces point at a different market than `fork-weth-wsteth`.
        adapterParams = AdapterMarketParams({
            loanToken: params.loanToken,
            collateralToken: params.collateralToken,
            oracle: params.oracle,
            irm: params.irm,
            lltv: params.lltv
        });
        assertEq(AdapterId.unwrap(adapterParams.id()), Id.unwrap(marketId), "adapter marketId matches the bound market");

        WETH = IWETH(address(m.loanToken));

        CURATOR = makeAddr("metaMorphoV2.curator");
        ALLOCATOR = makeAddr("metaMorphoV2.allocator");
        USER = _freshActor(m, "metaMorphoV2.user");
        BORROWER = _freshActor(m, "metaMorphoV2.borrower");
        SOLVER = _freshActor(m, "metaMorphoV2.solver");
        DIRECT_LENDER = _freshActor(m, "metaMorphoV2.directLender");
        LOW_LTV_BORROWER = _freshActor(m, "metaMorphoV2.lowLtvBorrower");

        _raiseSliceFloor();
        _configureVault();
    }

    /// @dev A vault-v2 allocator supplies into the Lido fork market via the Morpho adapter; borrowers drain all
    ///      liquidity so a plain vault withdraw reverts, then forceDeallocate exits the vault user and a
    ///      direct-lender fallback settle seizes the borrower's collateral to exit the direct lender.
    function test_metaMorphoV2_allocatesIntoForkAndForceDeallocates() public {
        uint256 directSupplyShares = _seedVaultAndDirectLender();
        _seedBorrowersAndDrainLiquidity();

        // The vault-allocate + direct-lender supply are now fully borrowed out, so the core holds no loan tokens:
        // a plain vault withdraw has nothing to pull and must revert. Assert on the CORE's balance (as the
        // original did) — on this market the core's idle loan-token balance is exactly its free liquidity.
        assertEq(m.loanToken.balanceOf(address(core)), 0, "Lido market fully utilized");

        vm.expectRevert();
        vm.prank(USER);
        vault2.withdraw(10 ether, USER, USER);

        _forceDeallocateVaultUser();
        _settleDirectLenderAndAssert(directSupplyShares);

        assertGt(core.position(marketId, USER).supplyShares, 0, "direct market position remains with user");
        assertEq(vault2.balanceOf(USER), 0, "user exited vault shares");
        assertEq(m.loanToken.balanceOf(SOLVER), 10 ether, "solver can repay temporary liquidity");
    }

    /// @dev USER deposits into the vault, the allocator routes it into the Lido market via the adapter, and a
    ///      direct lender supplies straight into the core. Adapter supply is asserted as a delta (the adapter is
    ///      shared), and the direct lender's supply shares are returned for the later fallback settle.
    function _seedVaultAndDirectLender() internal returns (uint256 directSupplyShares) {
        uint256 vaultIdleBefore = m.loanToken.balanceOf(address(vault2));

        _mintWETH(USER, 10 ether);
        vm.prank(USER);
        m.loanToken.approve(address(vault2), type(uint256).max);
        vm.prank(USER);
        uint256 vaultShares = vault2.deposit(10 ether, USER);
        assertGt(vaultShares, 0, "vault shares minted");

        uint256 adapterSupplyBefore = adapter.expectedSupplyAssets(Id.unwrap(marketId));
        vm.prank(ALLOCATOR);
        vault2.allocate(adapterAddr, abi.encode(adapterParams), 10 ether);

        assertEq(m.loanToken.balanceOf(address(vault2)), vaultIdleBefore, "vault allocated the deposited idle assets");
        assertEq(
            adapter.expectedSupplyAssets(Id.unwrap(marketId)) - adapterSupplyBefore,
            10 ether,
            "adapter supplied into Lido fork"
        );

        _mintWETH(DIRECT_LENDER, 5 ether);
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
        (address root,,,) = m.controller.nextSettlementBorrower();
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
        _mintWETH(SOLVER, 10 ether);
        vm.prank(SOLVER);
        m.loanToken.approve(address(core), type(uint256).max);
        vm.prank(SOLVER);
        core.supply(params, 10 ether, 0, USER, "");

        assertGt(core.position(marketId, USER).supplyShares, 0, "user got direct Lido market supply shares");

        uint256 adapterSupplyBefore = adapter.expectedSupplyAssets(Id.unwrap(marketId));
        uint256 vaultIdleBefore = m.loanToken.balanceOf(address(vault2));
        vault2.forceDeallocate(adapterAddr, abi.encode(adapterParams), 10 ether, USER);

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

    /// @dev The direct lender exits by settling its whole supply against BORROWER: with the core empty, the
    ///      core's "cancel up to onBehalf's supply minus free liquidity" gate lets the full ~5 WETH cut through,
    ///      backed by the raised slice floor. Collateral movements are asserted per-position.
    function _settleDirectLenderAndAssert(uint256 supplyShares) internal {
        uint256 directCollateralBefore = m.collateralToken.balanceOf(DIRECT_LENDER);
        uint256 borrowerRawCollateralBefore = core.position(marketId, BORROWER).collateral;

        vm.prank(DIRECT_LENDER);
        (uint256 collateralSeized, uint256 debtCanceled,,) =
            core.settle(params, 0, supplyShares, DIRECT_LENDER, BORROWER, DIRECT_LENDER);

        uint256 directSupplySharesAfter = core.position(marketId, DIRECT_LENDER).supplyShares;
        uint256 borrowerRawCollateralAfter = core.position(marketId, BORROWER).collateral;

        assertEq(directSupplySharesAfter, 0, "direct lender exited via fallback");
        assertTrue(debtCanceled > 4.9 ether && debtCanceled <= 5 ether, "direct lender canceled near 5 WETH debt");
        assertEq(
            m.collateralToken.balanceOf(DIRECT_LENDER),
            directCollateralBefore + collateralSeized,
            "direct lender received collateral"
        );
        assertEq(
            borrowerRawCollateralAfter,
            borrowerRawCollateralBefore - collateralSeized,
            "fallback debited borrower collateral"
        );
    }

    // ---
    // SETUP HELPERS
    // ---

    /// @dev Raise the settlement absolute floor to `SLICE_FLOOR_ASSETS`, read-modify-write over the live config so
    ///      only that knob moves. Manager-gated, so self-grant first. See the constant for why the floor is needed.
    function _raiseSliceFloor() internal {
        _grantSelfManager(m);
        SettlementConfig memory cfg = m.controller.settlementConfig();
        cfg.sliceFloorAssets = SLICE_FLOOR_ASSETS;
        m.controller.setSettlementConfig(cfg);
    }

    /// @dev Configure the SHARED, provisioned vault-v2 fixture for this run: register the adapter, authorize the
    ///      allocator, and open the caps, with a fresh test-actor curator. The provision leaves the vault
    ///      UNCONFIGURED, so probe that state first and fail loudly on an already-configured vault rather than
    ///      dying inside an opaque timelock / "already pending" revert — a re-used vault must stop the
    ///      run with a clear message. (Within one forge run each test re-forks anvil, so this only guards the
    ///      provisioned state, never leakage between tests.)
    function _configureVault() internal {
        require(
            vault2.curator() == address(0) && !vault2.isAdapter(adapterAddr) && !vault2.isAllocator(ALLOCATOR)
                && vault2.absoluteCap(keccak256(abi.encode("this", adapterAddr))) == 0,
            "MetaMorphoV2Integration: vault-v2 fixture is already configured; expected the unconfigured provision"
        );

        // setCurator is owner-gated. The provisioned vault's owner is the deploy key, not this test — prank it.
        // The curator itself stays a fresh test actor.
        vm.prank(vault2.owner());
        vault2.setCurator(CURATOR);

        _executeTimelocked(abi.encodeCall(vault2.setIsAllocator, (ALLOCATOR, true)));
        _executeTimelocked(abi.encodeCall(vault2.addAdapter, (adapterAddr)));

        _enableCap(abi.encode("this", adapterAddr));
        _enableCap(abi.encode("collateralToken", params.collateralToken));
        _enableCap(abi.encode("this/marketParams", adapterAddr, adapterParams));
    }

    function _enableCap(bytes memory idData) internal {
        _executeTimelocked(abi.encodeCall(vault2.increaseAbsoluteCap, (idData, type(uint128).max)));
        _executeTimelocked(abi.encodeCall(vault2.increaseRelativeCap, (idData, WAD)));
    }

    /// @dev Submit a curator action (zero timelock on the provisioned vault) as the curator, then execute it.
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

    function _mintWETH(address user, uint256 amount) internal {
        vm.deal(user, amount);
        vm.prank(user);
        WETH.deposit{value: amount}();
    }
}
