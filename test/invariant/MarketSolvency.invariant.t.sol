// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

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
/// forge-config: default.invariant.fail-on-revert = false
/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 250
contract MarketSolvencyInvariant is LidoLendSetup {
    MarketHandler internal handler;

    address internal constant A1 = address(0x9001);
    address internal constant A2 = address(0x9002);
    address internal constant A3 = address(0x9003);

    function setUp() public {
        MockERC20 loan = new MockERC20("Loan", "LOAN", 18);
        MockERC20 collateral = new MockERC20("Collateral", "COLL", 18);
        _deployProtocol(_defaultConfig(address(loan), address(collateral), address(collateral)));

        Market storage m = protocol.markets[0];
        // Instant activation for the actors → supplied collateral is immediately borrowable.
        m.controller.grantInstantActivation(A1);
        m.controller.grantInstantActivation(A2);
        m.controller.grantInstantActivation(A3);

        address[] memory actors = new address[](3);
        actors[0] = A1;
        actors[1] = A2;
        actors[2] = A3;
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

    function invariant_supplyCoversBorrow() public view {
        MorphoMarket memory mk = _market();
        assertGe(mk.totalSupplyAssets, mk.totalBorrowAssets, "supply must always cover borrow");
    }

    function invariant_idleBackedByTokens() public view {
        Market storage m = protocol.markets[0];
        MorphoMarket memory mk = _market();
        uint256 idle = mk.totalSupplyAssets - mk.totalBorrowAssets;
        // The vault forwards every deposit straight to the core, so the idle (un-borrowed supply) is held
        // by the CORE — the vault holds no loan tokens at rest (asserted separately below).
        assertGe(m.loanToken.balanceOf(address(m.core)), idle, "idle supply backed by loan tokens in the core");
    }

    function invariant_vaultHoldsNoLoanTokens() public view {
        Market storage m = protocol.markets[0];
        assertEq(m.loanToken.balanceOf(address(m.vault)), 0, "vault forwards deposits; holds no idle loan tokens");
    }

    function invariant_collateralConservation() public view {
        Market storage m = protocol.markets[0];
        uint256 sum = uint256(m.core.position(m.id, A1).collateral) + m.core.position(m.id, A2).collateral
            + m.core.position(m.id, A3).collateral;
        assertEq(sum, m.collateralToken.balanceOf(address(m.core)), "sum of position collateral == core balance");
    }

    /// @dev The controller's activation buckets must exactly partition each borrower's core collateral.
    function invariant_activationBucketsPartitionCollateral() public view {
        Market storage m = protocol.markets[0];
        address[3] memory who = [A1, A2, A3];
        for (uint256 i; i < 3; i++) {
            ILidoLendMarketController.BorrowerPosition memory d = m.controller.positionOf(who[i]);
            assertEq(
                d.active + d.activating + d.dust,
                m.core.position(m.id, who[i]).collateral,
                "active + activating + dust == core collateral"
            );
        }
    }

    /// @dev Deterministic companion to the fuzz run: force a position underwater and fully liquidate it, then
    ///      assert the bad debt IS socialized (supply drops) AND solvency still holds (supply covers borrow).
    function test_badDebtSocialization_preservesSolvency() public {
        Market storage m = protocol.markets[0];

        _fund(m.loanToken, A1, 1000 ether);
        vm.startPrank(A1);
        m.loanToken.approve(address(m.vault), 1000 ether);
        m.vault.deposit(1000 ether, A1);
        vm.stopPrank();

        _fund(m.collateralToken, A2, 100 ether);
        vm.startPrank(A2);
        m.collateralToken.approve(address(m.core), 100 ether);
        m.core.supplyCollateral(m.params, 100 ether, A2, ""); // A2 has instant activation -> active
        vm.stopPrank();
        uint256 maxBorrow = 100 ether * oraclePrice / 1e36 * 80 / 100;
        vm.prank(A2);
        m.core.borrow(m.params, maxBorrow * 99 / 100, 0, A2, A2);

        MockPriceOracle(address(m.oracle)).setPrice(oraclePrice / 2); // crash -> underwater
        m.core.accrueInterest(m.params);

        uint256 supplyBefore = m.core.market(m.id).totalSupplyAssets;
        _fund(m.loanToken, A3, type(uint128).max);
        vm.startPrank(A3);
        m.loanToken.approve(address(m.core), type(uint256).max);
        m.core.liquidate(m.params, A2, 100 ether, 0, ""); // seize ALL -> realize bad debt
        vm.stopPrank();

        MorphoMarket memory mk = m.core.market(m.id);
        assertLt(mk.totalSupplyAssets, supplyBefore, "bad debt socialized: totalSupplyAssets dropped");
        assertGe(mk.totalSupplyAssets, mk.totalBorrowAssets, "solvency survives socialization");
        assertEq(m.core.position(m.id, A2).collateral, 0, "full seize wiped the collateral");
    }
}
