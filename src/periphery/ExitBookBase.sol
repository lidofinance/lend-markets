// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IExitBook} from "../interfaces/IExitBook.sol";
import {ExitStatus, Request, PriorityRamp, RequestPreview} from "../types/ExitBookTypes.sol";
import {ExitBookLib} from "../libs/ExitBookLib.sol";
import {WAD} from "../libs/Constants.sol";

/// @title ExitBookBase
/// @author Lido
/// @notice Shared base of the exit books. A lender posts a request to exit a position; a filler later
///         closes it against available liquidity for a fee. A concrete book binds it to a source by
///         implementing the source operations, so any position that supports them can reuse this primitive.
abstract contract ExitBookBase is IExitBook, Ownable {
    using SafeERC20 for IERC20;
    using ExitBookLib for ExitBookLib.State;

    // ---
    // ERRORS
    // ---

    error ZeroShares();
    error ZeroMaxLifetime();
    error FeeTooHigh();
    error FeeRecipientRequired();
    error PriorityFeeTooHigh();
    error StartFeeAboveEnd();
    error RampPastDeadline();
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
        address asset,
        uint256 shares,
        uint256 startRate,
        uint256 endRate,
        uint256 rampDuration,
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

    /// @notice Cap on a request's priority-fee rate (WAD), checked at `place` — 10%.
    uint256 public constant MAX_PRIORITY_FEE = 0.1e18;

    /// @notice Hard cap on the service fee — a cut of the filler's gross reward (WAD) — 25%.
    uint256 public constant MAX_SERVICE_FEE = 0.25e18;

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

    constructor(address owner, uint256 maxLifetime_) Ownable(owner) {
        if (maxLifetime_ == 0) {
            revert ZeroMaxLifetime();
        }

        MAX_REQUEST_LIFETIME = maxLifetime_;
    }

    // ---
    // CONFIG
    // ---

    /// @inheritdoc IExitBook
    function setServiceFee(address recipient, uint256 fee) external onlyOwner {
        if (fee > MAX_SERVICE_FEE) {
            revert FeeTooHigh();
        }

        if (recipient == address(0) && fee != 0) {
            revert FeeRecipientRequired();
        }

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
        IERC20 asset = request.asset;

        if (depositAssets != 0) {
            asset.safeTransferFrom(msg.sender, address(this), depositAssets);
            _depositLiquidity(id, asset, depositAssets, msg.sender);
        }

        uint256 filledShares = _fillableShares(id, request);
        if (filledShares == 0) {
            revert NoFillableShares();
        }

        _book.recordFill(id, filledShares);

        // Redeem against the source and measure what actually arrived — never trust a return value.
        uint256 balanceBefore = asset.balanceOf(address(this));
        _redeem(id, request.owner, filledShares);
        uint256 assetsOut = asset.balanceOf(address(this)) - balanceBefore;
        if (assetsOut == 0) {
            revert NoAssetsRedeemed();
        }
        // Filler's slippage floor (0 to skip): if the fill under-produced, revert and roll back the deposit.
        // Late by necessity — `assetsOut` exists only post-redeem — so a griefed fill still burns the redeem
        // gas, but the filler's deposited capital is never committed below their floor.
        if (assetsOut < minAssetsOut) {
            revert AssetsOutBelowMin();
        }

        // Split what arrived three ways with no remainder: the lender gets their fixed-price `owed` minus the
        // priority fee, the filler gets the accrued yield plus that fee, the service takes a cut of the
        // filler's gross. `owed` is capped at `assetsOut` so a loss just trims it (no yield);
        // `feeRate <= MAX_PRIORITY_FEE < WAD`, so the fee never exceeds `owed`.
        uint256 owed = Math.min(Math.mulDiv(filledShares, request.pricePerShare, WAD), assetsOut);
        uint256 fee = Math.mulDiv(owed, _priorityFeeRate(request), WAD);
        uint256 fillerGross = (assetsOut - owed) + fee; // accrued yield + priority fee
        uint256 serviceCut = Math.mulDiv(fillerGross, serviceFee, WAD);
        uint256 fillerFee = fillerGross - serviceCut;
        uint256 lenderAssets = owed - fee;

        if (lenderAssets != 0) {
            asset.safeTransfer(request.owner, lenderAssets);
        }

        if (fillerFee != 0) {
            asset.safeTransfer(msg.sender, fillerFee);
        }

        if (serviceCut != 0) {
            asset.safeTransfer(feeRecipient, serviceCut);
        }

        emit ExitProcessed(id, msg.sender, address(asset), filledShares, lenderAssets, fillerFee, serviceCut);
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

        if (offset >= len) {
            return ids; // an unassigned named return is already an empty array
        }

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
    ///      `getRequestPreviews` batch.
    function _requestPreview(uint256 id) internal view returns (RequestPreview memory) {
        (uint256 filledShares, uint256 assetsOut) = _previewFill(id);
        return RequestPreview({id: id, request: _book.requests[id], filledShares: filledShares, assetsOut: assetsOut});
    }

    /// @dev Shares fillable now and the assets they would yield, or `(0, 0)` if the request is closed,
    ///      expired, or has no backing.
    function _previewFill(uint256 id) internal view returns (uint256 filledShares, uint256 assetsOut) {
        Request storage request = _book.requests[id];
        if (request.status != ExitStatus.Open || block.timestamp > request.deadline) {
            return (0, 0);
        }
        filledShares = _fillableShares(id, request);
        if (filledShares == 0) {
            return (0, 0);
        }
        assetsOut = _previewAssets(id, filledShares);
    }

    /// @dev Validate and append a request (called by a concrete book's `placeExitRequest`).
    function _createRequest(
        address account,
        IERC20 asset,
        uint256 shares,
        uint256 pricePerShare,
        PriorityRamp calldata ramp,
        uint256 deadline,
        bool fullFillOnly
    ) internal returns (uint256 id) {
        if (shares == 0) {
            revert ZeroShares();
        }
        if (ramp.endRate > MAX_PRIORITY_FEE) {
            revert PriorityFeeTooHigh();
        }
        if (ramp.startRate > ramp.endRate) {
            revert StartFeeAboveEnd();
        }
        if (deadline <= block.timestamp) {
            revert DeadlineInPast();
        }
        if (deadline > block.timestamp + MAX_REQUEST_LIFETIME) {
            revert DeadlineTooFar();
        }
        if (block.timestamp + ramp.rampDuration > deadline) {
            revert RampPastDeadline();
        }

        id = _book.add(account, asset, shares, pricePerShare, ramp, deadline, fullFillOnly);
        emit ExitRequested(
            id, account, address(asset), shares, ramp.startRate, ramp.endRate, ramp.rampDuration, deadline, fullFillOnly
        );
    }

    /// @dev Source fillable shares with the `fullFillOnly` policy applied.
    function _fillableShares(uint256 id, Request storage request) internal view returns (uint256 fillableShares) {
        fillableShares = _availableShares(id, request);
        if (request.fullFillOnly && fillableShares < request.sizeRemaining) {
            fillableShares = 0;
        }
    }

    /// @dev The priority-fee rate (WAD) in force now: `startRate` at creation, climbing linearly to
    ///      `endRate` over `rampDuration`, then held at `endRate` until the deadline.
    function _priorityFeeRate(Request storage request) internal view returns (uint256) {
        uint256 endRate = request.endRate;
        uint256 rampDuration = request.rampDuration;
        uint256 elapsed = block.timestamp - request.createdAt;

        if (elapsed >= rampDuration) {
            return endRate;
        }

        uint256 startRate = request.startRate;
        return startRate + (endRate - startRate) * elapsed / rampDuration;
    }

    // ---
    // SOURCE OPERATIONS — abstract, implemented by a concrete book
    // ---

    /// @dev Shares fillable right now from the source (remaining size capped by live backing), before the
    ///      `fullFillOnly` policy is applied. No state change.
    function _availableShares(uint256 id, Request storage request) internal view virtual returns (uint256);

    /// @dev Pull `shares` of `account`'s position out to this contract (assets land here). The base wraps
    ///      this with a balance-delta measurement, so the return value is ignored.
    function _redeem(uint256 id, address account, uint256 shares) internal virtual;

    /// @dev Deposit `depositAssets` of `asset` into the request's source on behalf of `filler`.
    function _depositLiquidity(uint256 id, IERC20 asset, uint256 depositAssets, address filler) internal virtual;

    /// @dev View estimate of the assets `shares` would yield from the source (for `previewFill`).
    function _previewAssets(uint256 id, uint256 shares) internal view virtual returns (uint256);
}
