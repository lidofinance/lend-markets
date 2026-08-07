// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControlEnumerable} from "@openzeppelin/contracts/access/extensions/AccessControlEnumerable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IExitBook} from "../interfaces/IExitBook.sol";
import {AssetRecoverer} from "../utils/AssetRecoverer.sol";
import {ExitStatus, Request, PriorityRamp, RequestPreview, Sizing} from "../types/ExitBookTypes.sol";
import {ExitBookLib} from "../libs/ExitBookLib.sol";
import {WAD} from "../libs/Constants.sol";

/// @title ExitBookBase
/// @author Lido
/// @notice Shared base of the exit books. A lender posts a request to exit a position; a filler later
///         closes it against available liquidity for a fee. A concrete book binds it to a source by
///         implementing the source operations, so any position that supports them can reuse this primitive.
abstract contract ExitBookBase is IExitBook, AccessControlEnumerable, AssetRecoverer {
    using SafeERC20 for IERC20;
    using ExitBookLib for ExitBookLib.State;

    // ---
    // ERRORS
    // ---

    error ZeroAddress();
    error ZeroShares();
    error ZeroMaxLifetime();
    error FeeTooHigh();
    error FeeRecipientRequired();
    error PriorityFeeTooHigh();
    error StartFeeAboveEnd();
    error RampStartAfterEnd();
    error RampPastDeadline();
    error ShareRateBelowMinimum();
    error NoFillableShares();
    error NoAssetsRedeemed();
    error AssetsOutBelowMin();
    error DeadlineInPast();
    error DeadlineTooFar();

    // ---
    // EVENTS
    // ---

    event ExitRequested(
        uint256 indexed id,
        address indexed owner,
        address indexed receiver,
        address asset,
        uint256 shares,
        uint256 minShareRate,
        PriorityRamp ramp,
        uint256 deadline,
        bool fullFillOnly
    );

    event ExitProcessed(
        uint256 indexed id,
        address indexed filler,
        address asset,
        uint256 filledShares,
        uint256 lenderAssets,
        uint256 fillerFee,
        uint256 serviceCut
    );

    event ExitCancelled(uint256 indexed id);

    event ServiceFeeSet(address indexed feeRecipient, uint256 serviceFee);

    // ---
    // CONSTANTS
    // ---

    /// @notice Role allowed to manage the source allow-list (which markets or vaults may be exited).
    bytes32 public constant ALLOWLIST_MANAGER_ROLE = keccak256("ALLOWLIST_MANAGER_ROLE");
    /// @notice Role allowed to set the service fee and its recipient.
    bytes32 public constant FEE_MANAGER_ROLE = keccak256("FEE_MANAGER_ROLE");
    /// @notice Role allowed to recover tokens held by the contract.
    bytes32 public constant RECOVERER_ROLE = keccak256("RECOVERER_ROLE");

    /// @notice Cap on a request's priority-fee rate (WAD), checked at `place` — 10%.
    uint256 public constant MAX_PRIORITY_FEE = 0.1e18;

    /// @notice Hard cap on the service fee — a cut of the filler's gross reward (WAD) — 25%.
    uint256 public constant MAX_SERVICE_FEE = 0.25e18;

    /// @notice Share amount a source share rate is quoted per.
    uint256 public constant SHARE_RATE_UNIT = 1e36;

    // ---
    // IMMUTABLES
    // ---

    /// @notice Cap on a request's lifetime: its `deadline` may be at most `createdAt + MAX_REQUEST_LIFETIME`.
    uint256 public immutable MAX_REQUEST_LIFETIME;

    // ---
    // STORAGE
    // ---

    /// @notice Recipient of the service fee.
    address public feeRecipient;

    /// @notice Service fee: a cut of the filler's gross reward (accrued yield + fee), as a WAD rate.
    uint256 public serviceFee;

    /// @notice The append-only request registry (see `ExitBookLib`).
    ExitBookLib.State internal _book;

    // ---
    // CONSTRUCTOR
    // ---

    /// @param admin        Holder of `DEFAULT_ADMIN_ROLE`.
    /// @param maxLifetime_ Cap on a request's lifetime; must be non-zero.
    constructor(address admin, uint256 maxLifetime_) {
        if (admin == address(0)) revert ZeroAddress();
        if (maxLifetime_ == 0) revert ZeroMaxLifetime();

        MAX_REQUEST_LIFETIME = maxLifetime_;

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    // ---
    // PERMISSIONS
    // ---

    /// @dev Asset recovery is `RECOVERER_ROLE`-only.
    function _checkRecoverer() internal view override {
        _checkRole(RECOVERER_ROLE);
    }

    // ---
    // CONFIG
    // ---

    /// @inheritdoc IExitBook
    function setServiceFee(address recipient, uint256 fee) external onlyRole(FEE_MANAGER_ROLE) {
        if (fee > MAX_SERVICE_FEE) revert FeeTooHigh();

        if (recipient == address(0) && fee != 0) revert FeeRecipientRequired();

        feeRecipient = recipient;
        serviceFee = fee;

        emit ServiceFeeSet(recipient, fee);
    }

    // ---
    // FILL
    // ---

    /// @inheritdoc IExitBook
    /// @dev Checks-effects-interactions: debit shares before the redeem, so a same-request re-entry sees
    ///      the reduced size and cannot double-fill. The book holds nothing between fills.
    function fillExitRequest(uint256 id, uint256 depositAssets, uint256 minAssetsOut) external {
        Request storage request = _book.requireFillable(id);
        IERC20 asset = _asset(id);

        if (depositAssets != 0) {
            asset.safeTransferFrom(msg.sender, address(this), depositAssets);
            _depositLiquidity(id, asset, depositAssets, msg.sender);
        }

        (uint256 filledShares, uint256 shareRate) = _fillableShares(id, request);
        // Order matters: a request with nothing to fill reports that, not the rate floor's error.
        if (filledShares == 0) revert NoFillableShares();
        if (shareRate < request.minShareRate) revert ShareRateBelowMinimum();

        uint256 quotedOwed = _quotedOwed(request, filledShares);
        _book.recordFill(id, filledShares);

        uint256 assetsOut = _redeemMeasured(id, request.owner, asset, filledShares, minAssetsOut);
        (uint256 lenderAssets, uint256 fillerFee, uint256 serviceCut) =
            _splitProceeds(assetsOut, quotedOwed, _priorityFeeRate(request));

        if (lenderAssets != 0) asset.safeTransfer(request.receiver, lenderAssets);

        if (fillerFee != 0) asset.safeTransfer(msg.sender, fillerFee);

        if (serviceCut != 0) asset.safeTransfer(feeRecipient, serviceCut);

        emit ExitProcessed(id, msg.sender, address(asset), filledShares, lenderAssets, fillerFee, serviceCut);
    }

    /// @dev Redeem `shares` of `owner`'s position and report what actually arrived, measured as a balance delta
    ///      rather than taken from the source's return value, then hold it to the filler's `minAssetsOut` floor
    ///      (0 to skip). That floor is late by necessity — the figure exists only post-redeem — so a griefed fill
    ///      still burns the redeem gas, but the filler's deposited capital is never committed below it.
    function _redeemMeasured(uint256 id, address owner, IERC20 asset, uint256 shares, uint256 minAssetsOut)
        private
        returns (uint256 assetsOut)
    {
        uint256 balanceBefore = asset.balanceOf(address(this));
        _redeem(id, owner, shares);
        assetsOut = asset.balanceOf(address(this)) - balanceBefore;
        if (assetsOut == 0) revert NoAssetsRedeemed();
        if (assetsOut < minAssetsOut) revert AssetsOutBelowMin();
    }

    /// @dev Split what the redeem produced three ways with no remainder: the lender gets their fixed-price
    ///      `quotedOwed` minus the priority fee, the filler gets the accrued yield plus that fee, and the
    ///      service takes a cut of the filler's gross. The owed amount is capped at `assetsOut`, so a loss just
    ///      trims it; `feeRate <= MAX_PRIORITY_FEE < WAD`, so the fee never exceeds it.
    function _splitProceeds(uint256 assetsOut, uint256 quotedOwed, uint256 feeRate)
        private
        view
        returns (uint256 lenderAssets, uint256 fillerFee, uint256 serviceCut)
    {
        uint256 owed = Math.min(quotedOwed, assetsOut);
        uint256 fee = Math.mulDiv(owed, feeRate, WAD);
        uint256 fillerGross = (assetsOut - owed) + fee; // accrued yield + priority fee
        serviceCut = Math.mulDiv(fillerGross, serviceFee, WAD);
        fillerFee = fillerGross - serviceCut;
        lenderAssets = owed - fee;
    }

    /// @dev Apportion the placement quote cumulatively for this fill. Called before the external redeem so
    ///      re-entrancy cannot move the request's cumulative boundaries.
    function _quotedOwed(Request storage request, uint256 filledShares) internal view returns (uint256) {
        uint256 filledBefore = uint256(request.sizeTotal) - request.sizeRemaining;
        uint256 filledAfter = filledBefore + filledShares;
        uint256 owedAfter = Math.mulDiv(request.quotedAssets, filledAfter, request.sizeTotal);
        uint256 owedBefore = Math.mulDiv(request.quotedAssets, filledBefore, request.sizeTotal);
        return owedAfter - owedBefore;
    }

    // ---
    // LENDER
    // ---

    /// @inheritdoc IExitBook
    function cancelExitRequest(uint256 id) external {
        _book.cancel(id, msg.sender);
        emit ExitCancelled(id);
    }

    // ---
    // READS
    // ---

    /// @inheritdoc IExitBook
    function getExitRequest(uint256 id) external view returns (Request memory) {
        return _book.requests[id];
    }

    /// @inheritdoc IExitBook
    function getRequests(uint256[] calldata ids) external view returns (Request[] memory requests) {
        requests = new Request[](ids.length);

        for (uint256 j; j < ids.length; ++j) {
            requests[j] = _book.requests[ids[j]];
        }
    }

    /// @inheritdoc IExitBook
    function lastRequestId() external view returns (uint256) {
        return _book.nextId;
    }

    /// @inheritdoc IExitBook
    function getOwnerRequestCount(address owner) external view returns (uint256) {
        return _book.ownerRequestIds[owner].length;
    }

    /// @inheritdoc IExitBook
    function getOwnerRequestIds(address owner, uint256 offset, uint256 count)
        external
        view
        returns (uint256[] memory ids)
    {
        uint256[] storage all = _book.ownerRequestIds[owner];
        uint256 len = all.length;

        if (offset >= len) return ids; // an unassigned named return is already an empty array

        uint256 n = Math.min(count, len - offset);

        ids = new uint256[](n);
        for (uint256 j; j < n; ++j) {
            ids[j] = all[offset + j];
        }
    }

    /// @inheritdoc IExitBook
    function previewFill(uint256 id) external view returns (RequestPreview memory) {
        return _requestPreview(id);
    }

    /// @inheritdoc IExitBook
    function getRequestPreviews(uint256[] calldata ids) external view returns (RequestPreview[] memory previews) {
        previews = new RequestPreview[](ids.length);

        for (uint256 j; j < ids.length; ++j) {
            previews[j] = _requestPreview(ids[j]);
        }
    }

    // ---
    // INTERNAL — orchestration
    // ---

    /// @dev The request at `id` with its live fill preview — shared body of `previewFill` and the
    ///      `getRequestPreviews` batch. The fill figures are `(0, 0)` when the request is closed, expired,
    ///      unbacked, or quoting under its `minShareRate` floor.
    function _requestPreview(uint256 id) internal view returns (RequestPreview memory) {
        Request storage request = _book.requests[id];
        uint256 filledShares;
        uint256 assetsOut;

        if (request.status == ExitStatus.Open && block.timestamp <= request.deadline) {
            uint256 shareRate;
            (filledShares, shareRate) = _fillableShares(id, request);
            if (shareRate < request.minShareRate) filledShares = 0;
            if (filledShares != 0) assetsOut = _previewAssets(id, filledShares);
        }

        // An id that was never issued has no source to ask, so it reports a zeroed record rather than reverting
        // — one unknown id must not take a whole batch read down with it.
        IERC20 asset = request.owner == address(0) ? IERC20(address(0)) : _asset(id);

        return
            RequestPreview({id: id, request: request, asset: asset, filledShares: filledShares, assetsOut: assetsOut});
    }

    /// @dev Validate and append a request (called by a concrete book's `placeExitRequest`).
    function _createRequest(
        address account,
        address receiver,
        Sizing memory sizing,
        PriorityRamp calldata ramp,
        uint256 deadline,
        bool fullFillOnly
    ) internal returns (uint256 id) {
        if (receiver == address(0)) revert ZeroAddress();
        if (sizing.shares == 0) revert ZeroShares();
        if (sizing.quotedAssets == 0) revert ZeroAssetQuote();
        if (ramp.endRate > MAX_PRIORITY_FEE) revert PriorityFeeTooHigh();
        if (ramp.startRate > ramp.endRate) revert StartFeeAboveEnd();
        if (ramp.rampStart > ramp.rampEnd) revert RampStartAfterEnd();
        if (deadline <= block.timestamp) revert DeadlineInPast();
        if (deadline > block.timestamp + MAX_REQUEST_LIFETIME) revert DeadlineTooFar();
        if (block.timestamp + ramp.rampEnd > deadline) revert RampPastDeadline();

        id = _book.add(account, receiver, sizing, ramp, deadline, fullFillOnly);
        emit ExitRequested(
            id,
            account,
            receiver,
            address(sizing.asset),
            sizing.shares,
            sizing.minShareRate,
            ramp,
            deadline,
            fullFillOnly
        );
    }

    /// @dev Source fillable shares with the `fullFillOnly` policy applied. The source's share rate is returned
    ///      alongside.
    function _fillableShares(uint256 id, Request storage request)
        internal
        view
        returns (uint256 fillableShares, uint256 shareRate)
    {
        (fillableShares, shareRate) = _availableShares(id, request);
        if (request.fullFillOnly && fillableShares < request.sizeRemaining) fillableShares = 0;
    }

    /// @dev The priority-fee rate (WAD) in force now: `startRate` while within the `rampStart` hold, then
    ///      climbing linearly to `endRate` by `rampEnd`, then held at `endRate` until the deadline.
    function _priorityFeeRate(Request storage request) internal view returns (uint256) {
        uint256 startRate = request.startRate;
        uint256 rampStart = request.rampStart;
        uint256 elapsed = block.timestamp - request.createdAt;

        if (elapsed < rampStart) return startRate;

        uint256 endRate = request.endRate;
        uint256 rampEnd = request.rampEnd;

        if (elapsed >= rampEnd) return endRate;

        return startRate + (endRate - startRate) * (elapsed - rampStart) / (rampEnd - rampStart);
    }

    // ---
    // SOURCE OPERATIONS — abstract, implemented by a concrete book
    // ---

    /// @dev Shares fillable right now from the source (remaining size capped by live backing) before the
    ///      `fullFillOnly` policy is applied, together with the source's share rate: loan assets per
    ///      `SHARE_RATE_UNIT` shares, rounded down. The rate is meaningful only when the share count is
    ///      non-zero — a source that reports nothing fillable may report no rate either. No state change.
    function _availableShares(uint256 id, Request storage request)
        internal
        view
        virtual
        returns (uint256 availableShares, uint256 shareRate);

    /// @dev The loan token the request's source pays out in. Held by the source, not copied onto the record.
    function _asset(uint256 id) internal view virtual returns (IERC20);

    /// @dev Pull `shares` of `account`'s position out to this contract (assets land here). The base wraps
    ///      this with a balance-delta measurement, so the return value is ignored.
    function _redeem(uint256 id, address account, uint256 shares) internal virtual;

    /// @dev Deposit `depositAssets` of `asset` into the request's source on behalf of `filler`.
    function _depositLiquidity(uint256 id, IERC20 asset, uint256 depositAssets, address filler) internal virtual;

    /// @dev View estimate of the assets `shares` would yield from the source (for `previewFill`).
    function _previewAssets(uint256 id, uint256 shares) internal view virtual returns (uint256);
}
