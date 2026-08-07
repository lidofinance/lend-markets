// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {Erc4626ExitBook} from "../../../src/periphery/Erc4626ExitBook.sol";
import {Request, RequestPreview, PriorityRamp, ExitStatus} from "../../../src/types/ExitBookTypes.sol";

interface IMintable {
    function mint(address to, uint256 amount) external;
}

/// @notice Handler for the ERC-4626 exit-book solvency invariant. A small fixed actor set of lenders place exit
///         requests against a single OZ ERC-4626 mock vault; one filler fills them; the book owner cancels;
///         yield is donated to move the share price. Every action self-bounds and early-returns when there is no
///         room, so the fuzzer drives long valid sequences. Tracks ghosts the invariant suite reads:
///         - `allIds` / `seen`: every id ever placed and the set membership behind it.
///         - per-fill three-way accumulators (`sumLenderPaid` + `sumFillerPaid` + `sumServicePaid`) vs
///           `sumAssetsOut`: the running conservation identity.
///         - `sizeCeiling[id]` / `wasClosed[id]`: `sizeRemaining` never grows, and a closed status never
///           reverts to Open.
///         Mirrors `MarketHandler`: `is CommonBase, StdCheats, StdUtils` (not Test) so the target set stays clean.
contract ExitBookHandler is CommonBase, StdCheats, StdUtils {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant MAX_PRIORITY_FEE = 0.1e18;

    Erc4626ExitBook internal immutable BOOK;
    IERC4626 internal immutable VAULT;
    IERC20 internal immutable ASSET;
    uint256 internal immutable MAX_LIFETIME;
    address internal immutable FILLER;
    address internal immutable FEE_RECIPIENT;

    address[] internal lenders;

    // --- ghosts ---

    uint256[] internal allIds; // every id ever placed (creation order)
    mapping(uint256 id => bool) internal seen;
    // Largest `sizeRemaining` ever observed for an id; the invariant asserts the live value never exceeds it.
    mapping(uint256 id => uint256) public sizeCeiling;
    // Statuses observed terminal (Filled/Cancelled) — the invariant asserts they never revert to Open.
    mapping(uint256 id => bool) public wasClosed;

    uint256 public fillCount;
    // Independent vault-side measure of what the book redeemed per fill: `deposit + (vaultBefore - vaultAfter)`.
    uint256 public sumAssetsOut;
    uint256 public sumLenderPaid;
    uint256 public sumFillerPaid;
    uint256 public sumServicePaid;
    // Independent conservation reference, no-liquidity fills only: `previewRedeem` (snapped pre-fill) is exactly
    // the redeem proceeds when the filler brings nothing, so the measured legs must reconstruct it with no
    // remainder. (With a liquidity deposit the pre-fill preview understates the post-deposit price, so those
    // fills are excluded from this reference and covered by the book-holds-zero invariant instead.)
    uint256 public sumLegsNoDep;
    uint256 public sumPreviewNoDep;

    constructor(
        Erc4626ExitBook book,
        IERC4626 vault,
        IERC20 asset,
        uint256 maxLifetime,
        address filler,
        address feeRecipient,
        address[] memory lenders_
    ) {
        BOOK = book;
        VAULT = vault;
        ASSET = asset;
        MAX_LIFETIME = maxLifetime;
        FILLER = filler;
        FEE_RECIPIENT = feeRecipient;
        lenders = lenders_;
    }

    // ---
    // VIEWS for the invariant suite
    // ---

    function idCount() external view returns (uint256) {
        return allIds.length;
    }

    function idAt(uint256 i) external view returns (uint256) {
        return allIds[i];
    }

    // ---
    // HELPERS
    // ---

    function _lender(uint256 seed) internal view returns (address) {
        return lenders[seed % lenders.length];
    }

    function _mint(address to, uint256 amount) internal {
        IMintable(address(ASSET)).mint(to, amount);
    }

    /// @dev A random live (Open, not past deadline) request id, or 0 if none.
    function _liveId(uint256 seed) internal view returns (uint256) {
        uint256 n = allIds.length;
        if (n == 0) return 0;
        uint256 start = seed % n;
        for (uint256 k; k < n; ++k) {
            uint256 id = allIds[(start + k) % n];
            Request memory r = BOOK.getExitRequest(id);
            if (r.status == ExitStatus.Open && block.timestamp <= r.deadline) return id;
        }
        return 0;
    }

    /// @dev Refresh the ghosts for `id`: register it on first sight, track the high-water `sizeRemaining`, and
    ///      latch the terminal-status flag once it leaves Open.
    function _sync(uint256 id) internal {
        if (!seen[id]) {
            seen[id] = true;
            allIds.push(id);
        }
        Request memory r = BOOK.getExitRequest(id);
        if (r.sizeRemaining > sizeCeiling[id]) sizeCeiling[id] = r.sizeRemaining;
        if (r.status != ExitStatus.Open) wasClosed[id] = true;
    }

    // ---
    // ACTIONS
    // ---

    /// @dev A lender deposits fresh assets, approves the book for the whole resulting balance, and places an
    ///      exit for a bounded asset amount with a valid ramp + deadline. Approving the full balance is what lets
    ///      overlapping requests from the same owner all still redeem at fill time.
    function place(
        uint256 lenderSeed,
        uint256 depositAmt,
        uint256 exitSeed,
        uint256 startRate,
        uint256 endRate,
        uint256 rampStart,
        uint256 rampEnd,
        uint256 deadlineSeed
    ) external {
        address a = _lender(lenderSeed);
        depositAmt = bound(depositAmt, 1 ether, 1_000_000 ether);
        _mint(a, depositAmt);

        vm.startPrank(a);
        ASSET.approve(address(VAULT), depositAmt);
        VAULT.deposit(depositAmt, a);
        VAULT.approve(address(BOOK), VAULT.balanceOf(a));
        vm.stopPrank();

        // Requests are denominated in assets; an amount too small to buy a whole share is skipped rather than
        // placed.
        uint256 exitAssets = bound(exitSeed, 1, depositAmt);
        if (VAULT.convertToShares(exitAssets) == 0) return;

        // Valid ramp: endRate in [0, MAX_PRIORITY_FEE]; startRate <= endRate; rampStart <= rampEnd; and
        // rampEnd must leave room before the deadline.
        endRate = bound(endRate, 0, MAX_PRIORITY_FEE);
        startRate = bound(startRate, 0, endRate);
        rampEnd = bound(rampEnd, 0, MAX_LIFETIME - 1);
        rampStart = bound(rampStart, 0, rampEnd);
        // deadline in (now + rampEnd, now + MAX_LIFETIME].
        uint256 minDeadline = block.timestamp + rampEnd + 1;
        uint256 maxDeadline = block.timestamp + MAX_LIFETIME;
        if (minDeadline > maxDeadline) return;
        uint256 deadline = bound(deadlineSeed, minDeadline, maxDeadline);

        PriorityRamp memory ramp =
            PriorityRamp({startRate: startRate, endRate: endRate, rampStart: rampStart, rampEnd: rampEnd});

        vm.prank(a);
        uint256 id = BOOK.placeExitRequest(VAULT, exitAssets, ramp, deadline, false);
        _sync(id);
    }

    /// @dev The filler fills a random live request. With probability ~half it brings liquidity
    ///      (`depositAssets`), otherwise it draws purely on the vault's existing backing. Accumulates the exact
    ///      three-way split from the actual token deltas for the conservation invariant.
    function fill(uint256 idSeed, uint256 depositAssets, bool bringLiquidity) external {
        uint256 id = _liveId(idSeed);
        if (id == 0) return;

        Request memory r = BOOK.getExitRequest(id);
        // Skip if there is nothing fillable right now (no live backing) — fill would revert NoFillableShares.
        RequestPreview memory p = BOOK.previewFill(id);
        if (p.filledShares == 0 || p.assetsOut == 0) return;

        uint256 deposit = 0;
        if (bringLiquidity) {
            deposit = bound(depositAssets, 1 ether, 100_000 ether);
            _mint(FILLER, deposit);
            vm.prank(FILLER);
            ASSET.approve(address(BOOK), deposit);
        }

        uint256[3] memory pre = [ASSET.balanceOf(r.owner), ASSET.balanceOf(FILLER), ASSET.balanceOf(FEE_RECIPIENT)];
        uint256 vaultBefore = ASSET.balanceOf(address(VAULT));

        vm.prank(FILLER);
        BOOK.fillExitRequest(id, deposit, 0);

        uint256 lenderGot = ASSET.balanceOf(r.owner) - pre[0];
        uint256 fillerGot = ASSET.balanceOf(FILLER) + deposit - pre[1]; // + deposit recovers the gross leg
        uint256 feeGot = ASSET.balanceOf(FEE_RECIPIENT) - pre[2];
        uint256 redeemed = deposit + vaultBefore - ASSET.balanceOf(address(VAULT));

        fillCount += 1;
        sumLenderPaid += lenderGot;
        sumFillerPaid += fillerGot;
        sumServicePaid += feeGot;
        sumAssetsOut += redeemed;

        if (!bringLiquidity) {
            // `p.assetsOut` is `previewRedeem(filledShares)` snapped BEFORE this fill — with no liquidity
            // deposit the pool is unchanged at redeem time, so it is exactly the proceeds. The measured legs
            // must reconstruct it with no remainder.
            sumLegsNoDep += (lenderGot + fillerGot + feeGot);
            sumPreviewNoDep += p.assetsOut;
        }

        _sync(id);
    }

    /// @dev The owner cancels a random live request.
    function cancel(uint256 idSeed) external {
        uint256 id = _liveId(idSeed);
        if (id == 0) return;
        address owner = BOOK.getExitRequest(id).owner;
        vm.prank(owner);
        BOOK.cancelExitRequest(id);
        _sync(id);
    }

    /// @dev Donate assets straight into the vault, raising the share price above placed snapshots (yield).
    function donateYield(uint256 amount) external {
        amount = bound(amount, 1 ether, 100_000 ether);
        _mint(address(VAULT), amount);
    }

    /// @dev Advance time within the active request window so ramp regimes (hold/linear/plateau) and expiry get
    ///      exercised.
    function warp(uint256 dt) external {
        dt = bound(dt, 1 hours, MAX_LIFETIME / 4);
        vm.warp(block.timestamp + dt);
    }
}
