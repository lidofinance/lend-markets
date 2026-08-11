// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControlEnumerable} from "@openzeppelin/contracts/access/extensions/AccessControlEnumerable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IExitBook} from "../interfaces/IExitBook.sol";
import {AssetRecoverer} from "../utils/AssetRecoverer.sol";
import {Request, PriorityRamp} from "../types/ExitBookTypes.sol";
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
    error ZeroAssets();
    error ZeroMaxLifetime();
    error FeeTooHigh();
    error FeeRecipientRequired();
    error PriorityFeeTooHigh();
    error StartFeeAboveEnd();
    error RampStartAfterEnd();
    error RampPastDeadline();
    error FillExceedsRemaining(uint256 requested, uint256 remaining);
    error FillBelowMinimum(uint256 requested, uint256 minimum);
    error MaxShareBurnBelowQuote(uint256 maximum, uint256 quote);
    error ShareBurnExceedsMaximum(uint256 actual, uint256 maximum);
    error AssetsOutMismatch(uint256 expected, uint256 actual);
    error DeadlineInPast();
    error DeadlineTooFar();
    error EnforcedPause();

    // ---
    // EVENTS
    // ---

    event ExitRequested(
        uint256 indexed id,
        address indexed owner,
        address indexed receiver,
        address asset,
        uint256 assets,
        uint256 minFillAssets,
        uint256 maxShareBurn,
        PriorityRamp ramp,
        uint256 deadline
    );

    event ExitProcessed(
        uint256 indexed id,
        address indexed executor,
        address indexed rewardRecipient,
        address asset,
        uint256 filledAssets,
        uint256 sharesBurned,
        uint256 fillerReward,
        uint256 serviceCut
    );

    event ExitCancelled(uint256 indexed id);

    event ServiceFeeSet(address indexed feeRecipient, uint256 serviceFee);

    event Paused(address account);

    event Unpaused(address account);

    // ---
    // CONSTANTS
    // ---

    /// @notice Role allowed to manage which markets or vaults may receive new requests.
    bytes32 public constant ALLOWLIST_MANAGER_ROLE = keccak256("ALLOWLIST_MANAGER_ROLE");
    /// @notice Role allowed to set the service fee and its recipient.
    bytes32 public constant FEE_MANAGER_ROLE = keccak256("FEE_MANAGER_ROLE");
    /// @notice Role allowed to recover tokens held by the contract.
    bytes32 public constant RECOVERER_ROLE = keccak256("RECOVERER_ROLE");
    /// @inheritdoc IExitBook
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    /// @inheritdoc IExitBook
    bytes32 public constant RESUMER_ROLE = keccak256("RESUMER_ROLE");

    /// @notice Cap on a request's priority-fee rate (WAD), checked at `place` — 10%.
    uint256 public constant MAX_PRIORITY_FEE = 0.1e18;

    /// @notice Hard cap on the service fee — a cut of the priority fee (WAD) — 25%.
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

    /// @inheritdoc IExitBook
    bool public paused;

    /// @notice Service fee: a cut of each fill's priority fee, as a WAD rate.
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
    // PAUSE
    // ---

    /// @inheritdoc IExitBook
    function pause() external onlyRole(PAUSER_ROLE) {
        paused = true;
        emit Paused(msg.sender);
    }

    /// @inheritdoc IExitBook
    function resume() external onlyRole(RESUMER_ROLE) {
        paused = false;
        emit Unpaused(msg.sender);
    }

    // ---
    // FILL
    // ---

    /// @inheritdoc IExitBook
    /// @dev Debits the exact amount before withdrawing it from the source.
    function fillExitRequest(uint256 id, uint256 fillAssets, address rewardRecipient) external {
        if (paused) revert EnforcedPause();
        if (rewardRecipient == address(0)) revert ZeroAddress();

        Request storage request = _book.requireFillable(id);
        IERC20 asset = request.asset;

        if (fillAssets == 0) revert ZeroAssets();

        if (fillAssets > request.assetsRemaining) revert FillExceedsRemaining(fillAssets, request.assetsRemaining);
        if (fillAssets < request.minFillAssets && fillAssets < request.assetsRemaining) {
            revert FillBelowMinimum(fillAssets, request.minFillAssets);
        }

        _book.recordFill(id, fillAssets);

        uint256 sharesBurned;
        {
            uint256 balanceBefore = asset.balanceOf(address(this));
            sharesBurned = _withdraw(id, request.owner, fillAssets);
            uint256 assetsOut = asset.balanceOf(address(this)) - balanceBefore;
            if (assetsOut != fillAssets) revert AssetsOutMismatch(fillAssets, assetsOut);
            if (request.maxShareBurn != 0) {
                // Match source withdrawals that round share burn up. Ceiling adds at most one raw share unit above
                // the proportional floor per fill; across a split request, total allowance may exceed maxShareBurn
                // by at most one unit per additional fill.
                uint256 maxSharesForFill =
                    Math.mulDiv(request.maxShareBurn, fillAssets, request.assetsTotal, Math.Rounding.Ceil);
                if (sharesBurned > maxSharesForFill) revert ShareBurnExceedsMaximum(sharesBurned, maxSharesForFill);
            }
        }

        uint256 receiverAssets;
        uint256 fillerReward;
        uint256 serviceCut;
        {
            uint256 priorityFee = Math.mulDiv(fillAssets, _priorityFeeRate(request), WAD);
            serviceCut = Math.mulDiv(priorityFee, serviceFee, WAD);
            fillerReward = priorityFee - serviceCut;
            receiverAssets = fillAssets - priorityFee;
        }

        if (receiverAssets != 0) asset.safeTransfer(request.receiver, receiverAssets);

        if (fillerReward != 0) asset.safeTransfer(rewardRecipient, fillerReward);

        if (serviceCut != 0) asset.safeTransfer(feeRecipient, serviceCut);

        emit ExitProcessed(
            id, msg.sender, rewardRecipient, address(asset), fillAssets, sharesBurned, fillerReward, serviceCut
        );
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

    // ---
    // INTERNAL — orchestration
    // ---

    /// @dev Validate and append a request (called by a concrete book's `placeExitRequest`).
    function _createRequest(
        address account,
        address receiver,
        IERC20 asset,
        uint256 assets,
        uint256 minFillAssets,
        uint256 requiredShares,
        uint256 maxShareBurn,
        PriorityRamp calldata ramp,
        uint256 deadline
    ) internal returns (uint256 id) {
        if (receiver == address(0)) revert ZeroAddress();
        if (assets == 0) revert ZeroAssets();
        if (maxShareBurn != 0 && maxShareBurn < requiredShares) {
            revert MaxShareBurnBelowQuote(maxShareBurn, requiredShares);
        }
        if (ramp.endRate > MAX_PRIORITY_FEE) revert PriorityFeeTooHigh();
        if (ramp.startRate > ramp.endRate) revert StartFeeAboveEnd();
        if (ramp.rampStart > ramp.rampEnd) revert RampStartAfterEnd();
        if (deadline <= block.timestamp) revert DeadlineInPast();
        if (deadline > block.timestamp + MAX_REQUEST_LIFETIME) revert DeadlineTooFar();
        if (block.timestamp + ramp.rampEnd > deadline) revert RampPastDeadline();

        minFillAssets = Math.min(minFillAssets, assets);
        id = _book.add(account, receiver, asset, assets, minFillAssets, maxShareBurn, ramp, deadline);
        emit ExitRequested(id, account, receiver, address(asset), assets, minFillAssets, maxShareBurn, ramp, deadline);
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

    /// @dev Withdraw exactly `assets` from `account`'s position to this contract and return the source shares
    ///      burned. The base measures the received asset balance delta independently.
    function _withdraw(uint256 id, address account, uint256 assets) internal virtual returns (uint256 sharesBurned);
}
