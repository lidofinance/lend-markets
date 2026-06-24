// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @title LenderExitBookLib
/// @author Lido Lending contributors.
/// @notice Registry of lender withdrawal requests: a flat id-keyed store with an active-id list for
///         paginated reads. No ordering — any request is filled by id. The embedding contract owns
///         the token movement, pricing, and settlement split; this library owns only the request
///         lifecycle (create, fill bookkeeping, cancel, enumerate).
/// @dev Self-contained: operates on a caller-embedded `State`, makes no external calls.
library LenderExitBookLib {
    // ---
    // TYPES
    // ---

    /// @notice How the request's shares are held, which decides what the embedding contract refunds on
    ///         cancel/expiry and how a fill is settled.
    enum Mode {
        Direct, // core-authorized withdrawal from the lender's own position
        Vault // escrowed ERC-4626 vault shares
    }

    /// @param owner The exiting lender.
    /// @param mode Entry mode: Direct (core-authorized) or Vault (escrowed shares).
    /// @param sizeRemaining Outstanding shares — escrowed vault shares (Vault) or core supply shares
    ///        (Direct). The fixed-price owed is `sizeRemaining * pricePerShare`; yield above it is the
    ///        keeper's reward, so the request tracks shares (not assets) to capture that yield.
    /// @param sizeTotal Original shares, the denominator for the per-fill priority-fee fraction.
    /// @param pricePerShare Assets per share, WAD-scaled, fixed when the request was created.
    /// @param maxPriorityFee Priority-fee cap, in loan-asset units. The fee a fill actually pays
    ///        ramps from 0 at `createdAt` to this cap at `deadline` (a Dutch auction), so a later
    ///        fill earns more; the unramped remainder stays with the lender.
    /// @param createdAt Timestamp the request was opened, the ramp's start.
    /// @param deadline Last timestamp the request may be filled, and the ramp's full-fee point.
    /// @param fullFillOnly Lender policy chosen at creation: when true the request may only be filled
    ///        in a single shot covering the whole size — a fill that cannot cover it all is rejected,
    ///        so the request is never left partially drained.
    /// @param closed Set when the request is fully filled, cancelled, or pruned; dropped from the
    ///        active set at that point.
    struct Request {
        address owner;
        Mode mode;
        uint256 sizeRemaining;
        uint256 sizeTotal;
        uint256 pricePerShare;
        uint96 maxPriorityFee;
        uint40 createdAt;
        uint40 deadline;
        bool fullFillOnly;
        bool closed;
    }

    /// @notice The whole queue: a flat id-keyed store plus the live-id index for pagination.
    /// @param nextId Monotonic id counter, never reused, so a closed id stays a stable handle.
    /// @param requests Every request ever created, keyed by id; closed ones linger here for lookups.
    /// @param activeIds Ids of open requests only, the set `paginate`/`count` walk. Swap-popped on close.
    struct State {
        uint256 nextId;
        mapping(uint256 id => Request) requests;
        uint256[] activeIds;
    }

    // ---
    // ERRORS
    // ---

    /// @notice The request is already closed (fully filled, cancelled, or pruned) and cannot be acted on.
    error RequestClosed();

    /// @notice The request is past its `deadline`, so it can no longer be filled.
    error RequestExpired();

    /// @notice The caller is not the request's `owner`, so it may not cancel it.
    error NotOwner();

    // ---
    // LIFECYCLE
    // ---

    /// @notice Create a request and add it to the active set. `createdAt` is stamped to now, anchoring
    ///         the priority-fee ramp that runs to `deadline`.
    function add(
        State storage self,
        address owner,
        Mode mode,
        uint256 shares,
        uint256 pricePerShare,
        uint256 maxPriorityFee,
        uint256 deadline,
        bool fullFillOnly
    ) internal returns (uint256 id) {
        id = self.nextId++;
        self.requests[id] = Request({
            owner: owner,
            mode: mode,
            sizeRemaining: shares,
            sizeTotal: shares,
            pricePerShare: pricePerShare,
            maxPriorityFee: SafeCast.toUint96(maxPriorityFee),
            createdAt: SafeCast.toUint40(block.timestamp),
            deadline: SafeCast.toUint40(deadline),
            fullFillOnly: fullFillOnly,
            closed: false
        });
        self.activeIds.push(id);
    }

    /// @notice Load a request that is open and not past its deadline, reverting otherwise.
    function requireOpen(State storage self, uint256 id) internal view returns (Request storage request) {
        request = self.requests[id];
        if (request.owner == address(0) || request.closed) revert RequestClosed();
        if (block.timestamp > request.deadline) revert RequestExpired();
    }

    /// @notice Record a fill: debit the filled shares, closing the request once it is fully drained.
    ///         The priority fee is recomputed per fill from the time ramp, so there is no fee budget
    ///         to debit here.
    function recordFill(State storage self, uint256 id, uint256 filledShares) internal {
        Request storage request = self.requests[id];
        request.sizeRemaining -= filledShares;
        if (request.sizeRemaining == 0) _close(self, id);
    }

    /// @notice Cancel `id` on behalf of `caller` (must be the owner). Returns the mode and the
    ///         leftover share size so the caller can refund escrow; the request is closed.
    function cancel(State storage self, uint256 id, address caller) internal returns (Mode mode, uint256 leftover) {
        Request storage request = self.requests[id];
        if (request.owner != caller) revert NotOwner();
        if (request.closed) revert RequestClosed();
        mode = request.mode;
        leftover = request.sizeRemaining;
        request.sizeRemaining = 0;
        _close(self, id);
    }

    /// @notice Close `id` if it is open and past its deadline; a no-op (`pruned == false`) otherwise so
    ///         a batch prune can skip ineligible ids without reverting. Returns the owner, mode, and
    ///         leftover share size for the caller to refund escrow.
    function expireIfDue(State storage self, uint256 id)
        internal
        returns (bool pruned, Mode mode, address owner, uint256 leftover)
    {
        Request storage request = self.requests[id];
        if (request.owner == address(0) || request.closed || block.timestamp <= request.deadline) {
            return (false, Mode.Direct, address(0), 0);
        }
        pruned = true;
        mode = request.mode;
        owner = request.owner;
        leftover = request.sizeRemaining;
        request.sizeRemaining = 0;
        _close(self, id);
    }

    // ---
    // VIEWS
    // ---

    /// @notice Open request ids, paginated; `offset`/`limit` index into the active set.
    function paginate(State storage self, uint256 offset, uint256 limit) internal view returns (uint256[] memory ids) {
        uint256 length = self.activeIds.length;
        if (offset >= length) return new uint256[](0);
        uint256 end = Math.min(offset + limit, length);
        ids = new uint256[](end - offset);
        for (uint256 index = offset; index < end; ++index) {
            ids[index - offset] = self.activeIds[index];
        }
    }

    /// @notice Number of open requests, the upper bound for `paginate`.
    function count(State storage self) internal view returns (uint256) {
        return self.activeIds.length;
    }

    // ---
    // INTERNAL HELPERS
    // ---

    /// @dev Mark closed and swap-pop the id out of the active set.
    function _close(State storage self, uint256 id) private {
        self.requests[id].closed = true;
        uint256 length = self.activeIds.length;
        for (uint256 index; index < length; ++index) {
            if (self.activeIds[index] == id) {
                self.activeIds[index] = self.activeIds[length - 1];
                self.activeIds.pop();
                break;
            }
        }
    }
}
