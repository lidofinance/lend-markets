// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Vm} from "forge-std/Vm.sol";

import {Market as MorphoMarket} from "@lido-lend/src/interfaces/IMorpho.sol";

import {LidoLendSetup} from "../setup/LidoLendSetup.sol";
import {Market} from "../setup/Types.sol";
import {ILidoLendMarketController} from "../../src/interfaces/ILidoLendMarketController.sol";

import {MockERC20, MockPriceOracle} from "../setup/Mocks.sol";
import {MarketHandler} from "./handlers/MarketHandler.sol";

/// @notice L4 stateful invariant: under any bounded sequence of supply/withdraw/collateral/borrow/repay/warp
///         actions, the market stays solvent. The two core properties:
///           - `totalSupplyAssets >= totalBorrowAssets` (never lend out more than is supplied), and
///           - the un-borrowed supply (idle) is backed by real loan tokens held by the core/vault.
///         Most actors hold instant activation so the fuzzer reaches the borrow/repay state space without fighting
///         the maturation timer. Two delayed actors keep the activation buckets and their timer in play.
/// @dev Runs REVERT-BOUNDED (`fail-on-revert = true`): every handler action self-bounds so that, for all fuzz
///      inputs including extreme ones, the underlying call never reverts. Reaching this surfaced three
///      HANDLER-bounding gaps, all fixed as genuine robustness improvements: (1) a `PositionAccountingMismatch`
///      traced to the handler over-seizing on a SOLVENT liquidation — collateral worth more than the debt
///      implies repaying more debt than exists, which the core itself rejects (there is no controller mirror;
///      the hook reads core pre-state, so the guard was faithful) — `liquidate` now caps the seize; (2)
///      share↔asset conversions now use `Math.mulDiv` to avoid intermediate overflow; and (3) the keeper
///      selection in `liquidate` added 1 to a raw `actorSeed`, which overflowed when the fuzzer supplied
///      `type(uint256).max` — it now shifts the victim's modular index instead. No core-arithmetic edge was
///      found: the panic the fuzzer hit was purely the handler's own keeper-index overflow, not a core
///      bad-debt-socialization overflow.
/// forge-config: default.invariant.fail-on-revert = true
/// forge-config: default.invariant.runs = 1000
/// forge-config: default.invariant.depth = 400
contract MarketSolvencyInvariant is LidoLendSetup {
    MarketHandler internal handler;

    address internal constant A1 = address(0x9001);
    address internal constant A2 = address(0x9002);
    address internal constant A3 = address(0x9003);
    address internal constant A4 = address(0x9004); // healthy borrower, deterministic bad-debt test only
    address internal constant D1 = address(0x9005); // delayed actor: no instant activation
    address internal constant D2 = address(0x9006); // delayed actor: no instant activation

    address[] internal actors;

    uint256 internal constant FLOOR = 10 ether; // minActivationAmount in the default config

    function setUp() public {
        MockERC20 loan = new MockERC20("Loan", "LOAN", 18);
        MockERC20 collateral = new MockERC20("Collateral", "COLL", 18);
        _deployProtocol(_defaultConfig(address(loan), address(collateral), address(collateral)));

        Market storage m = protocol.markets[0];
        actors.push(A1);
        actors.push(A2);
        actors.push(A3);
        // Instant activation for the actors → supplied collateral is immediately borrowable.
        for (uint256 i; i < actors.length; i++) {
            m.controller.setInstantActivation(actors[i], true);
        }
        actors.push(D1);
        actors.push(D2);

        handler = new MarketHandler(
            m.core,
            m.vault,
            m.controller,
            m.loanToken,
            m.collateralToken,
            m.params,
            m.id,
            oraclePrice,
            address(m.oracle),
            actors
        );
        bytes4[] memory selectors = new bytes4[](10);
        selectors[0] = MarketHandler.supply.selector;
        selectors[1] = MarketHandler.withdraw.selector;
        selectors[2] = MarketHandler.supplyCollateral.selector;
        selectors[3] = MarketHandler.borrow.selector;
        selectors[4] = MarketHandler.repay.selector;
        selectors[5] = MarketHandler.withdrawCollateral.selector;
        selectors[6] = MarketHandler.warp.selector;
        selectors[7] = MarketHandler.crashPrice.selector;
        selectors[8] = MarketHandler.liquidate.selector;
        selectors[9] = MarketHandler.supplyCollateralDust.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function _market() internal view returns (MorphoMarket memory) {
        return protocol.markets[0].core.market(protocol.markets[0].id);
    }

    /// @dev The market never lends out more than was supplied — `totalSupplyAssets >= totalBorrowAssets` always.
    function invariant_supplyCoversBorrow() public view {
        MorphoMarket memory mk = _market();
        assertGe(mk.totalSupplyAssets, mk.totalBorrowAssets, "supply must always cover borrow");
    }

    /// @dev The core's real loan-token balance always covers the un-borrowed (idle) supply, so idle stays withdrawable.
    function invariant_idleBackedByTokens() public view {
        Market storage m = protocol.markets[0];
        MorphoMarket memory mk = _market();
        uint256 idle = mk.totalSupplyAssets - mk.totalBorrowAssets;
        // The core holds AT LEAST the idle (un-borrowed) supply. It can hold a few wei MORE over long mixed
        // sequences. The common single paths are each EXACTLY synced (zero dust) — supply, borrow, accrue,
        // repay, and full/partial liquidation, verified in RoundingDust.t.sol — so the slack only emerges from
        // compounded rounding, not any one operation. Under-backing (balance < idle) is the real solvency bug;
        // the inequality is the property (assertEq fails by ~1 wei).
        assertGe(m.loanToken.balanceOf(address(m.core)), idle, "core loan balance covers idle supply");
    }

    /// @dev The vault forwards every deposit into the core and holds no idle loan tokens itself.
    function invariant_vaultHoldsNoLoanTokens() public view {
        Market storage m = protocol.markets[0];
        assertEq(m.loanToken.balanceOf(address(m.vault)), 0, "vault forwards deposits; holds no idle loan tokens");
    }

    /// @dev The vault is the only supplier in this fuzz (every deposit routes through it), so it must own
    ///      exactly the whole supply-share book — a phantom supply share anywhere else is a bug.
    function invariant_vaultIsSoleSupplier() public view {
        Market storage m = protocol.markets[0];
        assertEq(
            m.core.position(m.id, address(m.vault)).supplyShares,
            _market().totalSupplyShares,
            "vault holds 100% of supply shares"
        );
    }

    /// @dev The vault never reports more assets than the market actually holds (no value creation): its
    ///      `totalAssets()` claim stays within the market's total supply.
    function invariant_vaultNeverOverReports() public view {
        Market storage m = protocol.markets[0];
        assertLe(m.vault.totalAssets(), _market().totalSupplyAssets, "vault totalAssets <= market supply");
    }

    /// @dev The core's collateral-token balance equals the sum of every actor's recorded position collateral.
    function invariant_collateralConservation() public view {
        Market storage m = protocol.markets[0];
        uint256 sum;
        for (uint256 i; i < actors.length; i++) {
            sum += m.core.position(m.id, actors[i]).collateral;
        }
        assertEq(sum, m.collateralToken.balanceOf(address(m.core)), "sum of position collateral == core balance");
    }

    /// @dev A debt-bearing borrower never reaches active collateral below `minActivationAmount` through the
    ///      VOLUNTARY paths: sub-threshold active collateral has zero borrow capacity, so `withdrawCollateral`
    ///      and the borrow hook both revert `InsufficientActiveCollateral` (a gap this invariant first caught —
    ///      a debt-free withdraw below the threshold followed by a borrow). Liquidation is a FORCED path that may
    ///      legitimately leave a debt-bearing sub-threshold position, so its victims are excluded until their debt
    ///      is cleared; only the voluntary paths must uphold the floor. Audit T1-C13: the exclusion once outlived
    ///      the debt.
    function invariant_noDebtWithSubFloorCollateral() public view {
        Market storage m = protocol.markets[0];
        for (uint256 i; i < actors.length; i++) {
            if (!handler.liquidated(actors[i]) && m.core.position(m.id, actors[i]).borrowShares > 0) {
                assertGe(
                    m.core.position(m.id, actors[i]).collateral,
                    FLOOR,
                    "debt-bearing position keeps collateral >= minActivationAmount"
                );
            }
        }
    }

    /// @dev Audit T1-C1: `positionOf` derives `active` as the remainder, so a sum check was a tautology. The two
    ///      stored buckets must fit in the core collateral, and a lot has an unlock time exactly while it holds
    ///      activating collateral (market-controller.md "Collateral activation").
    function invariant_activationBucketsFitCollateral() public view {
        Market storage m = protocol.markets[0];
        for (uint256 i; i < actors.length; i++) {
            ILidoLendMarketController.BorrowerPosition memory d = m.controller.positionOf(actors[i]);
            assertLe(
                d.activating + d.dust,
                m.core.position(m.id, actors[i]).collateral,
                "activating + dust <= core collateral"
            );
            assertEq(d.unlockTime != 0, d.activating != 0, "unlock time set iff activating > 0");
        }
    }

    /// @dev Audit T1-C5: logs the counters and fails a run that missed a path the solvency invariants need. Foundry
    ///      restores the post-setUp state before each run, so the counters are per run.
    function afterInvariant() public {
        emit log_named_uint("supplies", handler.supplies());
        emit log_named_uint("withdraws", handler.withdraws());
        emit log_named_uint("collateralSupplies", handler.collateralSupplies());
        emit log_named_uint("dustSupplies", handler.dustSupplies());
        emit log_named_uint("collateralWithdrawals", handler.collateralWithdrawals());
        emit log_named_uint("borrows", handler.borrows());
        emit log_named_uint("repays", handler.repays());
        emit log_named_uint("crashes", handler.crashes());
        emit log_named_uint("liquidations", handler.liquidations());
        // A run makes 400 calls over 10 selectors. A floor holds when (1 - 0.1 * E)^400 < 1e-9, that is E >= 0.51.
        // E is the share of draws that count. A 1000-run campaign then misses the floor with odds below 1e-6.
        //   supplies, collateralSupplies, crashes: E = 1, because nothing in this fixture blocks them.
        // The next four rest on measurement over 3003 runs. The fewest moves in one run are in brackets:
        //   withdraws (15): E = 0.87. A draw fails only with no vault shares or no idle supply.
        //   borrows (11): E = 0.65. A draw needs active collateral with room under the LLTV, and idle supply.
        //   repays (7): E = 0.61. A draw needs debt, which the borrows keep open.
        //   collateralWithdrawals (7): E = 0.65. A draw needs collateral above the health margin.
        // Dust supplies (E = 0.2) and liquidations (none in 6 of 3003 runs) carry no floor. The tests below
        // reach them.
        assertGt(handler.supplies(), 0, "coverage: no supply");
        assertGt(handler.collateralSupplies(), 0, "coverage: no collateral supply");
        assertGt(handler.crashes(), 0, "coverage: no crash");
        assertGt(handler.withdraws(), 0, "coverage: no withdraw");
        assertGt(handler.borrows(), 0, "coverage: no borrow");
        assertGt(handler.repays(), 0, "coverage: no repay");
        assertGt(handler.collateralWithdrawals(), 0, "coverage: no collateral withdrawal");
    }

    /// @dev Audit T1-C1 and T1-C5: a run can miss a dust supply, so this drives each delayed bucket once. D1 holds
    ///      dust. D2's lot gets an unlock time, then matures inside the borrow hook once the delay has passed.
    function test_delayedActorBuckets_reachDustLotAndMaturity() public {
        Market storage m = protocol.markets[0];
        handler.supply(0, 1_000_000e18);
        handler.supplyCollateralDust(3, 0); // bound maps 0 to minDepositAmount
        handler.supplyCollateral(4, 0); // bound maps 0 to 50e18
        assertEq(handler.dustSupplies(), 1, "dust supply unreached");
        assertEq(m.controller.positionOf(D1).dust, 1 ether, "D1 holds no dust");
        ILidoLendMarketController.BorrowerPosition memory lot = m.controller.positionOf(D2);
        assertEq(lot.activating, 50 ether, "D2 holds no activating lot");
        assertGt(lot.unlockTime, block.timestamp, "D2's lot has no future unlock time");
        invariant_activationBucketsFitCollateral();

        handler.warp(0); // bound maps 0 to one hour
        assertLe(m.controller.positionOf(D2).unlockTime, block.timestamp, "setup: D2's lot is not due");
        handler.borrow(4, 0); // bound maps 0 to 1e18
        assertEq(handler.borrows(), 1, "borrow on the matured lot unreached");
        lot = m.controller.positionOf(D2);
        assertEq(lot.activating, 0, "the lot did not mature in the borrow hook");
        assertEq(lot.unlockTime, 0, "the matured lot kept its unlock time");
        invariant_activationBucketsFitCollateral();
    }

    /// @dev Audit T1-C13 and T1-C5: a run can miss a liquidation. A solvent partial liquidation leaves debt and flags
    ///      the victim. Repaying that debt clears the flag, so the floor invariant covers the victim's next borrow.
    function test_liquidatedFlag_clearsOnceDebtIsRepaid() public {
        Market storage m = protocol.markets[0];
        handler.supply(0, 1_000_000e18);
        handler.supplyCollateral(0, 100e18);
        // 75% of the LLTV capacity. A crash to 70% of the seed price then puts the LTV near 0.86: unhealthy, solvent.
        handler.borrow(0, 100e18 * oraclePrice / 1e36 * 80 / 100 * 75 / 100);
        handler.crashPrice(70);
        handler.liquidate(0, 10e18);
        assertEq(handler.liquidations(), 1, "liquidation unreached");
        assertGt(m.core.position(m.id, A1).borrowShares, 0, "setup: the partial liquidation left no debt");
        assertTrue(handler.liquidated(A1), "the victim with debt left is not flagged");

        handler.repay(0, m.core.position(m.id, A1).borrowShares);
        assertEq(m.core.position(m.id, A1).borrowShares, 0, "setup: the debt is not repaid");
        assertFalse(handler.liquidated(A1), "the flag outlived the debt");
    }

    /// @dev Deterministic bad-debt case with a SECOND, healthy borrower, so solvency is checked against a live
    ///      debt rather than a market wiped to zero.
    function test_badDebtSocialization_preservesSolvency() public {
        Market storage m = protocol.markets[0];
        m.controller.setInstantActivation(A4, true);

        _fund(m.loanToken, A1, 2000 ether);
        vm.startPrank(A1);
        m.loanToken.approve(address(m.vault), 2000 ether);
        m.vault.deposit(2000 ether, A1);
        vm.stopPrank();

        // A2 borrows to the LLTV; a 50% crash below puts it underwater.
        uint256 maxBorrow = 100 ether * oraclePrice / 1e36 * 80 / 100;
        _fund(m.collateralToken, A2, 100 ether);
        vm.startPrank(A2);
        m.collateralToken.approve(address(m.core), 100 ether);
        m.core.supplyCollateral(m.params, 100 ether, A2, "");
        m.core.borrow(m.params, maxBorrow * 99 / 100, 0, A2, A2);
        vm.stopPrank();

        // A4 stays solvent through the crash (40% of the cap -> 80% of the halved cap).
        uint256 a4Borrow = maxBorrow * 40 / 100;
        _fund(m.collateralToken, A4, 100 ether);
        vm.startPrank(A4);
        m.collateralToken.approve(address(m.core), 100 ether);
        m.core.supplyCollateral(m.params, 100 ether, A4, "");
        m.core.borrow(m.params, a4Borrow, 0, A4, A4);
        vm.stopPrank();

        MockPriceOracle(address(m.oracle)).setPrice(oraclePrice / 2);
        m.core.accrueInterest(m.params);

        uint256 supplyBefore = m.core.market(m.id).totalSupplyAssets;
        uint256 a4SharesBefore = m.core.position(m.id, A4).borrowShares;

        _fund(m.loanToken, A3, type(uint128).max);
        vm.startPrank(A3);
        m.loanToken.approve(address(m.core), type(uint256).max);
        vm.recordLogs();
        m.core.liquidate(m.params, A2, 100 ether, 0, ""); // seize all -> realize bad debt
        vm.stopPrank();
        uint256 badDebtAssets = _badDebtFromLiquidateLog(address(m.core));

        MorphoMarket memory mk = m.core.market(m.id);
        assertEq(mk.totalSupplyAssets, supplyBefore - badDebtAssets, "supply dropped by exactly badDebtAssets");
        assertGt(badDebtAssets, 0, "the liquidation actually realized bad debt");
        assertEq(m.core.position(m.id, A2).collateral, 0, "full seize wiped A2's collateral");
        assertEq(m.core.position(m.id, A2).borrowShares, 0, "A2's debt fully closed");
        assertEq(m.core.position(m.id, A4).borrowShares, a4SharesBefore, "A4's debt untouched by A2's liquidation");
        assertGt(mk.totalBorrowAssets, 0, "a live borrow remains -> solvency check is non-vacuous");
        assertGe(mk.totalSupplyAssets, mk.totalBorrowAssets, "solvency survives socialization");
    }

    /// @dev `badDebtAssets` from the core's `Liquidate` event — an independent read of the supply write-down.
    function _badDebtFromLiquidateLog(address core) internal returns (uint256) {
        bytes32 sig = keccak256("Liquidate(bytes32,address,address,uint256,uint256,uint256,uint256,uint256)");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == core && logs[i].topics[0] == sig) {
                (,,, uint256 badDebtAssets,) = abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, uint256));
                return badDebtAssets;
            }
        }
        revert("no Liquidate event");
    }
}
