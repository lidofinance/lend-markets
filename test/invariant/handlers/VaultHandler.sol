// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Vm} from "forge-std/Vm.sol";
import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {ILidoLend} from "@lido-lend/src/interfaces/ILidoLend.sol";
import {Id, MarketParams, Position, Market as MorphoMarket} from "@lido-lend/src/interfaces/IMorpho.sol";
import {IOracle} from "@lido-lend/src/interfaces/IOracle.sol";

import {ILidoLendERC4626} from "../../../src/interfaces/ILidoLendERC4626.sol";
import {ILidoLendMarketController} from "../../../src/interfaces/ILidoLendMarketController.sol";
import {LidoLendMarketController} from "../../../src/controllers/LidoLendMarketController.sol";
import {PausableUntil} from "../../../src/utils/PausableUntil.sol";
import {MockPriceOracle} from "../../setup/Mocks.sol";

/// @notice Handler for the vault invariant suite. On top of the market actions (borrow/repay/crash/warp/liquidate)
///         it drives the ERC-4626 surface (deposit/mint/withdraw/redeem) and the NEW vault mechanics (targeted
///         `settle`, `fallbackExit`, personal settlement-LTV updates, direct donations). Around each new-mechanic
///         call it records ghosts the
///         invariants read: standard exits and settlement must follow their declared one-sided rounding, settlement
///         collateral must reach the receiver without being retained by the vault, a direct donation cannot move the
///         price, and no exit may over-burn.
contract VaultHandler is CommonBase, StdCheats, StdUtils {
    struct SettlementState {
        uint256 vaultSupply;
        uint256 vaultAssets;
        uint256 coreSupplyShares;
        uint256 coreTotalSupplyAssets;
        uint256 coreTotalSupplyShares;
        uint256 coreTotalBorrowAssets;
        uint256 coreTotalBorrowShares;
        uint256 coreLoanBalance;
        uint256 borrowerShares; // the targeted borrower's debt shares; filled by the settle path only
        uint256 withdrawableAssets;
        uint256 idle;
        uint256 receiverCollateral;
        uint256 receiverLoan;
        uint256 oraclePrice;
    }

    struct ExitPayout {
        uint256 redeemAssets;
        uint256 loanAssets;
        uint256 receivedWhole;
        uint256 fraction;
    }

    struct CutRoundingState {
        uint256 supplyAssets;
        uint256 supplyShares;
        uint256 borrowAssets;
        uint256 borrowShares;
        uint256 consumedSupplyShares;
        uint256 cuts;
        uint256 roundingScaled;
    }

    struct CoreSettlement {
        address caller;
        address receiver;
        uint256 supplySharesBurned;
        uint256 borrowAssetsCanceled;
        uint256 borrowSharesCanceled;
        uint256 seizedAssets;
    }

    ILidoLend internal immutable CORE;
    ILidoLendERC4626 internal immutable VAULT;
    ILidoLendMarketController internal immutable CONTROLLER;
    IERC20 internal immutable LOAN;
    IERC20 internal immutable COLLATERAL;
    MarketParams internal params;
    Id internal immutable ID;
    uint256 internal immutable SEED_PRICE;
    address internal immutable ORACLE;
    uint256 internal immutable VAULT_VIRTUAL_SHARES;
    uint256 internal immutable LOAN_UNIT;
    uint256 internal constant LLTV = 0.8e18;
    uint256 internal constant FLOOR = 10 ether;
    uint8 internal constant VAULT_SHARE_DECIMALS = 18;
    uint256 internal constant CORE_VIRTUAL_SHARES = 1e6;
    uint256 internal constant CORE_VIRTUAL_ASSETS = 1;
    uint256 internal constant PAYOUT_SCALE = 1e36;
    bytes32 internal constant CORE_SETTLE_TOPIC =
        keccak256("Settle(bytes32,address,address,address,address,uint256,uint256,uint256,uint256)");
    bytes4 internal constant PANIC_SELECTOR = 0x4e487b71;
    uint256 internal constant ARITHMETIC_PANIC_CODE = 0x11;
    bytes32 internal constant SETTLEMENT_SLICE_TOO_SMALL_HASH = keccak256("settlement slice too small");
    address[] internal actors;

    // Ghosts read by the invariants.
    bool public withdrawRoundingMismatch; // withdraw did not burn ceil(assets -> vault shares)
    bool public redeemRoundingMismatch; // redeem did not pay floor(vault shares -> assets)
    bool public settlementBurnMismatch; // a settle leg did not match its declared pro-rata rounding
    bool public fullSettlementBurnMismatch; // a consumed full core claim did not burn the full request
    bool public settlementShareRateDecreased; // remaining vault shares own fewer core shares pro-rata
    bool public settlementCollateralPayoutMismatch; // receiver balance delta did not equal returned collateral
    bool public targetedSettlementWithoutPersonalEligibility; // a targeted settle filled without a personal slice
    bool public targetedSettlementExceededGrossClaim; // targeted settle consumed more than the request's core claim
    bool public priceMovedByDonation; // a direct donation shifted the share price
    bool public exitBurnedTooMuch; // an exit burned more shares than requested
    bool public settleLiquidityMismatch; // idle delta differs from the final debt-rounding adjustment
    bool public fallbackExitLiquidityMismatch; // idle drop differs from liquid payout plus debt-rounding adjustment
    bool public parViolated; // an exit seized collateral worth MORE than the debt it cancelled (a penalty)
    bool public settlePayoutExceededCut; // a settle's seized value (rounded up) exceeded its down-rounded debt cut
    bool public settleBurnBelowDebt; // a settle burned core supply shares worth less than the debt it cancelled
    bool public settleSupplyAssetsMismatch; // supply assets removed != redeem payout + cancelled debt
    bool public settleDebtReportMismatch; // debtCanceled != the observed cut's value, or borrow totals off it
    bool public settleMovedLoanToken; // the core's loan-token balance moved by other than what the exit paid out
    bool public settlementArithmeticPanicked; // settle / fallbackExit reverted with Panic(0x11)
    bool public exitPayoutBoundViolated;
    string public exitPayoutBoundFailure;
    uint256 public totalDonated; // loan tokens sent straight to the vault (uncounted)

    // Coverage counters.
    uint256 public deposits;
    uint256 public withdraws;
    uint256 public redeems;
    uint256 public settles;
    uint256 public fallbackExits;
    uint256 public withdrawRoundUpCases;
    uint256 public redeemRoundDownCases;
    uint256 public partialSettlementFills;
    uint256 public settlementRoundUpCases;
    uint256 public fullSettlementFills;
    uint256 public nothingSettledReverts;
    uint256 public positiveSettlementLtvUpdates;
    uint256 public eligibleTargetedSettlementCalls;
    uint256 public mixedFallbackSettlementFills;
    uint256 public collateralPayouts;
    uint256 public settlementDustReverts;
    uint256 public borrows;
    uint256 public crashes;
    uint256 public liquidations;
    uint256 public donations;
    uint256 public pauses;
    uint256 public caps;

    constructor(
        ILidoLend core,
        ILidoLendERC4626 vault,
        ILidoLendMarketController controller,
        IERC20 loan,
        IERC20 collateral,
        MarketParams memory p,
        Id id,
        uint256 oraclePrice,
        address oracle,
        address[] memory actors_
    ) {
        // The observers count each token's flows separately; one token on both roles would fold them together.
        require(address(loan) != address(collateral), "same-token market unsupported");
        CORE = core;
        VAULT = vault;
        CONTROLLER = controller;
        LOAN = loan;
        COLLATERAL = collateral;
        params = p;
        ID = id;
        SEED_PRICE = oraclePrice;
        ORACLE = oracle;
        uint8 assetDecimals = IERC20Metadata(vault.asset()).decimals();
        LOAN_UNIT = 10 ** assetDecimals;
        VAULT_VIRTUAL_SHARES = assetDecimals < VAULT_SHARE_DECIMALS ? 10 ** (VAULT_SHARE_DECIMALS - assetDecimals) : 1;
        actors = actors_;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _price() internal view returns (uint256) {
        return IOracle(ORACLE).price();
    }

    function _pps() internal view returns (uint256) {
        return VAULT.convertToAssets(1e18);
    }

    function _mintTo(IERC20 token, address to, uint256 add) internal {
        deal(address(token), to, token.balanceOf(to) + add);
    }

    function _idle() internal view returns (uint256) {
        MorphoMarket memory mk = CORE.market(ID);
        return mk.totalSupplyAssets - mk.totalBorrowAssets;
    }

    /// @dev Derive consumed shares `q` and the ceiling burn from redemption budget `C` and core state deltas.
    function _settlementModel(uint256 requestedShares, uint256 claim, uint256 coreSharesBefore, uint256 coreSharesAfter)
        internal
        pure
        returns (uint256 settled, uint256 expectedBurn, bool invalid)
    {
        if (coreSharesAfter > coreSharesBefore || claim == 0) return (0, 0, true);

        settled = coreSharesBefore - coreSharesAfter;
        if (settled > claim) return (0, 0, true);

        // `C = claim`, `q = settled`: burn exactly `ceil(requestedShares * q / C)`.
        expectedBurn = Math.mulDiv(requestedShares, settled, claim);
        if (mulmod(requestedShares, settled, claim) != 0) ++expectedBurn;
    }

    /// @dev Compares two nonnegative fractions without overflowing either cross-product.
    function _fractionLess(
        uint256 leftNumerator,
        uint256 leftDenominator,
        uint256 rightNumerator,
        uint256 rightDenominator
    ) internal pure returns (bool) {
        (uint256 leftHigh, uint256 leftLow) = Math.mul512(leftNumerator, rightDenominator);
        (uint256 rightHigh, uint256 rightLow) = Math.mul512(rightNumerator, leftDenominator);
        return leftHigh < rightHigh || (leftHigh == rightHigh && leftLow < rightLow);
    }

    /// @dev Snapshots every input needed to model a settle or both legs of a fallback exit.
    function _settlementState(address receiver) internal view returns (SettlementState memory state) {
        MorphoMarket memory market_ = CORE.market(ID);
        state.vaultSupply = VAULT.totalSupply();
        state.vaultAssets = VAULT.totalAssets();
        state.coreSupplyShares = CORE.position(ID, address(VAULT)).supplyShares;
        state.coreTotalSupplyAssets = market_.totalSupplyAssets;
        state.coreTotalSupplyShares = market_.totalSupplyShares;
        state.coreTotalBorrowAssets = market_.totalBorrowAssets;
        state.coreTotalBorrowShares = market_.totalBorrowShares;
        state.coreLoanBalance = LOAN.balanceOf(address(CORE));
        state.withdrawableAssets = CONTROLLER.maxWithdrawableAssets(address(VAULT));
        state.idle = market_.totalSupplyAssets - market_.totalBorrowAssets;
        state.receiverCollateral = COLLATERAL.balanceOf(receiver);
        state.receiverLoan = LOAN.balanceOf(receiver);
        state.oraclePrice = _price();
    }

    /// @dev Price both observed receipts against the burned shares at the pre-call ERC-4626 conversion.
    function _exitPayout(SettlementState memory before, address receiver)
        internal
        view
        returns (ExitPayout memory payout)
    {
        uint256 burnedShares = before.vaultSupply - VAULT.totalSupply();
        payout.redeemAssets =
            Math.mulDiv(burnedShares, before.vaultAssets + 1, before.vaultSupply + VAULT_VIRTUAL_SHARES);
        payout.loanAssets = LOAN.balanceOf(receiver) - before.receiverLoan;
        uint256 collateralReceived = COLLATERAL.balanceOf(receiver) - before.receiverCollateral;
        payout.receivedWhole = payout.loanAssets + Math.mulDiv(collateralReceived, before.oraclePrice, PAYOUT_SCALE);
        payout.fraction = mulmod(collateralReceived, before.oraclePrice, PAYOUT_SCALE);
    }

    /// @dev Replay the borrow-share cuts from pre-call totals. Neither the reported collateral nor the receiver's
    ///      collateral balance enters the model. mulmod keeps each oracle remainder exact at 1e-36 loan precision.
    function _executedCuts(SettlementState memory before, uint256 loanAssets)
        internal
        returns (CutRoundingState memory state)
    {
        state.supplyAssets = before.coreTotalSupplyAssets - loanAssets;
        state.supplyShares = before.coreTotalSupplyShares
            - Math.mulDiv(
                loanAssets,
                before.coreTotalSupplyShares + CORE_VIRTUAL_SHARES,
                before.coreTotalSupplyAssets + 1,
                Math.Rounding.Ceil
            );
        state.borrowAssets = before.coreTotalBorrowAssets;
        state.borrowShares = before.coreTotalBorrowShares;
        Vm.Log[] memory entries = vm.getRecordedLogs();
        for (uint256 i; i < entries.length; ++i) {
            Vm.Log memory entry = entries[i];
            if (
                entry.emitter == address(CORE) && entry.topics.length == 4 && entry.topics[0] == CORE_SETTLE_TOPIC
                    && entry.topics[1] == Id.unwrap(ID) && entry.topics[2] == bytes32(uint256(uint160(address(VAULT))))
            ) _observeCutRounding(state, abi.decode(entry.data, (CoreSettlement)), before.oraclePrice);
        }
        MorphoMarket memory after_ = CORE.market(ID);
        require(
            state.supplyAssets == after_.totalSupplyAssets && state.supplyShares == after_.totalSupplyShares
                && state.borrowAssets == after_.totalBorrowAssets && state.borrowShares == after_.totalBorrowShares,
            "rounding model matches core totals"
        );
    }

    function _observeCutRounding(CutRoundingState memory state, CoreSettlement memory cut, uint256 price)
        internal
        pure
    {
        uint256 debtDown =
            Math.mulDiv(cut.borrowSharesCanceled, state.borrowAssets + 1, state.borrowShares + CORE_VIRTUAL_SHARES);
        uint256 debtRounding = mulmod(
                cut.borrowSharesCanceled, state.borrowAssets + 1, state.borrowShares + CORE_VIRTUAL_SHARES
            ) == 0
            ? 0
            : 1;
        uint256 debtUp = debtDown + debtRounding;
        uint256 supplyBurn =
            Math.mulDiv(debtUp, state.supplyShares + CORE_VIRTUAL_SHARES, state.supplyAssets + 1, Math.Rounding.Ceil);
        require(
            cut.borrowAssetsCanceled == debtUp && cut.supplySharesBurned == supplyBurn,
            "rounding model matches core cut"
        );
        state.roundingScaled += debtRounding * PAYOUT_SCALE + mulmod(debtDown, PAYOUT_SCALE, price);
        state.consumedSupplyShares += supplyBurn;
        ++state.cuts;
        state.supplyAssets -= debtUp;
        state.supplyShares -= supplyBurn;
        state.borrowAssets = state.borrowAssets > debtUp ? state.borrowAssets - debtUp : 0;
        state.borrowShares -= cut.borrowSharesCanceled;
    }

    /// @dev U = consumed core supply shares, n = cuts, r = core share value immediately after the liquid leg.
    ///      Ceiling each supply-share burn gives (U-n)*r < cancelled debt <= U*r when n > 0.
    ///      Thus E_min = L + floor((U-n)*r) + 1 - T - R; E_max = L + floor(U*r) - T - R.
    ///      L = loan payout, R = pre-call previewRedeem(burned), T = sum of debt ceil/floor gaps and oracle dust.
    ///      With no cuts both bounds are L-R. All values use raw loan units, scaled by 1e36 for exact fractions.
    function _cutRoundingInterval(SettlementState memory before, ExitPayout memory payout, CutRoundingState memory cuts)
        internal
        pure
        returns (int256 lower, int256 upper)
    {
        uint256 minimumDebt;
        uint256 maximumDebt;
        if (cuts.cuts != 0) {
            uint256 supplyShares = before.coreTotalSupplyShares
                - Math.mulDiv(
                    payout.loanAssets,
                    before.coreTotalSupplyShares + CORE_VIRTUAL_SHARES,
                    before.coreTotalSupplyAssets + 1,
                    Math.Rounding.Ceil
                );
            uint256 supplyAssets = before.coreTotalSupplyAssets - payout.loanAssets;
            minimumDebt = Math.mulDiv(
                cuts.consumedSupplyShares - cuts.cuts, supplyAssets + 1, supplyShares + CORE_VIRTUAL_SHARES
            ) + 1;
            maximumDebt = Math.mulDiv(cuts.consumedSupplyShares, supplyAssets + 1, supplyShares + CORE_VIRTUAL_SHARES);
        }
        lower = (int256(payout.loanAssets + minimumDebt) - int256(payout.redeemAssets)) * int256(PAYOUT_SCALE)
            - int256(cuts.roundingScaled);
        upper = (int256(payout.loanAssets + maximumDebt) - int256(payout.redeemAssets)) * int256(PAYOUT_SCALE)
            - int256(cuts.roundingScaled);
    }

    function _observeExitPayoutBound(SettlementState memory before, address receiver) internal {
        ExitPayout memory payout = _exitPayout(before, receiver);
        CutRoundingState memory cuts = _executedCuts(before, payout.loanAssets);
        require(
            (cuts.cuts == 0) == (payout.receivedWhole == payout.loanAssets && payout.fraction == 0),
            "cut event coverage"
        );
        require(_price() == before.oraclePrice, "rounding bound requires a constant in-call oracle price");
        (int256 lower, int256 upper) = _cutRoundingInterval(before, payout, cuts);
        // The rounding interval alone permits overpayment; the ERC-4626 entitlement additionally requires E <= 0.
        if (upper > 0) upper = 0;
        int256 actual = (int256(payout.receivedWhole) - int256(payout.redeemAssets)) * int256(PAYOUT_SCALE)
            + int256(payout.fraction);
        if (!exitPayoutBoundViolated && (actual < lower || actual > upper)) {
            exitPayoutBoundViolated = true;
            exitPayoutBoundFailure = string.concat(
                "payout minus pre-call previewRedeem(burned shares): E=",
                _formatSigned(actual),
                "; min=",
                _formatSigned(lower),
                "; max=",
                _formatSigned(upper),
                "; cuts=",
                vm.toString(cuts.cuts),
                " (loan-token raw units)"
            );
        }
    }

    function _formatSigned(int256 value) internal pure returns (string memory) {
        uint256 magnitude = uint256(value < 0 ? -value : value);
        return
            string.concat(value < 0 ? "-" : "", _formatOracleValue(magnitude / PAYOUT_SCALE, magnitude % PAYOUT_SCALE));
    }

    /// @dev The oracle denominator is 1e36, so 36 zero-padded decimal digits represent the remainder exactly.
    function _formatOracleValue(uint256 whole, uint256 fraction) internal pure returns (string memory) {
        if (fraction == 0) return vm.toString(whole);
        bytes memory padded = bytes(vm.toString(1e36 + fraction));
        bytes memory decimals = new bytes(36);
        for (uint256 i; i < decimals.length; ++i) {
            decimals[i] = padded[i + 1];
        }
        return string.concat(vm.toString(whole), ".", string(decimals));
    }

    /// @dev Checks the exact settlement burn and the core-share entitlement left to each remaining vault share.
    function _observeSettlementLeg(
        uint256 requestedShares,
        uint256 actualBurn,
        uint256 supplyBefore,
        uint256 coreSharesBefore,
        uint256 coreSharesAfter,
        uint256 claim
    ) internal {
        (uint256 settled, uint256 expectedBurn, bool invalid) =
            _settlementModel(requestedShares, claim, coreSharesBefore, coreSharesAfter);
        if (invalid) {
            settlementBurnMismatch = true;
            return;
        }

        if (actualBurn != expectedBurn) settlementBurnMismatch = true;
        if (settled != 0) {
            if (settled < claim) ++partialSettlementFills;
            if (mulmod(requestedShares, settled, claim) != 0) ++settlementRoundUpCases;
        }
        if (settled == claim) {
            ++fullSettlementFills;
            if (actualBurn != requestedShares) fullSettlementBurnMismatch = true;
        }

        uint256 supplyAfter = VAULT.totalSupply();
        if (actualBurn > supplyBefore || supplyAfter != supplyBefore - actualBurn) settlementBurnMismatch = true;
        if (supplyAfter != 0 && _fractionLess(coreSharesAfter, supplyAfter, coreSharesBefore, supplyBefore)) {
            settlementShareRateDecreased = true;
        }
    }

    function _observeTargetedSettlementLeg(uint256 shares, uint256 burnedShares, SettlementState memory before)
        internal
    {
        _observeSettlementLeg(
            shares,
            burnedShares,
            before.vaultSupply,
            before.coreSupplyShares,
            CORE.position(ID, address(VAULT)).supplyShares,
            _redemptionCoreClaim(shares, before, 0)
        );
    }

    /// @dev Model the request's ERC-4626 entitlement and round it down into core shares, after any liquid leg.
    function _redemptionCoreClaim(uint256 requestedShares, SettlementState memory before, uint256 loanAssets)
        internal
        view
        returns (uint256)
    {
        uint256 coreBurn = Math.mulDiv(
            loanAssets,
            before.coreTotalSupplyShares + CORE_VIRTUAL_SHARES,
            before.coreTotalSupplyAssets + 1,
            Math.Rounding.Ceil
        );
        uint256 vaultBurn = Math.mulDiv(
            loanAssets, before.vaultSupply + VAULT_VIRTUAL_SHARES, before.vaultAssets + 1, Math.Rounding.Ceil
        );
        uint256 coreAssets = before.coreTotalSupplyAssets - loanAssets;
        uint256 coreShares = before.coreTotalSupplyShares - coreBurn;
        uint256 vaultAssets =
            Math.mulDiv(before.coreSupplyShares - coreBurn, coreAssets + 1, coreShares + CORE_VIRTUAL_SHARES);
        uint256 assets =
            Math.mulDiv(requestedShares, vaultAssets + 1, before.vaultSupply - vaultBurn + VAULT_VIRTUAL_SHARES);
        return Math.mulDiv(assets, coreShares + CORE_VIRTUAL_SHARES, coreAssets + 1);
    }

    /// @dev In this sole-supplier fixture, the redemption budget also fits the gross pro-rata core-share claim.
    function _observeTargetedSettlementClaim(uint256 requestedShares, SettlementState memory before) internal {
        uint256 claim = Math.mulDiv(before.coreSupplyShares, requestedShares, before.vaultSupply);
        if (claim == 0) {
            targetedSettlementExceededGrossClaim = true;
            return;
        }

        uint256 coreSharesAfter = CORE.position(ID, address(VAULT)).supplyShares;
        if (coreSharesAfter > before.coreSupplyShares || before.coreSupplyShares - coreSharesAfter > claim) {
            targetedSettlementExceededGrossClaim = true;
        }
    }

    /// @dev Checks the configured receiver's token delta; owner and receiver are deliberately distinct in callers.
    function _observeCollateralPayout(uint256 collateralSeized, address receiver, SettlementState memory before)
        internal
    {
        uint256 collateralAfter = COLLATERAL.balanceOf(receiver);
        if (
            collateralAfter < before.receiverCollateral
                || collateralAfter - before.receiverCollateral != collateralSeized
        ) settlementCollateralPayoutMismatch = true;
        if (collateralSeized != 0) ++collateralPayouts;
    }

    /// @dev Reconstructs fallbackExit's pure-redeem or capped-withdraw leg from the pre-call state.
    function _fallbackLiquidLeg(uint256 requestedShares, SettlementState memory before)
        internal
        view
        returns (uint256 vaultSharesBurned, uint256 coreSharesBurned, uint256 loanAssets)
    {
        if (before.withdrawableAssets == 0) return (0, 0, 0);

        uint256 redeemAssets =
            Math.mulDiv(requestedShares, before.vaultAssets + 1, before.vaultSupply + VAULT_VIRTUAL_SHARES);
        if (redeemAssets <= before.withdrawableAssets) {
            vaultSharesBurned = requestedShares;
            loanAssets = redeemAssets;
        } else {
            loanAssets = before.withdrawableAssets;
            vaultSharesBurned = Math.mulDiv(
                loanAssets, before.vaultSupply + VAULT_VIRTUAL_SHARES, before.vaultAssets + 1, Math.Rounding.Ceil
            );
        }

        coreSharesBurned = Math.mulDiv(
            loanAssets,
            before.coreTotalSupplyShares + CORE_VIRTUAL_SHARES,
            before.coreTotalSupplyAssets + CORE_VIRTUAL_ASSETS,
            Math.Rounding.Ceil
        );
    }

    /// @dev Removes the modeled liquid leg, then checks the remaining settlement against its intermediate claim.
    function _observeFallbackExit(
        uint256 requestedShares,
        uint256 actualBurn,
        uint256 actualLoanAssets,
        SettlementState memory before
    ) internal {
        (uint256 liquidBurn, uint256 liquidCoreBurn, uint256 expectedLoanAssets) =
            _fallbackLiquidLeg(requestedShares, before);
        if (
            actualLoanAssets != expectedLoanAssets || liquidBurn > requestedShares || liquidBurn > actualBurn
                || liquidCoreBurn > before.coreSupplyShares
        ) {
            settlementBurnMismatch = true;
            return;
        }

        uint256 coreSharesAfter = CORE.position(ID, address(VAULT)).supplyShares;
        uint256 settlementRequest = requestedShares - liquidBurn;
        uint256 settlementBurn = actualBurn - liquidBurn;
        uint256 settlementCoreBefore = before.coreSupplyShares - liquidCoreBurn;
        if (settlementRequest == 0) {
            if (settlementBurn != 0 || coreSharesAfter != settlementCoreBefore) settlementBurnMismatch = true;
            return;
        }

        _observeFallbackSettlementLeg(requestedShares, settlementBurn, before, actualLoanAssets);
        if (liquidBurn != 0 && settlementBurn != 0) ++mixedFallbackSettlementFills;
    }

    function _observeFallbackSettlementLeg(
        uint256 requestedShares,
        uint256 burnedShares,
        SettlementState memory before,
        uint256 loanAssets
    ) internal {
        (uint256 liquidBurn, uint256 coreBurn,) = _fallbackLiquidLeg(requestedShares, before);
        uint256 settlementRequest = requestedShares - liquidBurn;
        uint256 claim = _redemptionCoreClaim(settlementRequest, before, loanAssets);
        _observeSettlementLeg(
            settlementRequest,
            burnedShares,
            before.vaultSupply - liquidBurn,
            before.coreSupplyShares - coreBurn,
            CORE.position(ID, address(VAULT)).supplyShares,
            claim
        );
    }

    function _ctrl() internal view returns (LidoLendMarketController) {
        return LidoLendMarketController(address(CONTROLLER));
    }

    function _paused() internal view returns (bool) {
        return _ctrl().isPaused();
    }

    /// @dev At par, seized collateral is the cancelled debt priced at the oracle, rounded down — so its value stays
    ///      at most the cancelled debt even when the conversion back is rounded UP against the market. A value above
    ///      the cancelled debt would be a penalty extracted from the borrower.
    function _seizedValueExceedsDebt(uint256 collateralSeized, uint256 debtCanceled) internal view returns (bool) {
        return Math.mulDiv(collateralSeized, _price(), 1e36, Math.Rounding.Ceil) > debtCanceled;
    }

    /// @dev Core shares to assets at the given totals, rounded down (the core's `toAssetsDown`).
    function _coreAssetsDown(uint256 shares, uint256 totalAssets, uint256 totalShares) internal pure returns (uint256) {
        return Math.mulDiv(shares, totalAssets + CORE_VIRTUAL_ASSETS, totalShares + CORE_VIRTUAL_SHARES);
    }

    /// @dev Core shares to assets at the given totals, rounded up (the core's `toAssetsUp`).
    function _coreAssetsUp(uint256 shares, uint256 totalAssets, uint256 totalShares) internal pure returns (uint256) {
        return
            Math.mulDiv(
                shares, totalAssets + CORE_VIRTUAL_ASSETS, totalShares + CORE_VIRTUAL_SHARES, Math.Rounding.Ceil
            );
    }

    /// @dev Value checks of a targeted settle, at the post-accrual pre-call totals and derived from state deltas
    ///      rather than return values. Rounding is measured against the settler — what they receive is valued up,
    ///      what they give is valued down — so a leak breaks an inequality instead of hiding in rounding slack.
    function _observeSettleValueBounds(
        SettlementState memory before,
        address borrower,
        uint256 collateralSeized,
        uint256 debtCanceled
    ) internal {
        uint256 borrowerSharesAfter = CORE.position(ID, borrower).borrowShares;
        if (borrowerSharesAfter > before.borrowerShares) {
            settlePayoutExceededCut = true;
            return;
        }
        uint256 sharesCanceled = before.borrowerShares - borrowerSharesAfter;

        uint256 cutDown = _coreAssetsDown(sharesCanceled, before.coreTotalBorrowAssets, before.coreTotalBorrowShares);
        if (Math.mulDiv(collateralSeized, _price(), 1e36, Math.Rounding.Ceil) > cutDown) {
            settlePayoutExceededCut = true;
        }

        // Recompute the reported cancel from the observed share delta instead of trusting the return value.
        if (debtCanceled != _coreAssetsUp(sharesCanceled, before.coreTotalBorrowAssets, before.coreTotalBorrowShares)) {
            settleDebtReportMismatch = true;
        }
        uint256 expectedBorrowAssets =
            before.coreTotalBorrowAssets > debtCanceled ? before.coreTotalBorrowAssets - debtCanceled : 0;
        if (CORE.market(ID).totalBorrowAssets != expectedBorrowAssets) settleDebtReportMismatch = true;

        uint256 coreSharesAfter = CORE.position(ID, address(VAULT)).supplyShares;
        if (coreSharesAfter > before.coreSupplyShares) {
            settleBurnBelowDebt = true;
            return;
        }
        uint256 burnedValue = _coreAssetsDown(
            before.coreSupplyShares - coreSharesAfter, before.coreTotalSupplyAssets, before.coreTotalSupplyShares
        );
        if (burnedValue < debtCanceled) settleBurnBelowDebt = true;
    }

    /// @dev Exact conservation of an exit, from the same pre-call snapshot: total supply assets fall by exactly
    ///      the redeem payout plus the cancelled debt (both exit paths decrement them by those two amounts and
    ///      nothing else), and the core's loan-token balance falls by exactly what the exit paid out of it.
    function _observeCoreConservation(SettlementState memory before, uint256 loanAssets, uint256 debtCanceled)
        internal
    {
        uint256 supplyAfter = CORE.market(ID).totalSupplyAssets;
        if (
            supplyAfter > before.coreTotalSupplyAssets
                || before.coreTotalSupplyAssets - supplyAfter != loanAssets + debtCanceled
        ) settleSupplyAssetsMismatch = true;

        // The redeem leg is the only loan-token outflow (the constructor bars same-token markets).
        uint256 loanAfter = LOAN.balanceOf(address(CORE));
        if (loanAfter > before.coreLoanBalance || before.coreLoanBalance - loanAfter != loanAssets) {
            settleMovedLoanToken = true;
        }
    }

    // ── ERC-4626 entry ──

    function deposit(uint256 actorSeed, uint256 amount) external {
        address a = _actor(actorSeed);
        uint256 room = VAULT.maxDeposit(a);
        if (!_paused() && room < LOAN_UNIT) return;
        amount = bound(amount, LOAN_UNIT, _paused() ? 1_000_000 * LOAN_UNIT : Math.min(room, 1_000_000 * LOAN_UNIT));
        _mintTo(LOAN, a, amount);
        vm.startPrank(a);
        LOAN.approve(address(VAULT), amount);
        if (_paused()) {
            vm.expectRevert(abi.encodeWithSelector(ERC4626Upgradeable.ERC4626ExceededMaxDeposit.selector, a, amount, 0));
            VAULT.deposit(amount, a);
            vm.stopPrank();
            return;
        }
        VAULT.deposit(amount, a);
        vm.stopPrank();
        deposits++;
    }

    function mint(uint256 actorSeed, uint256 shares) external {
        address a = _actor(actorSeed);
        uint256 shareRoom = VAULT.maxMint(a);
        if (!_paused() && shareRoom < 1e18) return;
        shares = bound(shares, 1e18, _paused() ? 1_000_000e18 : Math.min(shareRoom, 1_000_000e18));
        uint256 cost = VAULT.previewMint(shares);
        _mintTo(LOAN, a, cost);
        vm.startPrank(a);
        LOAN.approve(address(VAULT), cost);
        if (_paused()) {
            vm.expectRevert(abi.encodeWithSelector(ERC4626Upgradeable.ERC4626ExceededMaxMint.selector, a, shares, 0));
            VAULT.mint(shares, a);
            vm.stopPrank();
            return;
        }
        VAULT.mint(shares, a);
        vm.stopPrank();
        deposits++;
    }

    function withdraw(uint256 actorSeed, uint256 amount) external {
        address a = _actor(actorSeed);
        if (_paused()) {
            vm.prank(a);
            vm.expectRevert(abi.encodeWithSelector(ERC4626Upgradeable.ERC4626ExceededMaxWithdraw.selector, a, 1, 0));
            VAULT.withdraw(1, a, a);
            return;
        }
        uint256 max = VAULT.maxWithdraw(a);
        if (max == 0) return;
        amount = bound(amount, 1, max);

        uint256 supplyBefore = VAULT.totalSupply();
        uint256 assetsBefore = VAULT.totalAssets();
        uint256 balanceBefore = VAULT.balanceOf(a);
        uint256 expectedBurn =
            Math.mulDiv(amount, supplyBefore + VAULT_VIRTUAL_SHARES, assetsBefore + 1, Math.Rounding.Ceil);
        bool roundedUp = mulmod(amount, supplyBefore + VAULT_VIRTUAL_SHARES, assetsBefore + 1) != 0;

        vm.prank(a);
        uint256 actualBurn = VAULT.withdraw(amount, a, a);
        uint256 balanceAfter = VAULT.balanceOf(a);
        bool balanceMismatch = balanceAfter > balanceBefore || balanceBefore - balanceAfter != expectedBurn;
        if (actualBurn != expectedBurn || balanceMismatch) withdrawRoundingMismatch = true;
        if (roundedUp) ++withdrawRoundUpCases;
        withdraws++;
    }

    function redeem(uint256 actorSeed, uint256 shares) external {
        address a = _actor(actorSeed);
        if (_paused()) {
            vm.prank(a);
            vm.expectRevert(abi.encodeWithSelector(ERC4626Upgradeable.ERC4626ExceededMaxRedeem.selector, a, 1, 0));
            VAULT.redeem(1, a, a);
            return;
        }
        uint256 max = VAULT.maxRedeem(a);
        if (max == 0) return;
        shares = bound(shares, 1, max);

        uint256 supplyBefore = VAULT.totalSupply();
        uint256 assetsBefore = VAULT.totalAssets();
        uint256 sharesBefore = VAULT.balanceOf(a);
        uint256 assetsExpected = Math.mulDiv(shares, assetsBefore + 1, supplyBefore + VAULT_VIRTUAL_SHARES);
        bool roundedDown = mulmod(shares, assetsBefore + 1, supplyBefore + VAULT_VIRTUAL_SHARES) != 0;
        uint256 assetsBalanceBefore = LOAN.balanceOf(a);

        vm.prank(a);
        uint256 assetsActual = VAULT.redeem(shares, a, a);
        uint256 assetsBalanceAfter = LOAN.balanceOf(a);
        uint256 sharesAfter = VAULT.balanceOf(a);
        if (
            assetsActual != assetsExpected || assetsBalanceAfter < assetsBalanceBefore
                || assetsBalanceAfter - assetsBalanceBefore != assetsExpected || sharesAfter > sharesBefore
                || sharesBefore - sharesAfter != shares
        ) redeemRoundingMismatch = true;
        if (roundedDown) ++redeemRoundDownCases;
        redeems++;
    }

    // ── new mechanics: settle / fallbackExit / donation ──

    /// @dev Target one borrower. A successful call must have a positive personal settlement-LTV slice at quote time,
    ///      and its burn must be the ceiling-rounded fraction of the redemption budget consumed.
    function settle(uint256 ownerSeed, uint256 borrowerSeed, uint256 shares) external {
        address owner = _actor(ownerSeed);
        uint256 bal = VAULT.balanceOf(owner);
        if (bal == 0 || _paused() || CONTROLLER.hasBadDebt() || CONTROLLER.settlementBorrowersCount() == 0) return;

        address borrower = _actor(borrowerSeed);
        if (CORE.position(ID, borrower).borrowShares == 0) return;
        address[] memory borrowers = new address[](1);
        borrowers[0] = borrower;

        CORE.accrueInterest(params); // isolate the pro-rata burn from interest
        (, uint256 personalSlice) = CONTROLLER.settlementLtv(borrower);
        if (personalSlice != 0) ++eligibleTargetedSettlementCalls;

        address receiver = actors[(ownerSeed % actors.length + 1) % actors.length];
        SettlementState memory before = _settlementState(receiver);
        before.borrowerShares = CORE.position(ID, borrower).borrowShares;
        shares = bound(shares, 1, bal);
        vm.recordLogs();
        vm.prank(owner);
        uint256 sharesBurned;
        uint256 collateralSeized;
        uint256 debtCanceled;
        try VAULT.settle(shares, borrowers, receiver, owner) returns (
            uint256 sharesBurned_, uint256 collateralSeized_, uint256 debtCanceled_
        ) {
            sharesBurned = sharesBurned_;
            collateralSeized = collateralSeized_;
            debtCanceled = debtCanceled_;
        } catch Panic(uint256 code) {
            _recordSettlementPanicOrRevert(code);
            return;
        } catch Error(string memory reason) {
            _recordExpectedSettlementErrorOrRevert(reason);
            return;
        } catch (bytes memory reason) {
            _recordExpectedSettlementCustomErrorOrRevert(reason);
            return;
        }

        if (sharesBurned > shares) exitBurnedTooMuch = true;
        if (personalSlice == 0) targetedSettlementWithoutPersonalEligibility = true;
        _observeTargetedSettlementClaim(shares, before);
        _observeTargetedSettlementLeg(shares, sharesBurned, before);
        _observeCollateralPayout(collateralSeized, receiver, before);
        // Supply loses the full up-rounded debt, but the core floors remaining borrow assets at zero.
        uint256 debtRounding = Math.saturatingSub(debtCanceled, before.coreTotalBorrowAssets);
        if (_idle() + debtRounding != before.idle) settleLiquidityMismatch = true;
        if (_seizedValueExceedsDebt(collateralSeized, debtCanceled)) parViolated = true;
        _observeSettleValueBounds(before, borrower, collateralSeized, debtCanceled);
        _observeCoreConservation(before, 0, debtCanceled);
        _observeExitPayoutBound(before, receiver);
        settles++;
    }

    /// @dev Redeem the liquid part then settle the rest. The model reconstructs the intermediate state after the
    ///      liquid leg, then checks the settle leg against that live core-share claim. Skips when a bad-debt root
    ///      would revert the settle leg.
    function fallbackExit(uint256 actorSeed, uint256 shares, uint256 iterations) external {
        address owner = _actor(actorSeed);
        uint256 bal = VAULT.balanceOf(owner);
        if (bal == 0 || _paused() || CONTROLLER.hasBadDebt()) return;

        CORE.accrueInterest(params);
        address receiver = actors[(actorSeed % actors.length + 1) % actors.length];
        SettlementState memory before = _settlementState(receiver);
        shares = bound(shares, 1, bal);
        vm.recordLogs();
        vm.prank(owner);
        uint256 sharesBurned;
        uint256 loanAssets;
        uint256 collateralSeized;
        uint256 debtCanceled;
        try VAULT.fallbackExit(shares, receiver, owner, bound(iterations, 0, 50)) returns (
            uint256 sharesBurned_, uint256 loanAssets_, uint256 collateralSeized_, uint256 debtCanceled_
        ) {
            sharesBurned = sharesBurned_;
            loanAssets = loanAssets_;
            collateralSeized = collateralSeized_;
            debtCanceled = debtCanceled_;
        } catch Panic(uint256 code) {
            _recordSettlementPanicOrRevert(code);
            return;
        } catch Error(string memory reason) {
            _recordExpectedSettlementErrorOrRevert(reason);
            return;
        } catch (bytes memory reason) {
            _recordExpectedSettlementCustomErrorOrRevert(reason);
            return;
        }

        if (sharesBurned > shares) exitBurnedTooMuch = true;
        _observeFallbackExit(shares, sharesBurned, loanAssets, before);
        _observeCollateralPayout(collateralSeized, receiver, before);
        // Include any final debt rounding beyond the borrow-asset balance; it moves accounting, not loan tokens.
        uint256 idleAfter = _idle();
        uint256 debtRounding = Math.saturatingSub(debtCanceled, before.coreTotalBorrowAssets);
        if (idleAfter + loanAssets + debtRounding != before.idle) fallbackExitLiquidityMismatch = true;
        if (_seizedValueExceedsDebt(collateralSeized, debtCanceled)) parViolated = true;
        _observeCoreConservation(before, loanAssets, debtCanceled);
        _observeExitPayoutBound(before, receiver);
        fallbackExits++;
    }

    /// @dev A direct loan-token donation to the vault. `totalAssets` counts only the Morpho position, so this is
    ///      uncounted and must not move the share price.
    function donate(uint256 amount) external {
        if (_paused()) {
            vm.expectRevert(PausableUntil.ResumedExpected.selector);
            CORE.accrueInterest(params);
            return;
        }
        amount = bound(amount, 1, 1_000_000 * LOAN_UNIT);
        CORE.accrueInterest(params);
        uint256 ppsBefore = _pps();
        _mintTo(LOAN, address(this), amount);
        LOAN.transfer(address(VAULT), amount);
        if (_pps() != ppsBefore) priceMovedByDonation = true;
        totalDonated += amount;
        donations++;
    }

    // ── market actions to reach illiquid / distressed states ──

    function supplyCollateral(uint256 actorSeed, uint256 amount) external {
        address a = _actor(actorSeed);
        amount = bound(amount, 50e18, 1_000_000e18);
        _mintTo(COLLATERAL, a, amount);
        vm.startPrank(a);
        COLLATERAL.approve(address(CORE), amount);
        if (_paused()) vm.expectRevert(PausableUntil.ResumedExpected.selector);
        CORE.supplyCollateral(params, amount, a, "");
        vm.stopPrank();
    }

    function borrow(uint256 actorSeed, uint256 amount) external {
        address a = _actor(actorSeed);
        Position memory pos = CORE.position(ID, a);
        if (pos.collateral < FLOOR) return;
        if (!_paused()) CORE.accrueInterest(params);
        MorphoMarket memory mk = CORE.market(ID);
        uint256 maxBorrow = Math.mulDiv(Math.mulDiv(pos.collateral, _price(), 1e36), LLTV, 1e18);
        uint256 debt =
            mk.totalBorrowShares == 0 ? 0 : Math.mulDiv(pos.borrowShares, mk.totalBorrowAssets, mk.totalBorrowShares);
        if (maxBorrow <= debt) return;
        uint256 healthRoom = (maxBorrow - debt) * 99 / 100;
        uint256 liquidity = mk.totalSupplyAssets - mk.totalBorrowAssets;
        uint256 room = healthRoom < liquidity ? healthRoom : liquidity;
        if (room < LOAN_UNIT) return;
        amount = bound(amount, LOAN_UNIT, room);
        uint256 mintShares = Math.mulDiv(
            amount, uint256(mk.totalBorrowShares) + 1e6, uint256(mk.totalBorrowAssets) + 1, Math.Rounding.Ceil
        );
        if (mintShares > type(uint128).max) return;
        bool paused = _paused();
        if (paused) vm.expectRevert(PausableUntil.ResumedExpected.selector);
        vm.prank(a);
        CORE.borrow(params, amount, 0, a, a);
        if (!paused) borrows++;
    }

    /// @dev Opt a live borrower into a target far enough below its current LTV to produce a positive personal slice.
    function setSettlementLtv(uint256 actorSeed, uint256 targetSeed) external {
        address borrower = _actor(actorSeed);
        Position memory position = CORE.position(ID, borrower);
        if (position.borrowShares == 0 || position.collateral == 0 || CONTROLLER.hasBadDebt()) return;

        ILidoLendMarketController.BorrowerPosition memory dashboard = CONTROLLER.positionOf(borrower);
        uint256 collateralValue = Math.mulDiv(position.collateral, _price(), 1e36);
        if (dashboard.debtAssets == 0 || collateralValue == 0) return;

        uint256 currentLtv = Math.mulDiv(dashboard.debtAssets, 1e18, collateralValue);
        uint256 maxTarget = Math.min(currentLtv / 2, 1e18 - 1);
        if (maxTarget == 0) return;

        uint256 target = bound(targetSeed, 1, maxTarget);
        vm.prank(borrower);
        CONTROLLER.setSettlementLtv(target);

        (, uint256 personalSlice) = CONTROLLER.settlementLtv(borrower);
        if (personalSlice != 0) ++positiveSettlementLtvUpdates;
    }

    function repay(uint256 actorSeed, uint256 amount) external {
        address a = _actor(actorSeed);
        Position memory pos = CORE.position(ID, a);
        if (pos.borrowShares == 0) return;
        if (!_paused()) CORE.accrueInterest(params);
        MorphoMarket memory mk = CORE.market(ID);
        uint256 shares = bound(amount, 1, pos.borrowShares);
        uint256 owed = Math.mulDiv(
            shares, uint256(mk.totalBorrowAssets) + 1, uint256(mk.totalBorrowShares) + 1e6, Math.Rounding.Ceil
        );
        _mintTo(LOAN, a, owed);
        vm.startPrank(a);
        LOAN.approve(address(CORE), owed);
        if (_paused()) vm.expectRevert(PausableUntil.ResumedExpected.selector);
        CORE.repay(params, 0, shares, a, "");
        vm.stopPrank();
    }

    function warp(uint256 dt) external {
        dt = bound(dt, 1 hours, 30 days);
        vm.warp(block.timestamp + dt);
        if (!_paused()) CORE.accrueInterest(params); // accrue gates on resume; let time advance so a pause expires
    }

    // ── governance state: pause / resume and the supply cap (the max* MUST track these) ──

    function pauseResume(uint256 seed) external {
        LidoLendMarketController c = _ctrl();
        if (c.isPaused()) c.resume();
        else c.pauseFor(bound(seed, 1 hours, 3 days));
        pauses++;
    }

    function setSupplyCap(uint256 seed) external {
        uint256 tSA = CORE.market(ID).totalSupplyAssets;
        // Mostly a binding cap near the current supply; sometimes uncap (0 == unlimited).
        _ctrl().setSupplyCap(seed % 4 == 0 ? 0 : tSA + bound(seed, 0, 500 * LOAN_UNIT));
        caps++;
    }

    function crashPrice(uint256 factor) external {
        factor = bound(factor, 25, 90);
        MockPriceOracle(ORACLE).setPrice(SEED_PRICE * factor / 100);
        crashes++;
    }

    /// @dev A bounded, monotonic price path: compound from the current oracle value instead of the seed price.
    function growPrice(uint256 growthBps) external {
        growthBps = bound(growthBps, 1, 100);
        MockPriceOracle(ORACLE).setPrice(Math.mulDiv(_price(), 10_000 + growthBps, 10_000));
    }

    function liquidate(uint256 actorSeed, uint256 seize) external {
        address victim = _actor(actorSeed);
        Position memory pos = CORE.position(ID, victim);
        if (pos.borrowShares == 0 || pos.collateral == 0) return;
        if (!_paused()) CORE.accrueInterest(params);
        MorphoMarket memory mk = CORE.market(ID);
        uint256 debt = Math.mulDiv(pos.borrowShares, mk.totalBorrowAssets, mk.totalBorrowShares);
        uint256 collValue = Math.mulDiv(pos.collateral, _price(), 1e36);
        if (debt <= collValue * LLTV / 1e18) return;

        uint256 amount;
        if (debt > collValue) {
            amount = pos.collateral;
        } else {
            uint256 maxSeize = Math.mulDiv(debt, 1e36, _price());
            if (maxSeize == 0) return;
            amount = bound(seize, 1, maxSeize);
        }
        address keeper = actors[(actorSeed % actors.length + 1) % actors.length];
        _mintTo(LOAN, keeper, type(uint128).max);
        vm.startPrank(keeper);
        LOAN.approve(address(CORE), type(uint256).max);
        if (_paused()) {
            vm.expectRevert(PausableUntil.ResumedExpected.selector);
            CORE.liquidate(params, victim, amount, 0, "");
            vm.stopPrank();
            return;
        }
        CORE.liquidate(params, victim, amount, 0, "");
        vm.stopPrank();
        liquidations++;
    }

    function _recordSettlementPanicOrRevert(uint256 code) private {
        if (code == ARITHMETIC_PANIC_CODE) {
            settlementArithmeticPanicked = true;
            return;
        }

        bytes memory reason = abi.encodeWithSelector(PANIC_SELECTOR, code);
        assembly ("memory-safe") {
            revert(add(reason, 0x20), mload(reason))
        }
    }

    /// @dev The core emits this exact reason only after independently deriving a zero collateral seizure. Keep the
    ///      expected dust path visible while rethrowing every other string error and all panics.
    function _recordExpectedSettlementErrorOrRevert(string memory reason) private {
        if (keccak256(bytes(reason)) == SETTLEMENT_SLICE_TOO_SMALL_HASH) {
            settlementDustReverts++;
            return;
        }
        revert(reason);
    }

    /// @dev A positive vault-share request can have no floor-valued core-share claim at dust scale, or its targeted
    ///      batch can consume no settlement budget. These are expected no-settlement boundaries; every other custom
    ///      error is rethrown.
    function _recordExpectedSettlementCustomErrorOrRevert(bytes memory reason) private {
        bytes4 selector;
        if (reason.length >= 4) {
            assembly ("memory-safe") {
                selector := mload(add(reason, 0x20))
            }
        }
        if (selector == ILidoLendERC4626.ZeroMorphoSupplyShares.selector) return;
        if (selector == ILidoLendERC4626.NothingSettled.selector) {
            ++nothingSettledReverts;
            return;
        }

        assembly ("memory-safe") {
            revert(add(reason, 0x20), mload(reason))
        }
    }
}
