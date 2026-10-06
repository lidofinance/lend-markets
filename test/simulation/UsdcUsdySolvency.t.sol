// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {Market as MorphoMarket} from "@lido-lend/src/interfaces/IMorpho.sol";
import {SharesMathLib} from "@lido-lend/src/libraries/SharesMathLib.sol";
import {WAD} from "@lido-lend/src/libraries/MathLib.sol";

import {ILidoLendMarketController} from "../../src/interfaces/ILidoLendMarketController.sol";
import {Erc4626Math} from "../setup/Erc4626Math.sol";
import {MarketActions} from "../setup/MarketActions.sol";
import {Market} from "../setup/Types.sol";
import {Random} from "./Random.sol";
import {SolvencySimulation} from "./SolvencySimulation.sol";

/// @notice Solvency simulation on a 6/18 market shaped like USDC/USDY. The price only rises, 1 to 10 basis points a
///         step. Under that walk a position can go unhealthy by accrual but never underwater, so the run must see no
///         bad debt: a write-off would be a driver or core fault. It covers exits, settlement, governance, fees, gifts
///         and exit books on a healthy market with a six-decimal loan token.
contract UsdcUsdySolvencySimulation is SolvencySimulation {
    using MarketActions for Market;
    using Random for Random.Context;
    using SharesMathLib for uint256;

    function _loanDecimals() internal pure override returns (uint8) {
        return 6;
    }

    /// @dev 1.03 to 1.12 USDC per USDY, in the six-decimal loan scale.
    function _priceBand() internal pure override returns (uint256, uint256) {
        return (1.03e24, 1.12e24);
    }

    function _stepPrice(uint256 current) internal override returns (uint256) {
        return current * (10_000 + random.between(1, 10)) / 10_000;
    }

    function _crashFactor() internal pure override returns (uint256) {
        return WAD;
    }

    function _assertPriceModelConsequences() internal view override {
        assertEq(count[Action.LiquidateBadDebt], 0, "usdc/usdy: a write-off on a rising price");
        assertEq(g.badDebt, 0, "usdc/usdy: bad debt on a rising price");
        assertEq(g.badDebtGate, 0, "usdc/usdy: the bad-debt gate fired on a rising price");
    }

    // ---
    // BOUNDARY PINS
    // ---
    //
    // Boundaries a random run cannot be relied on to hit exactly. The four vault pins sit here, not in the shared
    // base, because they need a six-decimal loan token: the vault's 12-decimal virtual-share offset then makes a
    // share differ from an asset, so floor-rounded conversions lose value.

    /// @notice Settling the queue root reverts once the root is bad debt, even for a cut well inside its personal
    ///         allowance.
    /// @dev lender-settlement.md "Controller execution rules": the bad-debt gate reverts `SettlementBadDebt` before
    ///      any allowance check. Kills `src/controllers/LidoLendMarketController.sol:550` with its `_isBadDebt(...)`
    ///      condition mutated to never hold, which lets the cut through.
    function test_badDebtGate_blocksSettle_usdc() public {
        _setUpSimulation(_shortCounts());
        Market storage m = _m();
        address liquidity = lenders[0];
        _mintLoan(liquidity, 1000 * unit);
        m.vaultDeposit(liquidity, 1000 * unit);

        // Debt several times the settler's budget, so the cut it funds seizes well under the whole collateral
        // and the core's own seizure check cannot pre-empt the gate.
        address b = borrowers[0];
        _mintCollateral(b, 1000 ether);
        m.supplyCollateralInstant(b, b, 1000 ether);
        m.borrow(b, _borrowRoom(b) / 2);
        m.setSettlementLtv(b, TARGET_LTV);

        address settler = lenders[1];
        _mintLoan(settler, minSettle);
        m.vaultDeposit(settler, minSettle);

        m.distress(b, 1.05e18);
        (address root,) = m.controller.nextSettlementBorrower(0);
        assertEq(root, b, "setup: the only debtor is the queue root");
        assertTrue(_isUnderwater(b), "setup: the root's debt is worth more than its collateral");

        address[] memory targets = new address[](1);
        targets[0] = b;
        uint256 budget = m.vault.balanceOf(settler);
        vm.prank(settler);
        vm.expectRevert(ILidoLendMarketController.SettlementBadDebt.selector);
        m.vault.settle(budget, targets, settler, settler);
    }

    /// @notice A fallback exit with no liquid leg drops the vault's managed core shares by exactly the shares the
    ///         settlement cut burned: the canceled debt converted up into supply shares.
    /// @dev lender-settlement.md "Vault accounting boundary": only vault-originated core shares back vault shares.
    ///      Kills `src/LidoLendERC4626.sol:335` (`_managedSupplyShares -= settledSupplyShares;`) mutated to
    ///      decrement less, which leaves the vault claiming shares it no longer holds.
    function test_fallbackExit_managedSharesDropByBudget_usdc() public {
        _setUpSimulation(_shortCounts());
        Market storage m = _m();
        address l = lenders[0];
        uint256 deposit = 1000 * unit;
        _mintLoan(l, deposit);
        m.vaultDeposit(l, deposit);

        address b = borrowers[0];
        _mintCollateral(b, 3000 ether);
        m.supplyCollateralInstant(b, b, 3000 ether);
        m.borrow(b, _borrowRoom(b));
        assertEq(_freeLiquidity(), 0, "setup: the market must be fully lent out, so the exit has no liquid leg");

        MorphoMarket memory mk = m.accruedMarket();
        uint256 managedBefore = m.vault.managedSupplyShares();
        // One iteration, so the whole drop answers for exactly one cut.
        (,,, uint256 debtCanceled) = m.fallbackExit(l, m.vault.balanceOf(l), l, 1);
        assertGt(debtCanceled, 0, "the settle leg must have cut the queue root");

        assertEq(
            managedBefore - m.vault.managedSupplyShares(),
            debtCanceled.toSharesUp(mk.totalSupplyAssets, mk.totalSupplyShares),
            "fallbackExit: managed shares did not drop by the core shares the cut burned"
        );
    }

    /// @notice With nothing withdrawable, a holder whose shares are worth no loan asset redeems nothing. On a liquid
    ///         market, a position the liquidity covers redeems whole.
    /// @dev lender-settlement.md "Vault fallback exit / 1. Liquid loan-asset withdrawal". Kills
    ///      `src/LidoLendERC4626.sol:163` (`liquidAssets == 0`). With the guard dead, the paused leg returns the
    ///      whole balance, since a zero-valued position fits zero liquidity: that rules out `!=`, `<` and deleting
    ///      the statement. The liquid leg rules out `>=` and `>`, which return zero there. `<=` equals `==` on
    ///      `uint256` and is unkillable.
    function test_maxRedeem_zeroLiquidityDustHolder_isZero() public {
        _setUpSimulation(_shortCounts());
        Market storage m = _m();
        address l = lenders[0];
        address dust = lenders[1];
        _mintLoan(l, 1000 * unit);
        m.vaultDeposit(l, 1000 * unit);
        vm.prank(l);
        m.vault.transfer(dust, 1);

        assertGt(_freeLiquidity(), 0, "setup: an unlent market withdraws something");
        assertEq(m.vault.maxRedeem(l), m.vault.balanceOf(l), "a covered position redeems whole");

        m.pause(2 hours);
        assertEq(_freeLiquidity(), 0, "setup: a paused market withdraws nothing");
        assertEq(m.vault.balanceOf(dust), 1, "setup: the holder holds one share");
        assertEq(Erc4626Math.toAssets(m.vault, 1, Math.Rounding.Floor), 0, "setup: one share is worth no loan asset");

        assertEq(m.vault.maxRedeem(dust), 0, "no withdrawable liquidity: maxRedeem must be zero");
    }

    /// @notice A position whose floor-rounded value equals the free liquidity redeems whole, not the liquidity
    ///         floored into shares. A smaller position redeems whole too; a larger one redeems that floored amount.
    /// @dev lender-settlement.md "Vault fallback exit / 1. Liquid loan-asset withdrawal". Kills
    ///      `src/LidoLendERC4626.sol:166` (`previewRedeem(ownerShares) <= liquidAssets`): the exact fit rules out
    ///      `<`, `>` and `!=`, the larger holder `>=`, and the smaller holder `==`.
    function test_maxRedeem_positionExactlyFitsLiquidity_isWholeBalance() public {
        _setUpSimulation(_shortCounts());
        Market storage m = _m();
        address l = lenders[0];
        address fit = lenders[1];
        address small = lenders[2];
        uint256 deposit = 1000 * unit;
        _mintLoan(l, deposit);
        m.vaultDeposit(l, deposit);

        // Each holder gets one share past what its target value buys, so converting that value back cannot
        // return the balance. `l` keeps the rest, which is worth more than the liquidity.
        uint256 liquid = deposit / 5;
        uint256 held = Erc4626Math.toShares(m.vault, liquid, Math.Rounding.Floor) + 1;
        uint256 heldSmall = Erc4626Math.toShares(m.vault, liquid / 2, Math.Rounding.Floor) + 1;
        vm.prank(l);
        m.vault.transfer(fit, held);
        vm.prank(l);
        m.vault.transfer(small, heldSmall);

        address b = borrowers[0];
        _mintCollateral(b, 3000 ether);
        m.supplyCollateralInstant(b, b, 3000 ether);
        m.borrow(b, deposit - liquid);

        assertEq(_freeLiquidity(), liquid, "setup: the borrow must leave exactly the fitting holder's value free");
        assertEq(
            Erc4626Math.toAssets(m.vault, held, Math.Rounding.Floor), liquid, "setup: the position is worth exactly it"
        );
        assertLt(Erc4626Math.toShares(m.vault, liquid, Math.Rounding.Floor), held, "setup: the round trip loses one");
        assertLt(Erc4626Math.toAssets(m.vault, heldSmall, Math.Rounding.Floor), liquid, "setup: the small one is under");
        assertGt(Erc4626Math.toAssets(m.vault, m.vault.balanceOf(l), Math.Rounding.Floor), liquid, "setup: `l` is over");

        assertEq(m.vault.maxRedeem(fit), held, "an exactly-fitting position must redeem whole");
        assertEq(m.vault.maxRedeem(small), heldSmall, "a position under the liquidity must redeem whole");
        assertEq(
            m.vault.maxRedeem(l),
            Erc4626Math.toShares(m.vault, liquid, Math.Rounding.Floor),
            "a position over the liquidity must redeem the floored conversion of it"
        );
    }

    /// @notice Under a live supply cap, `maxMint` is the room floored into shares, not the room itself. With no cap
    ///         it passes the unlimited sentinel through.
    /// @dev market-controller.md "Lender supply cap". Kills `src/LidoLendERC4626.sol:179`
    ///      (`maxAssets == type(uint256).max`): the capped leg rules out `<=`, `<` and `!=`, which return the asset
    ///      amount, and the uncapped leg rules out `>`, which converts the sentinel and overflows. `>=` equals `==`
    ///      at the top of the range and is unkillable.
    function test_maxMint_underSupplyCap_isTheShareConversion() public {
        _setUpSimulation(_shortCounts());
        Market storage m = _m();
        address l = lenders[0];
        uint256 deposit = 1000 * unit;
        _mintLoan(l, deposit);
        m.vaultDeposit(l, deposit);

        assertEq(_vaultMaxDeposit(l), type(uint256).max, "setup: the market is deployed uncapped");
        assertEq(m.vault.maxMint(l), type(uint256).max, "an uncapped maxMint passes the sentinel through");

        uint256 room = 500 * unit;
        m.setSupplyCap(deposit + room);
        uint256 expected = Erc4626Math.toShares(m.vault, room, Math.Rounding.Floor);
        assertEq(_vaultMaxDeposit(l), room, "setup: the cap must leave exactly the room the test set");
        assertTrue(expected != room, "setup: a share must not be an asset, or the mutation is invisible");

        assertEq(m.vault.maxMint(l), expected, "a capped maxMint must be maxDeposit floored into shares");
    }
}
