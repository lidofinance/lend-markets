// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {Id, IMorpho, MarketParams} from "@lido-lend/src/interfaces/IMorpho.sol";
import {MarketParamsLib} from "@lido-lend/src/libraries/MarketParamsLib.sol";
import {MorphoBalancesLib} from "@lido-lend/src/libraries/periphery/MorphoBalancesLib.sol";
import {SharesMathLib} from "@lido-lend/src/libraries/SharesMathLib.sol";

import {ILidoLend} from "@lido-lend/src/interfaces/ILidoLend.sol";
import {ILidoLendMarketController} from "./interfaces/ILidoLendMarketController.sol";
import {ILidoLendERC4626} from "./interfaces/ILidoLendERC4626.sol";

/// @title LidoLendERC4626
/// @notice Single-market ERC-4626 wrapper for a Morpho Blue fork market with settle exit support.
/// @dev    Assumes `asset()` and the market's collateral token are standard ERC-20s without transfer
///         callbacks (no ERC-777 `tokensToSend`, no ERC-1363 `transferAndCall`).
contract LidoLendERC4626 layout at erc7201("lido.lend.storage.LidoLendERC4626")
    is
    ERC4626Upgradeable,
    ILidoLendERC4626
{
    using MarketParamsLib for MarketParams;
    using SafeERC20 for IERC20;
    using SharesMathLib for uint256;

    // ---
    // CONSTANTS
    // ---

    /// @inheritdoc ILidoLendERC4626
    uint256 public constant DEFAULT_MAX_SETTLEMENT_ITERATIONS = 150;

    /// @dev Decimals the vault's shares normalize to, like every Morpho vault — independent of the loan
    ///      token's own decimals. The virtual-share offset is `SHARE_DECIMALS - loanTokenDecimals` (floored at 0).
    uint8 private constant SHARE_DECIMALS = 18;

    // ---
    // IMMUTABLES
    // ---

    /// @inheritdoc ILidoLendERC4626
    ILidoLend public immutable LIDO_LEND;

    // ---
    // STORAGE
    // ---

    /// @inheritdoc ILidoLendERC4626
    Id public marketId;

    /// @inheritdoc ILidoLendERC4626
    ILidoLendMarketController public controller;

    /// @dev Cached market params (loan/collateral/oracle/irm/lltv) for the core supply, withdraw and settle calls.
    MarketParams internal _marketParams;

    /// @dev Virtual-share decimals offset, `SHARE_DECIMALS - loanTokenDecimals`, frozen at init (see
    ///     `_decimalsOffset`).
    uint8 internal _loanDecimalsOffset;

    /// @dev Core supply shares from vault operations only — backs shares in place of the full core position,
    ///      which `supply(onBehalf)` lets anyone inflate.
    uint256 internal _managedSupplyShares;

    // ---
    // INITIALIZATION
    // ---

    /// @custom:oz-upgrades-unsafe-allow constructor state-variable-immutable
    constructor(address lidoLend) {
        if (lidoLend == address(0)) revert ZeroLidoLend();

        LIDO_LEND = ILidoLend(lidoLend);

        _disableInitializers();
    }

    /// @inheritdoc ILidoLendERC4626
    function initialize(
        MarketParams memory marketParams_,
        address controller_,
        string memory name_,
        string memory symbol_
    ) external initializer {
        if (controller_ == address(0)) revert ZeroController();

        if (marketParams_.loanToken == address(0)) revert ZeroLoanToken();

        if (marketParams_.collateralToken == address(0)) revert ZeroCollateralToken();

        __ERC20_init(name_, symbol_);
        __ERC4626_init(IERC20(marketParams_.loanToken));

        _loanDecimalsOffset =
            uint8(Math.saturatingSub(SHARE_DECIMALS, IERC20Metadata(marketParams_.loanToken).decimals()));

        controller = ILidoLendMarketController(controller_);
        marketId = marketParams_.id();
        if (Id.unwrap(controller.marketId()) != Id.unwrap(marketId)) revert ControllerMarketMismatch();
        _marketParams = marketParams_;

        IERC20(marketParams_.loanToken).forceApprove(address(LIDO_LEND), type(uint256).max);
    }

    // ---
    // GETTERS
    // ---

    /// @inheritdoc ILidoLendERC4626
    function marketParams() external view returns (MarketParams memory) {
        return _marketParams;
    }

    /// @inheritdoc ILidoLendERC4626
    function managedSupplyShares() external view returns (uint256) {
        return _managedSupplyShares;
    }

    // ---
    // OVERRIDES
    // ---

    /// @dev Only vault-originated supply shares back shares — direct loan-token donations and permissionless
    ///      core `supply` credits to the vault address are uncounted and cannot move the share price.
    function totalAssets() public view override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        uint256 supplyShares = _managedSupplyShares;
        if (supplyShares == 0) return 0;
        (uint256 totalSupplyAssets, uint256 totalSupplyShares) = _marketSupplyTotals();
        return supplyShares.toAssetsDown(totalSupplyAssets, totalSupplyShares);
    }

    /// @dev Capped by the market's free liquidity, not just the owner's position: supplied tokens may be borrowed
    ///      out, so withdrawing past liquidity reverts in the core. The illiquid remainder exits via `fallbackExit`.
    ///      Zero while the controller is paused, since a real withdraw would revert then too.
    function maxWithdraw(address owner) public view override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        return Math.min(previewRedeem(balanceOf(owner)), _morphoWithdrawableAssets());
    }

    /// @dev Liquidity cap of `maxWithdraw`, in shares. When the owner's whole position fits in free liquidity
    ///      it returns the exact share balance, avoiding a `convertToShares` round-trip that could round the
    ///      last wei down and strand a share. Otherwise it caps to the shares liquidity covers.
    function maxRedeem(address owner) public view override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        uint256 ownerShares = balanceOf(owner);
        uint256 liquidAssets = _morphoWithdrawableAssets();

        return previewRedeem(ownerShares) <= liquidAssets ? ownerShares : convertToShares(liquidAssets);
    }

    /// @dev Deferred to the controller, which decides how much the market accepts.
    function maxDeposit(address) public view override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        return controller.maxDeposit();
    }

    /// @dev `maxDeposit` in shares, floored; the unlimited sentinel passes through unconverted.
    function maxMint(address receiver) public view override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        uint256 maxAssets = maxDeposit(receiver);
        return maxAssets == type(uint256).max ? maxAssets : _convertToShares(maxAssets, Math.Rounding.Floor);
    }

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        if (assets != 0 && shares == 0) revert ZeroSharesMinted(assets);
        super._deposit(caller, receiver, assets, shares);
        if (assets != 0) {
            (, uint256 suppliedShares) = LIDO_LEND.supply(_marketParams, assets, 0, address(this), "");
            if (suppliedShares == 0) revert ZeroCoreSupplySharesMinted(assets);
            _managedSupplyShares += suppliedShares;
        }
    }

    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        override
    {
        if (assets != 0) {
            (, uint256 withdrawnShares) = LIDO_LEND.withdraw(_marketParams, assets, 0, address(this), address(this));
            _managedSupplyShares -= withdrawnShares;
        }
        super._withdraw(caller, receiver, owner, assets, shares);
    }

    /// @dev The frozen virtual-share offset (`SHARE_DECIMALS - loanTokenDecimals`). Defense-in-depth on top of the
    ///      managed-share `totalAssets`, which is the actual donation/inflation defense.
    function _decimalsOffset() internal view override returns (uint8) {
        return _loanDecimalsOffset;
    }

    // ---
    // SETTLEMENT
    // ---

    /// @inheritdoc ILidoLendERC4626
    /// @dev A targeted, liquidity-neutral cut of the named borrowers: it redeems no liquidity first (unlike
    ///      `fallbackExit`), so it stays subject to the core's settleable-supply gate (reverts
    ///      `SETTLEMENT_EXCEEDS_SETTLEABLE_SUPPLY` while idle liquidity still covers the amount). Collateral
    ///      goes from Morpho straight to `receiver`. For the griefing-resistant exit use `fallbackExit`.
    function settle(uint256 shares, address[] calldata borrowers, address receiver, address owner)
        external
        returns (uint256 sharesBurned, uint256 loanAssets, uint256 collateralSeized, uint256 debtCanceled)
    {
        if (borrowers.length == 0) revert EmptyBorrowers();
        if (shares == 0) revert ZeroShares();
        if (receiver == address(0)) revert ZeroAddress();
        if (shares > balanceOf(owner)) revert ExceededBalance(owner, shares, balanceOf(owner));

        // The owner's pro-rata supply shares — the budget the cuts consume.
        uint256 settlingSupplyShares = Math.mulDiv(_managedSupplyShares, shares, totalSupply());
        if (settlingSupplyShares == 0) revert ZeroMorphoSupplyShares();

        uint256 remainingSupplyShares = settlingSupplyShares;
        for (uint256 i = 0; i < borrowers.length && remainingSupplyShares != 0; ++i) {
            address borrower = borrowers[i];
            (uint256 cutShares, uint256 cutCollateral, uint256 cutDebt) =
                _settleBorrower(remainingSupplyShares, borrower, receiver);

            debtCanceled += cutDebt;
            collateralSeized += cutCollateral;
            remainingSupplyShares = Math.saturatingSub(remainingSupplyShares, cutShares);
        }
        if (remainingSupplyShares < settlingSupplyShares) {
            _managedSupplyShares -= settlingSupplyShares - remainingSupplyShares;
        }

        // Burn only the shares actually settled (pro-rata if the cuts fell short). loanAssets stays 0 — settle
        // pays the receiver collateral, not loan assets.
        sharesBurned = remainingSupplyShares == 0
            ? shares
            : Math.mulDiv(
                shares, settlingSupplyShares - remainingSupplyShares, settlingSupplyShares, Math.Rounding.Ceil
            );

        address caller = _msgSender();
        if (sharesBurned != 0) {
            if (caller != owner) _spendAllowance(owner, caller, sharesBurned);
            _burn(owner, sharesBurned);
        }

        emit Settled(caller, owner, receiver, sharesBurned, collateralSeized, debtCanceled);
    }

    /// @dev Resolve the policy cut for `borrower` and settle it within `budget` via `_settle`.
    function _settleBorrower(uint256 budgetSupplyShares, address borrower, address receiver)
        internal
        returns (uint256 cutShares, uint256 collateralSeized, uint256 debtCanceled)
    {
        (uint256 supplyShares, uint256 borrowShares, uint256 remainingBorrowShares) = controller.settlementFor(borrower);
        return _settle(budgetSupplyShares, borrower, supplyShares, borrowShares, remainingBorrowShares, receiver);
    }

    /// @inheritdoc ILidoLendERC4626
    /// @dev Redeems what liquidity covers before settling, closing a griefing vector: the core blocks `settle`
    ///      while idle liquidity still covers the amount, so without the redeem an attacker could add idle right
    ///      before the call to force the exit to revert. That liquidity goes to the owner as loan assets;
    ///      collateral goes from Morpho straight to `receiver`.
    function fallbackExit(uint256 shares, address receiver, address owner, uint256 maxIterations)
        external
        returns (uint256 sharesBurned, uint256 loanAssets, uint256 collateralSeized, uint256 debtCanceled)
    {
        if (shares == 0) revert ZeroShares();
        if (receiver == address(0)) revert ZeroAddress();
        if (shares > balanceOf(owner)) revert ExceededBalance(owner, shares, balanceOf(owner));

        // 1. Drain the free liquidity, then settle the illiquid remainder. When illiquid, drain by EXACT assets
        //    (via `withdraw`), not floor-rounded shares: a floor-share redeem strands a wei of liquidity that makes
        //    the core settle gate reject the remainder and revert the whole exit.
        {
            uint256 liquid = _morphoWithdrawableAssets();
            if (previewRedeem(shares) <= liquid) {
                sharesBurned = shares;
                loanAssets = redeem(shares, receiver, owner);
            } else if (liquid != 0) {
                loanAssets = liquid;
                sharesBurned = withdraw(liquid, receiver, owner);
            }
        }
        uint256 remaining = shares - sharesBurned;
        if (remaining == 0) return (sharesBurned, loanAssets, 0, 0);

        // 2. Settle the remainder against the risk queue, head first (collateral to receiver), up to the owner's
        //    pro-rata supply-share budget for it.
        uint256 settlingSupplyShares = Math.mulDiv(_managedSupplyShares, remaining, totalSupply());
        if (settlingSupplyShares == 0) revert ZeroMorphoSupplyShares();

        if (maxIterations == 0) maxIterations = DEFAULT_MAX_SETTLEMENT_ITERATIONS;
        uint256 remainingSupplyShares = settlingSupplyShares;

        for (uint256 i = 0; i < maxIterations && remainingSupplyShares != 0; ++i) {
            (uint256 cutShares, uint256 cutCollateral, uint256 cutDebt) =
                _settleNextAllowedBorrower(remainingSupplyShares, receiver);
            if (cutShares == 0) break;

            debtCanceled += cutDebt;
            collateralSeized += cutCollateral;
            remainingSupplyShares = Math.saturatingSub(remainingSupplyShares, cutShares);
        }
        if (remainingSupplyShares < settlingSupplyShares) {
            _managedSupplyShares -= settlingSupplyShares - remainingSupplyShares;
        }

        // Burn the settled remainder (pro-rata, rounded up so remaining holders aren't diluted) and spend
        // allowance for it; the redeem leg burned its own.
        uint256 settledShares = remainingSupplyShares == 0
            ? remaining
            : Math.mulDiv(
                remaining, settlingSupplyShares - remainingSupplyShares, settlingSupplyShares, Math.Rounding.Ceil
            );
        address caller = _msgSender();

        if (settledShares != 0) {
            if (caller != owner) _spendAllowance(owner, caller, settledShares);
            _burn(owner, settledShares);
        }
        sharesBurned += settledShares;

        emit FallbackExit(caller, owner, receiver, settledShares, collateralSeized, debtCanceled);
    }

    /// @dev Same as `_settleBorrower`, but on the queue root resolved together with its cut.
    function _settleNextAllowedBorrower(uint256 budgetSupplyShares, address receiver)
        internal
        returns (uint256 cutShares, uint256 collateralSeized, uint256 debtCanceled)
    {
        (address borrower, uint256 supplyShares, uint256 borrowShares, uint256 remainingBorrowShares) =
            controller.nextSettlementBorrower();
        return _settle(budgetSupplyShares, borrower, supplyShares, borrowShares, remainingBorrowShares, receiver);
    }

    /// @dev Settle `borrower`'s cut capped at `budgetSupplyShares`: borrow-anchor an affordable full close, else
    ///      supply-anchor. `cutSupplyShares` is the supply burn the core reports back; a borrow-anchored close
    ///      derives it, matching the controller's `supplyShares` estimate, so the cut stays within budget.
    function _settle(
        uint256 budgetSupplyShares,
        address borrower,
        uint256 supplyShares,
        uint256 borrowShares,
        uint256 remainingBorrowShares,
        address receiver
    ) internal returns (uint256 cutSupplyShares, uint256 collateralSeized, uint256 debtCanceled) {
        cutSupplyShares = Math.min(supplyShares, budgetSupplyShares);
        if (cutSupplyShares == 0) return (0, 0, 0);

        // Affordable full close: borrow-anchor (supply 0, the core derives the burn). Partial or
        // unaffordable full close: supply-anchor at the capped burn.
        (supplyShares, borrowShares) = remainingBorrowShares == 0 && supplyShares <= budgetSupplyShares
            ? (uint256(0), borrowShares)
            : (cutSupplyShares, 0);

        (collateralSeized, debtCanceled,/* borrowSharesCanceled */, cutSupplyShares) =
            LIDO_LEND.settle(_marketParams, supplyShares, borrowShares, address(this), borrower, receiver);
    }

    function _marketSupplyTotals() internal view returns (uint256 totalSupplyAssets, uint256 totalSupplyShares) {
        (totalSupplyAssets, totalSupplyShares,,) =
            MorphoBalancesLib.expectedMarketBalances(IMorpho(address(LIDO_LEND)), _marketParams);
    }

    function _morphoWithdrawableAssets() internal view returns (uint256) {
        return controller.maxWithdrawableAssets(address(this));
    }
}
