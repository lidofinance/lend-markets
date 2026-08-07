// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ExitStatus, Request, PriorityRamp, Sizing} from "../types/ExitBookTypes.sol";

/// @title ExitBookLib
/// @author Lido
/// @notice Append-only request registry. Source-agnostic and storage-only: a book holds one `State` and
///         drives it via `using ExitBookLib for State`. Requests are never deleted — a fill marks `Filled`,
///         a cancel `Cancelled`. Lookups go by id (the `requests` mapping) or by owner (the `ownerRequestIds`
///         index); callers filter closed entries by status.
library ExitBookLib {
    // ---
    // ERRORS
    // ---

    /// @notice The request is not open (filled or cancelled).
    error RequestClosed();
    /// @notice The request is past its `deadline` and can no longer be filled.
    error RequestExpired();
    /// @notice The caller is not the request's owner.
    error NotOwner();

    // ---
    // STATE
    // ---

    /// @param nextId Monotonic id counter; the last id issued (ids start at 1).
    /// @param requests Every request ever created, keyed by id; closed ones linger as stable handles.
    /// @param ownerRequestIds Per-owner index of the ids that owner opened, in creation order.
    struct State {
        uint256 nextId;
        mapping(uint256 id => Request) requests;
        mapping(address owner => uint256[]) ownerRequestIds;
    }

    // ---
    // MUTATIONS
    // ---

    /// @notice Append a request and return its id.
    function add(
        State storage self,
        address owner,
        address receiver,
        Sizing memory sizing,
        PriorityRamp calldata ramp,
        uint256 deadline
    ) internal returns (uint256 id) {
        id = ++self.nextId;
        self.requests[id] = Request({
            owner: owner,
            receiver: receiver,
            createdAt: SafeCast.toUint40(block.timestamp),
            deadline: SafeCast.toUint40(deadline),
            status: ExitStatus.Open,
            sizeRemaining: SafeCast.toUint128(sizing.shares),
            sizeTotal: SafeCast.toUint128(sizing.shares),
            quotedAssets: sizing.quotedAssets,
            minShareRate: sizing.minShareRate,
            minFillShares: sizing.minFillShares,
            startRate: SafeCast.toUint96(ramp.startRate),
            endRate: SafeCast.toUint96(ramp.endRate),
            rampStart: SafeCast.toUint32(ramp.rampStart),
            rampEnd: SafeCast.toUint32(ramp.rampEnd)
        });
        self.ownerRequestIds[owner].push(id);
    }

    /// @notice Debit filled shares, marking `Filled` once fully drained.
    function recordFill(State storage self, uint256 id, uint256 filledShares) internal {
        Request storage request = self.requests[id];

        // Only an open request can be filled — guards against re-closing a cancelled/filled request (a
        // zero-share call would otherwise corrupt its status to `Filled`).
        if (request.status != ExitStatus.Open) revert RequestClosed();

        request.sizeRemaining -= SafeCast.toUint128(filledShares);

        if (request.sizeRemaining == 0) request.status = ExitStatus.Filled;
    }

    /// @notice Cancel `id` on behalf of `caller` (must be the owner). Marks `Cancelled`; nothing to refund.
    function cancel(State storage self, uint256 id, address caller) internal {
        Request storage request = self.requests[id];

        if (request.owner != caller) revert NotOwner();

        if (request.status != ExitStatus.Open) revert RequestClosed();

        request.sizeRemaining = 0;
        request.status = ExitStatus.Cancelled;
    }

    // ---
    // READS
    // ---

    /// @notice Load a request that is open and not past its `deadline`, reverting otherwise.
    function requireFillable(State storage self, uint256 id) internal view returns (Request storage request) {
        request = self.requests[id];

        if (request.owner == address(0) || request.status != ExitStatus.Open) revert RequestClosed();

        if (block.timestamp > request.deadline) revert RequestExpired();
    }
}
