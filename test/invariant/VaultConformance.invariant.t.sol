// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {IMorpho, Market as MorphoMarket} from "@lido-lend/src/interfaces/IMorpho.sol";
import {MorphoBalancesLib} from "@lido-lend/src/libraries/periphery/MorphoBalancesLib.sol";

import {LidoLendMarketController} from "../../src/controllers/LidoLendMarketController.sol";
import {LidoLendSetup} from "../setup/LidoLendSetup.sol";
import {Market} from "../setup/Types.sol";
import {MockERC20} from "../setup/Mocks.sol";
import {VaultHandler} from "./handlers/VaultHandler.sol";

/// @notice L4 stateful invariants for `LidoLendERC4626`, focused on the mechanics it adds over a plain ERC-4626:
///         the liquidity-capped `max*`, the settlement-backed `settle` / `fallbackExit` exits, and the position-only
///         `totalAssets` (donation defence). Under any bounded sequence of deposit/mint/withdraw/redeem/settle/
///         fallbackExit/borrow/personal-LTV update/repay/crash/warp/liquidate/donate, the vault must never create
///         value, settlement burns must follow their declared one-sided rounding, donations cannot move the share
///         price, and every `max*` must stay a real, honoured bound.
/// @dev `afterInvariant` reports successful-action counters so a vacuous campaign (no settles / exits) is visible.
/// forge-config: default.invariant.fail-on-revert = true
/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 250
contract VaultConformanceInvariant is LidoLendSetup {
    VaultHandler internal handler;

    address[] internal actors;

    function setUp() public {
        MockERC20 loan = new MockERC20("Loan", "LOAN", 18);
        MockERC20 collateral = new MockERC20("Collateral", "COLL", 18);
        _deployProtocol(_defaultConfig(address(loan), address(collateral), address(collateral)));

        Market storage m = protocol.markets[0];
        actors.push(address(0x9001));
        actors.push(address(0x9002));
        actors.push(address(0x9003));
        for (uint256 i; i < actors.length; i++) {
            m.controller.setInstantActivation(actors[i], true);
        }

        handler = new VaultHandler(
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

        // The handler toggles pause and the supply cap, so it needs those roles.
        LidoLendMarketController c = LidoLendMarketController(address(m.controller));
        c.grantRole(c.PAUSER_ROLE(), address(handler));
        c.grantRole(c.RESUMER_ROLE(), address(handler));
        c.grantRole(c.MANAGER_ROLE(), address(handler));

        // Seed one live personal settlement path so the targeted-settlement invariants do not depend on a random
        // deposit -> collateral -> borrow -> opt-in prefix before they can observe a successful fill.
        handler.deposit(0, 1_000 ether);
        handler.supplyCollateral(1, 1_000 ether);
        handler.borrow(1, 25 ether);
        handler.setSettlementLtv(1, 1);

        bytes4[] memory all = new bytes4[](16);
        all[0] = VaultHandler.deposit.selector;
        all[1] = VaultHandler.mint.selector;
        all[2] = VaultHandler.withdraw.selector;
        all[3] = VaultHandler.redeem.selector;
        all[4] = VaultHandler.settle.selector;
        all[5] = VaultHandler.fallbackExit.selector;
        all[6] = VaultHandler.supplyCollateral.selector;
        all[7] = VaultHandler.borrow.selector;
        all[8] = VaultHandler.setSettlementLtv.selector;
        all[9] = VaultHandler.repay.selector;
        all[10] = VaultHandler.warp.selector;
        all[11] = VaultHandler.crashPrice.selector;
        all[12] = VaultHandler.liquidate.selector;
        all[13] = VaultHandler.donate.selector;
        all[14] = VaultHandler.pauseResume.selector;
        all[15] = VaultHandler.setSupplyCap.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: all}));
        targetContract(address(handler));
    }

    function _m() internal view returns (Market storage) {
        return protocol.markets[0];
    }

    function _mk() internal view returns (MorphoMarket memory) {
        return _m().core.market(_m().id);
    }

    // ── accounting / conservation ──

    /// @dev Every deposit routes through the vault into the Morpho supply, so the vault owns 100% of supply shares.
    function invariant_vaultIsSoleSupplier() public view {
        Market storage m = _m();
        assertEq(m.core.position(m.id, address(m.vault)).supplyShares, _mk().totalSupplyShares, "vault owns all supply");
    }

    /// @dev The vault forwards deposits into the core and holds only the uncounted donations — never counted assets.
    function invariant_donationsAreTheOnlyIdleTokens() public view {
        Market storage m = _m();
        assertEq(m.loanToken.balanceOf(address(m.vault)), handler.totalDonated(), "vault holds only the donations");
    }

    /// @dev No value creation: the vault never claims more assets than the market's supply owes. Compared against
    ///      the ACCRUED supply (as `totalAssets` itself uses), since a pause leaves interest un-accrued in storage.
    function invariant_noValueCreation() public view {
        Market storage m = _m();
        (uint256 accruedSupply,,,) = MorphoBalancesLib.expectedMarketBalances(IMorpho(address(m.core)), m.params);
        assertLe(m.vault.totalAssets(), accruedSupply, "totalAssets <= accrued market supply");
    }

    /// @dev Solvency of the underlying market the vault supplies into.
    function invariant_supplyCoversBorrow() public view {
        MorphoMarket memory mk = _mk();
        assertGe(mk.totalSupplyAssets, mk.totalBorrowAssets, "supply covers borrow");
    }

    /// @dev The core holds at least the idle (un-borrowed) supply in real tokens.
    function invariant_idleBackedByTokens() public view {
        Market storage m = _m();
        MorphoMarket memory mk = _mk();
        assertGe(m.loanToken.balanceOf(address(m.core)), mk.totalSupplyAssets - mk.totalBorrowAssets, "idle backed");
    }

    /// @dev Share holdings partition the supply.
    function invariant_holdersSumToSupply() public view {
        Market storage m = _m();
        uint256 sum;
        for (uint256 i; i < actors.length; i++) {
            sum += m.vault.balanceOf(actors[i]);
        }
        assertEq(sum, m.vault.totalSupply(), "sum of balances == totalSupply");
    }

    // ── liquidity-capped max* (new mechanic) ──

    /// @dev `maxWithdraw` is a real, liquidity-capped bound. Outside a pause, the floor-valued `maxRedeem` also fits
    ///      in free liquidity; during a pause both exit limits are zero.
    function invariant_maxAreHonouredBounds() public view {
        Market storage m = _m();
        MorphoMarket memory mk = _mk();
        uint256 idle = mk.totalSupplyAssets - mk.totalBorrowAssets;
        bool paused = LidoLendMarketController(address(m.controller)).isPaused();
        for (uint256 i; i < actors.length; i++) {
            address a = actors[i];
            assertLe(m.vault.maxWithdraw(a), idle, "maxWithdraw <= free liquidity");
            assertLe(m.vault.maxWithdraw(a), m.vault.previewRedeem(m.vault.balanceOf(a)), "maxWithdraw <= redeemable");
            assertLe(m.vault.maxRedeem(a), m.vault.balanceOf(a), "maxRedeem <= balance");
            if (paused) {
                assertEq(m.vault.maxWithdraw(a), 0, "paused: maxWithdraw == 0");
                assertEq(m.vault.maxRedeem(a), 0, "paused: maxRedeem == 0");
            } else {
                assertLe(m.vault.previewRedeem(m.vault.maxRedeem(a)), idle, "maxRedeem preview fits liquidity");
            }
        }
    }

    /// @dev EIP: a disabled or capped deposit side makes `max{Deposit,Mint}` the amount that would not revert.
    ///      Paused -> 0; a supply cap -> the remaining headroom; otherwise unlimited.
    function invariant_maxDepositMintReflectState() public view {
        Market storage m = _m();
        LidoLendMarketController c = LidoLendMarketController(address(m.controller));
        address a = actors[0]; // maxDeposit has no per-user limit here, so any actor is representative

        if (c.isPaused()) {
            assertEq(m.vault.maxDeposit(a), 0, "paused: maxDeposit == 0");
            assertEq(m.vault.maxMint(a), 0, "paused: maxMint == 0");
            return;
        }
        uint256 cap = c.supplyCap();
        if (cap == 0) {
            assertEq(m.vault.maxDeposit(a), type(uint256).max, "uncapped: maxDeposit unlimited");
            assertEq(m.vault.maxMint(a), type(uint256).max, "uncapped: maxMint unlimited");
        } else {
            // headroom is measured against the ACCRUED supply, matching the controller's maxDeposit()
            // (which reads `expectedMarketBalances`); the stored total lags by any un-accrued interest.
            (uint256 tSA,,,) = MorphoBalancesLib.expectedMarketBalances(IMorpho(address(m.core)), m.params);
            assertEq(m.vault.maxDeposit(a), cap > tSA ? cap - tSA : 0, "capped: maxDeposit == headroom");
        }
    }

    // ── new-mechanic ghosts ──

    /// @dev Standard exits use the ERC-4626 one-sided conversions: `withdraw(assets)` burns the exact
    ///      assets-to-shares conversion rounded up, while `redeem(shares)` pays the exact shares-to-assets conversion
    ///      rounded down.
    function invariant_standardExitRounding() public view {
        assertFalse(handler.withdrawRoundingMismatch(), "withdraw burned ceil(assets -> shares)");
        assertFalse(handler.redeemRoundingMismatch(), "redeem paid floor(shares -> assets)");
    }

    /// @dev For settlement claim `C` and consumed core shares `q`, the burn is exactly
    ///      `ceil(requestedVaultShares * q / C)`. A partial fill therefore burns less than one additional raw vault
    ///      share; when `q == C`, it burns exactly `requestedVaultShares`.
    function invariant_settlementRounding() public view {
        assertFalse(handler.settlementBurnMismatch(), "settlement burn matched its declared rounding");
        assertFalse(handler.fullSettlementBurnMismatch(), "full settlement fill burned the full request");
        assertFalse(handler.settlementShareRateDecreased(), "remaining holders received settlement rounding");
    }

    /// @dev A successful targeted settle requires a positive personal settlement-LTV slice at quote time.
    function invariant_targetedSettlementRequiresPersonalEligibility() public view {
        assertFalse(
            handler.targetedSettlementWithoutPersonalEligibility(),
            "targeted settlement required a positive personal slice"
        );
    }

    /// @dev A targeted settle cannot consume more core shares than the request's gross pro-rata claim.
    function invariant_targetedSettlementStaysWithinGrossClaim() public view {
        assertFalse(handler.targetedSettlementExceededGrossClaim(), "targeted settlement stayed within gross claim");
    }

    /// @dev Settlement collateral ends at the configured receiver and is not retained as vault backing.
    function invariant_settlementCollateralGoesToReceiver() public view {
        Market storage m = _m();
        assertFalse(handler.settlementCollateralPayoutMismatch(), "receiver received all settlement collateral");
        assertEq(m.collateralToken.balanceOf(address(m.vault)), 0, "vault retained no settlement collateral");
    }

    /// @dev A direct donation is uncounted, so it never moves the share price.
    function invariant_donationNeverMovesPrice() public view {
        assertFalse(handler.priceMovedByDonation(), "donation left the share price unchanged");
    }

    /// @dev No exit ever burns more shares than were requested.
    function invariant_exitBurnBounded() public view {
        assertFalse(handler.exitBurnedTooMuch(), "settle/fallbackExit burned <= requested shares");
    }

    /// @dev A targeted `settle` pays no loan and cancels debt and supply by the same amount, so it leaves the market's
    ///      free liquidity (utilization) unchanged.
    function invariant_settleIsLiquidityNeutral() public view {
        assertFalse(handler.settleMovedLiquidity(), "settle left free liquidity unchanged");
    }

    /// @dev `fallbackExit` drops free liquidity by exactly its redeem-leg payout; its settle leg is liquidity-neutral.
    function invariant_fallbackExitIdleMatchesRedeem() public view {
        assertFalse(handler.fallbackExitLiquidityMismatch(), "fallbackExit idle drop == its loan payout");
    }

    /// @dev Settlement runs at par with no penalty: the seized collateral is worth at most the debt it cancels,
    ///      even when its value is rounded up against the market.
    function invariant_settlementRunsAtPar() public view {
        assertFalse(handler.parViolated(), "seized collateral value <= cancelled debt (par, no penalty)");
    }

    /// @dev A settle's collateral payout, valued at the oracle price rounded up, never exceeds the down-rounded
    ///      value of the borrow shares it cancelled.
    function invariant_settlePayoutWithinCut() public view {
        assertFalse(handler.settlePayoutExceededCut(), "seized value (up) <= down-rounded cancelled cut");
    }

    /// @dev The supply shares a settle burns are worth at least the debt it cancels, so a settler — including
    ///      one settling their own debt — cannot receive more value than they burned.
    function invariant_settleBurnCoversDebt() public view {
        assertFalse(handler.settleBurnBelowDebt(), "burned supply shares are worth >= the cancelled debt");
    }

    /// @dev The `debtCanceled` a settle reports equals the up-rounded value of the borrow shares it actually
    ///      removed, and the market's borrow assets fall by exactly that amount.
    function invariant_settleDebtReportMatchesDeltas() public view {
        assertFalse(handler.settleDebtReportMismatch(), "reported debtCanceled == up-rounded observed share delta");
    }

    /// @dev Exact conservation across both exit paths: total supply assets fall by exactly the redeem payout plus
    ///      the cancelled debt, and the core's loan-token balance falls by exactly what the exit paid out of it.
    function invariant_settleConservesAccounting() public view {
        assertFalse(handler.settleSupplyAssetsMismatch(), "supply assets removed == redeem payout + cancelled debt");
        assertFalse(handler.settleMovedLoanToken(), "core loan-token balance moved only by the exit's payout");
    }

    /// @dev Checked settlement-budget accounting must never underflow in either exit path.
    function invariant_settlementNeverPanics() public view {
        assertFalse(handler.settlementArithmeticPanicked(), "settle/fallbackExit never panic");
    }

    function afterInvariant() public {
        emit log_named_uint("deposits", handler.deposits());
        emit log_named_uint("withdraws", handler.withdraws());
        emit log_named_uint("redeems", handler.redeems());
        emit log_named_uint("settles", handler.settles());
        emit log_named_uint("fallbackExits", handler.fallbackExits());
        emit log_named_uint("withdrawRoundUpCases", handler.withdrawRoundUpCases());
        emit log_named_uint("redeemRoundDownCases", handler.redeemRoundDownCases());
        emit log_named_uint("partialSettlementFills", handler.partialSettlementFills());
        emit log_named_uint("settlementRoundUpCases", handler.settlementRoundUpCases());
        emit log_named_uint("fullSettlementFills", handler.fullSettlementFills());
        emit log_named_uint("nothingSettledReverts", handler.nothingSettledReverts());
        emit log_named_uint("positiveSettlementLtvUpdates", handler.positiveSettlementLtvUpdates());
        emit log_named_uint("eligibleTargetedSettlementCalls", handler.eligibleTargetedSettlementCalls());
        emit log_named_uint("mixedFallbackSettlementFills", handler.mixedFallbackSettlementFills());
        emit log_named_uint("collateralPayouts", handler.collateralPayouts());
        emit log_named_uint("settlementDustReverts", handler.settlementDustReverts());
        emit log_named_uint("borrows", handler.borrows());
        emit log_named_uint("crashes", handler.crashes());
        emit log_named_uint("liquidations", handler.liquidations());
        emit log_named_uint("donations", handler.donations());
        emit log_named_uint("pauses", handler.pauses());
        emit log_named_uint("caps", handler.caps());
    }
}
