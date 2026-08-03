// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

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
///         Activation is short-circuited (actors hold instant activation) so the fuzzer reaches the
///         borrow/repay state space without fighting the maturation timer.
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

        handler = new MarketHandler(
            m.core, m.vault, m.loanToken, m.collateralToken, m.params, m.id, oraclePrice, address(m.oracle), actors
        );
        bytes4[] memory selectors = new bytes4[](9);
        selectors[0] = MarketHandler.supply.selector;
        selectors[1] = MarketHandler.withdraw.selector;
        selectors[2] = MarketHandler.supplyCollateral.selector;
        selectors[3] = MarketHandler.borrow.selector;
        selectors[4] = MarketHandler.repay.selector;
        selectors[5] = MarketHandler.withdrawCollateral.selector;
        selectors[6] = MarketHandler.warp.selector;
        selectors[7] = MarketHandler.crashPrice.selector;
        selectors[8] = MarketHandler.liquidate.selector;
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
    ///      legitimately leave a debt-bearing sub-threshold position, so its victims are excluded; only the
    ///      voluntary paths must uphold the floor.
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

    /// @dev The controller's activation buckets must exactly partition each borrower's core collateral.
    function invariant_activationBucketsPartitionCollateral() public view {
        Market storage m = protocol.markets[0];
        for (uint256 i; i < actors.length; i++) {
            ILidoLendMarketController.BorrowerPosition memory d = m.controller.positionOf(actors[i]);
            assertEq(
                d.active + d.activating + d.dust,
                m.core.position(m.id, actors[i]).collateral,
                "active + activating + dust == core collateral"
            );
        }
    }

    /// @dev Surfaces vacuous campaigns: reports how deep the fuzzer reached (last run's counters). If borrows
    ///      or liquidations stay at 0 the solvency invariants are passing only because nothing risky happened.
    function afterInvariant() public {
        emit log_named_uint("supplies", handler.supplies());
        emit log_named_uint("borrows", handler.borrows());
        emit log_named_uint("repays", handler.repays());
        emit log_named_uint("crashes", handler.crashes());
        emit log_named_uint("liquidations", handler.liquidations());
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
