// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {IMorpho, Id, MarketParams} from "@lido-lend/src/interfaces/IMorpho.sol";
import {WAD} from "@lido-lend/src/libraries/MathLib.sol";
import {MarketParamsLib} from "@lido-lend/src/libraries/MarketParamsLib.sol";
import {MorphoBalancesLib} from "@lido-lend/src/libraries/periphery/MorphoBalancesLib.sol";
import {SharesMathLib} from "@lido-lend/src/libraries/SharesMathLib.sol";

import {WithdrawalQueueLib} from "../libs/WithdrawalQueueLib.sol";
import {WithdrawalMathLib} from "../libs/WithdrawalMathLib.sol";

/// @title WithdrawalQueue
/// @author Lido Lending contributors.
/// @notice Lender stablecoin-exit queue for a single LidoLend market. A lender posts a request to
///         exit a fixed size of their supply position; anyone (a "keeper") then drains whatever
///         liquidity the market currently has into the request, earning the lender's priority fee.
///         The lender claims the freed stablecoin; the keeper claims the fee. Large exits no longer
///         need the lender to chase liquidity transaction by transaction.
/// @dev Two entry modes feed one registry:
///      - Direct: the lender authorizes this contract on the core (`setAuthorization`) and the fill
///        withdraws straight from their core position. The position stays with the lender, who may
///        undo the authorization or withdraw themselves — then the request simply stops filling.
///      - Vault: the lender escrows ERC-4626 vault shares here at request time (core supply shares
///        are not transferable, so escrow is only possible through the tokenized layer); the fill
///        redeems them.
///      The priority fee is a Dutch auction: the lender sets a cap and the fee a fill earns ramps
///      linearly from 0 at request time to the cap at the deadline, so a liquidity-starved request
///      grows more attractive to fill the longer it waits, while one filled early costs the lender
///      almost nothing.
///      The request registry lives in `WithdrawalQueueLib`; this contract owns the token movement,
///      pricing, and the per-fill settlement split. Bolt-on: no core changes. Pause and freeze
///      interactions are out of scope for this revision.
contract WithdrawalQueue is Ownable {
    using SafeERC20 for IERC20;
    using MarketParamsLib for MarketParams;
    using SharesMathLib for uint256;
    using WithdrawalQueueLib for WithdrawalQueueLib.State;

    /* ERRORS */

    error ZeroSize();
    error ZeroAddress();
    error AssetMismatch();
    error FeeTooHigh();
    error FeeRecipientRequired();
    error DeadlineInPast();
    error NothingAvailable();
    error NotAuthorizedOnCore();

    /* EVENTS */

    event WithdrawalRequested(
        uint256 indexed id,
        address indexed owner,
        WithdrawalQueueLib.Mode mode,
        uint256 size,
        uint256 maxPriorityFee,
        uint256 deadline,
        bool fullFillOnly
    );
    event WithdrawalProcessed(
        uint256 indexed id,
        address indexed keeper,
        uint256 filledShares,
        uint256 lenderAssets,
        uint256 keeperFee,
        uint256 protocolFee
    );
    event WithdrawalCancelled(uint256 indexed id);
    event WithdrawalExpired(uint256 indexed id);
    event Claimed(address indexed account, uint256 assets);
    event ProtocolFeeSet(address indexed feeRecipient, uint256 protocolFeeBps);

    /* CONSTANTS */

    /// @notice Hard cap on the protocol cut of the keeper's priority fee (1%).
    uint256 public constant MAX_PROTOCOL_FEE_BPS = 100;

    /// @dev Basis-point denominator, also the priority-fee ramp's value at the deadline.
    uint256 internal constant BPS = 10_000;

    /* IMMUTABLES */

    IMorpho public immutable CORE;
    IERC4626 public immutable VAULT;
    IERC20 public immutable ASSET;
    Id public immutable MARKET_ID;

    /* STORAGE */

    MarketParams internal _params;

    /// @notice Account credited the protocol cut; claims it through the shared `claim` path. The cut
    ///         is taken only from the keeper's reward, never from the lender's proceeds.
    address public feeRecipient;
    /// @notice Protocol cut of the keeper's priority fee, in basis points (≤ `MAX_PROTOCOL_FEE_BPS`).
    uint256 public protocolFeeBps;

    WithdrawalQueueLib.State internal _queue;
    /// @notice Loan-asset balance withdrawable by each account (lender proceeds or keeper fees).
    mapping(address account => uint256) public claimable;

    /* CONSTRUCTOR */

    /// @param vault ERC-4626 vault wrapping this market; its `asset()` must equal `params.loanToken`.
    /// @param core The LidoLend core the Direct mode withdraws from.
    /// @param params Market the queue serves (its id and loan asset are derived here).
    /// @param owner Owner that may set the protocol fee.
    /// @param recipient Initial protocol-fee recipient.
    /// @param bps Initial protocol fee, capped at `MAX_PROTOCOL_FEE_BPS`.
    constructor(address vault, address core, MarketParams memory params, address owner, address recipient, uint256 bps)
        Ownable(owner)
    {
        if (vault == address(0) || core == address(0)) revert ZeroAddress();
        if (IERC4626(vault).asset() != params.loanToken) revert AssetMismatch();

        VAULT = IERC4626(vault);
        CORE = IMorpho(core);
        ASSET = IERC20(params.loanToken);
        _params = params;
        MARKET_ID = params.id();
        _setProtocolFee(recipient, bps);
    }

    /* CONFIG */

    /// @notice The market parameters this queue serves.
    /// @return params The stored market parameters.
    function marketParams() external view returns (MarketParams memory params) {
        return _params;
    }

    /// @notice Set the protocol fee recipient and rate together. `bps` is capped at
    ///         `MAX_PROTOCOL_FEE_BPS`; a zero recipient requires a zero rate (no fee with nowhere to
    ///         send it).
    /// @param recipient Account credited the protocol cut (zero to disable, which forces `bps` zero).
    /// @param bps Protocol cut of the keeper's reward, in basis points (≤ `MAX_PROTOCOL_FEE_BPS`).
    function setProtocolFee(address recipient, uint256 bps) external onlyOwner {
        _setProtocolFee(recipient, bps);
    }

    function _setProtocolFee(address recipient, uint256 bps) internal {
        if (bps > MAX_PROTOCOL_FEE_BPS) revert FeeTooHigh();
        if (recipient == address(0) && bps != 0) revert FeeRecipientRequired();
        feeRecipient = recipient;
        protocolFeeBps = bps;
        emit ProtocolFeeSet(recipient, bps);
    }

    /* WITHDRAWAL FLOW */

    /// @notice Open an exit request. Direct mode: caller must have authorized this contract on the
    ///         core first; `assets` worth of their supply position is queued. Vault mode: caller must
    ///         have approved this contract for the vault shares worth `assets`, which are escrowed.
    /// @param mode Direct (core authorization) or Vault (escrowed shares).
    /// @param assets Loan-asset amount the lender wants to free; the request fixes the share price now
    ///        and queues the matching shares.
    /// @param maxPriorityFee Priority-fee cap, in loan-asset units. The fee a fill earns ramps from 0
    ///        at this call to the cap at `deadline` (a Dutch auction), charged out of the lender's owed.
    /// @param deadline Last timestamp the request may be filled, and the ramp's full-fee point.
    /// @param fullFillOnly When true the request may only be filled in a single shot covering its whole
    ///        size; a fill is rejected while the market cannot cover it all, never leaving it partial.
    /// @return id The new request id.
    function requestWithdrawal(
        WithdrawalQueueLib.Mode mode,
        uint256 assets,
        uint256 maxPriorityFee,
        uint256 deadline,
        bool fullFillOnly
    ) external returns (uint256 id) {
        if (assets == 0) revert ZeroSize();
        if (deadline <= block.timestamp) revert DeadlineInPast();

        uint256 shares;
        uint256 pricePerShare;
        if (mode == WithdrawalQueueLib.Mode.Vault) {
            shares = VAULT.convertToShares(assets);
            pricePerShare = VAULT.convertToAssets(WAD);
            IERC20(address(VAULT)).safeTransferFrom(msg.sender, address(this), shares);
        } else {
            if (!CORE.isAuthorized(msg.sender, address(this))) revert NotAuthorizedOnCore();
            pricePerShare = _coreSharesToAssets(WAD);
            shares = Math.mulDiv(assets, WAD, pricePerShare);
        }

        id = _queue.add(msg.sender, mode, shares, pricePerShare, maxPriorityFee, deadline, fullFillOnly);
        emit WithdrawalRequested(id, msg.sender, mode, assets, maxPriorityFee, deadline, fullFillOnly);
    }

    /// @notice Drain whatever liquidity the market currently has into request `id`, splitting the
    ///         proceeds between the lender, the caller (keeper), and the protocol. Callable by
    ///         anyone, repeatedly, until the request is fully filled.
    /// @param id The request to fill.
    function processWithdrawal(uint256 id) external {
        WithdrawalQueueLib.Request storage request = _queue.requireOpen(id);

        (uint256 filledShares, uint256 assetsOut) = _pull(request);
        if (filledShares == 0 || assetsOut == 0) revert NothingAvailable();

        // Dutch ramp: 0 at creation, full cap at the deadline (the request can't be filled past it).
        uint256 feeRampBps = (block.timestamp - request.createdAt) * BPS / (request.deadline - request.createdAt);
        (uint256 lenderAssets, uint256 keeperFee, uint256 protocolFee) = WithdrawalMathLib.splitFill(
            assetsOut,
            filledShares,
            request.sizeTotal,
            request.pricePerShare,
            request.maxPriorityFee,
            feeRampBps,
            protocolFeeBps
        );

        _queue.recordFill(id, filledShares);
        claimable[request.owner] += lenderAssets;
        claimable[msg.sender] += keeperFee;
        if (protocolFee != 0) claimable[feeRecipient] += protocolFee;

        emit WithdrawalProcessed(id, msg.sender, filledShares, lenderAssets, keeperFee, protocolFee);
    }

    /// @notice Cancel request `id`. Vault mode returns the unfilled escrowed shares; Direct mode just
    ///         drops the request (the position never left the lender). Caller must be the owner.
    /// @param id The request to cancel.
    function cancelWithdrawal(uint256 id) external {
        address owner = _queue.requests[id].owner;
        (WithdrawalQueueLib.Mode mode, uint256 leftover) = _queue.cancel(id, msg.sender);
        if (mode == WithdrawalQueueLib.Mode.Vault && leftover != 0) {
            IERC20(address(VAULT)).safeTransfer(owner, leftover);
        }
        emit WithdrawalCancelled(id);
    }

    /// @notice Permissionlessly drop expired requests from the active set, refunding the escrowed
    ///         shares of Vault-mode requests to their owners. Ids that are not open-and-expired are
    ///         skipped, so a stale batch never reverts.
    /// @param ids Candidate request ids to prune.
    function pruneExpired(uint256[] calldata ids) external {
        for (uint256 index; index < ids.length; ++index) {
            uint256 id = ids[index];
            (bool pruned, WithdrawalQueueLib.Mode mode, address owner, uint256 leftover) = _queue.expireIfDue(id);
            if (!pruned) continue;
            if (mode == WithdrawalQueueLib.Mode.Vault && leftover != 0) {
                IERC20(address(VAULT)).safeTransfer(owner, leftover);
            }
            emit WithdrawalExpired(id);
        }
    }

    /// @notice Withdraw the caller's accumulated loan-asset balance (lender proceeds or keeper fees).
    /// @return assets The amount transferred to the caller.
    function claim() external returns (uint256 assets) {
        assets = claimable[msg.sender];
        if (assets == 0) return 0;
        claimable[msg.sender] = 0;
        ASSET.safeTransfer(msg.sender, assets);
        emit Claimed(msg.sender, assets);
    }

    /* VIEWS */

    /// @notice The full record for request `id` (zero-valued struct if it never existed).
    /// @param id The request id to read.
    /// @return request The stored request record.
    function getRequest(uint256 id) external view returns (WithdrawalQueueLib.Request memory request) {
        return _queue.requests[id];
    }

    /// @notice Open request ids, paginated.
    /// @param offset Start index into the active set.
    /// @param limit Maximum number of ids to return.
    /// @return ids The open ids in the `[offset, offset + limit)` window.
    function activeRequests(uint256 offset, uint256 limit) external view returns (uint256[] memory ids) {
        return _queue.paginate(offset, limit);
    }

    /// @notice Number of open requests in the active set.
    /// @return count The active request count.
    function activeRequestCount() external view returns (uint256 count) {
        return _queue.count();
    }

    /* INTERNAL */

    /// @dev Redeem/withdraw as many of the request's shares as the market can honour now, capped at
    ///      `sizeRemaining` and at the request's own source (escrowed shares for Vault — bounded by
    ///      `sizeRemaining`; the lender's live position for Direct). Returns the shares filled and the
    ///      assets they produced; the fixed-price owed vs accrued yield split happens in the caller.
    ///      A `fullFillOnly` request yields nothing until the available amount covers its whole size,
    ///      so the caller reverts (`NothingAvailable`) rather than fill it partially.
    function _pull(WithdrawalQueueLib.Request storage request)
        internal
        returns (uint256 filledShares, uint256 assetsOut)
    {
        if (request.mode == WithdrawalQueueLib.Mode.Vault) {
            filledShares = Math.min(request.sizeRemaining, VAULT.maxRedeem(address(this)));
            if (filledShares == 0 || (request.fullFillOnly && filledShares < request.sizeRemaining)) return (0, 0);
            assetsOut = VAULT.redeem(filledShares, address(this), address(this));
        } else {
            uint256 availableShares = _coreAssetsToShares(_idleAssets());
            uint256 ownerShares = CORE.position(MARKET_ID, request.owner).supplyShares;
            filledShares = Math.min(Math.min(request.sizeRemaining, availableShares), ownerShares);
            if (filledShares == 0 || (request.fullFillOnly && filledShares < request.sizeRemaining)) return (0, 0);
            (assetsOut,) = CORE.withdraw(_params, 0, filledShares, request.owner, address(this));
        }
    }

    /* CORE LIQUIDITY / PRICE VIEWS */

    function _idleAssets() internal view returns (uint256) {
        (uint256 totalSupplyAssets,, uint256 totalBorrowAssets,) =
            MorphoBalancesLib.expectedMarketBalances(CORE, _params);
        return totalSupplyAssets > totalBorrowAssets ? totalSupplyAssets - totalBorrowAssets : 0;
    }

    function _coreSharesToAssets(uint256 shares) internal view returns (uint256) {
        (uint256 totalSupplyAssets, uint256 totalSupplyShares,,) =
            MorphoBalancesLib.expectedMarketBalances(CORE, _params);
        return shares.toAssetsDown(totalSupplyAssets, totalSupplyShares);
    }

    function _coreAssetsToShares(uint256 assets) internal view returns (uint256) {
        (uint256 totalSupplyAssets, uint256 totalSupplyShares,,) =
            MorphoBalancesLib.expectedMarketBalances(CORE, _params);
        return assets.toSharesDown(totalSupplyAssets, totalSupplyShares);
    }
}
