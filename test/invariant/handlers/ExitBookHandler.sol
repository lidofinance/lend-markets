// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {CommonBase} from "forge-std/Base.sol";
import {StdAssertions} from "forge-std/StdAssertions.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {Erc4626ExitBook} from "../../../src/periphery/Erc4626ExitBook.sol";
import {Request, PriorityRamp, ExitStatus} from "../../../src/types/ExitBookTypes.sol";

interface IMintable {
    function mint(address to, uint256 amount) external;
}

interface IAllocatableVault {
    function allocate(uint256 assets) external;

    function realizeLoss(uint256 assets) external;
}

struct FillSnapshot {
    Request request;
    uint256 receiverAssets;
    uint256 fillerAssets;
    uint256 rewardRecipientAssets;
    uint256 feeRecipientAssets;
    uint256 bookAssets;
    uint256 vaultAssets;
    uint256 ownerShares;
    uint256 fillerShares;
    uint256 ownerShareAllowance;
}

/// @notice Handler for the ERC-4626 exit-book solvency invariant. A small fixed actor set of lenders place exit
///         requests against one liquidity-aware ERC-4626 vault; one filler fills them; the owner cancels; yield
///         and source allocations move the share price and live liquidity. Every action self-bounds and tracks
///         exact request state and checks each fill's payout conservation, executor isolation, and failure rollback.
///         Mirrors `MarketHandler`: `is CommonBase, StdAssertions, StdCheats, StdUtils` (not Test) so the target set
///         stays clean.
contract ExitBookHandler is CommonBase, StdAssertions, StdCheats, StdUtils {
    uint256 internal constant MAX_PRIORITY_FEE = 0.1e18;

    Erc4626ExitBook internal immutable BOOK;
    IERC4626 internal immutable VAULT;
    IERC20 internal immutable ASSET;
    uint256 internal immutable MAX_LIFETIME;
    address internal immutable FILLER;
    address internal immutable REWARD_RECIPIENT;
    address internal immutable FEE_RECIPIENT;

    address[] internal lenders;

    // --- ghosts ---

    uint256[] internal allIds; // every id ever placed (creation order)
    mapping(uint256 id => uint256) public expectedRemaining;
    mapping(uint256 id => ExitStatus) public expectedStatus;

    uint256 public fillCount;
    uint256 public protectedFillCount;
    uint256 public lateShareFailureCount;
    uint256 public pausedFillFailures;
    uint256 public unavailableFillAttempts;
    uint256 public closedFillFailures;
    uint256 public expiredFillFailures;
    uint256 public pausedPlacementAttempts;

    uint256 public sumFilledAssets;
    uint256 public sumReceiverPaid;
    uint256 public sumRewardPaid;
    uint256 public sumServicePaid;

    constructor(
        Erc4626ExitBook book,
        IERC4626 vault,
        IERC20 asset,
        uint256 maxLifetime,
        address filler,
        address rewardRecipient,
        address feeRecipient,
        address[] memory lenders_
    ) {
        BOOK = book;
        VAULT = vault;
        ASSET = asset;
        MAX_LIFETIME = maxLifetime;
        FILLER = filler;
        REWARD_RECIPIENT = rewardRecipient;
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

    /// @dev A random live (Open and not past deadline) request id, or 0 if none.
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

    function _protectedLiveId(uint256 seed) internal view returns (uint256) {
        uint256 n = allIds.length;
        if (n == 0) return 0;
        uint256 start = seed % n;
        for (uint256 k; k < n; ++k) {
            uint256 id = allIds[(start + k) % n];
            Request memory r = BOOK.getExitRequest(id);
            if (r.status == ExitStatus.Open && block.timestamp <= r.deadline && r.maxShareBurn != 0) return id;
        }
        return 0;
    }

    function _openId(uint256 seed) internal view returns (uint256) {
        uint256 n = allIds.length;
        if (n == 0) return 0;
        uint256 start = seed % n;
        for (uint256 k; k < n; ++k) {
            uint256 id = allIds[(start + k) % n];
            if (BOOK.getExitRequest(id).status == ExitStatus.Open) return id;
        }
        return 0;
    }

    function _unavailableId(uint256 seed) internal view returns (uint256) {
        uint256 n = allIds.length;
        if (n == 0) return 0;
        uint256 start = seed % n;
        for (uint256 k; k < n; ++k) {
            uint256 id = allIds[(start + k) % n];
            Request memory r = BOOK.getExitRequest(id);
            if (r.status != ExitStatus.Open || block.timestamp > r.deadline) return id;
        }
        return 0;
    }

    /// @dev Register a newly placed request and seed its independent expected-state model.
    function _sync(uint256 id) internal {
        allIds.push(id);

        Request memory r = BOOK.getExitRequest(id);
        expectedRemaining[id] = r.assetsRemaining;
        expectedStatus[id] = ExitStatus.Open;
    }

    function _snapshot(Request memory request) internal view returns (FillSnapshot memory snapshot) {
        snapshot.request = request;
        snapshot.receiverAssets = ASSET.balanceOf(request.receiver);
        snapshot.fillerAssets = ASSET.balanceOf(FILLER);
        snapshot.rewardRecipientAssets = ASSET.balanceOf(REWARD_RECIPIENT);
        snapshot.feeRecipientAssets = ASSET.balanceOf(FEE_RECIPIENT);
        snapshot.bookAssets = ASSET.balanceOf(address(BOOK));
        snapshot.vaultAssets = ASSET.balanceOf(address(VAULT));
        snapshot.ownerShares = VAULT.balanceOf(request.owner);
        snapshot.fillerShares = VAULT.balanceOf(FILLER);
        snapshot.ownerShareAllowance = VAULT.allowance(request.owner, address(BOOK));
    }

    function _callFill(uint256 id, uint256 fillAssets) internal returns (bool success) {
        vm.prank(FILLER);
        (success,) =
            address(BOOK).call(abi.encodeWithSelector(BOOK.fillExitRequest.selector, id, fillAssets, REWARD_RECIPIENT));
    }

    function _assertRollback(uint256 id, FillSnapshot memory before_) internal view {
        Request memory after_ = BOOK.getExitRequest(id);
        assertEq(keccak256(abi.encode(after_)), keccak256(abi.encode(before_.request)), "request rolls back");
        assertEq(ASSET.balanceOf(before_.request.receiver), before_.receiverAssets, "receiver assets roll back");
        assertEq(ASSET.balanceOf(FILLER), before_.fillerAssets, "filler assets roll back");
        assertEq(ASSET.balanceOf(REWARD_RECIPIENT), before_.rewardRecipientAssets, "reward-recipient assets roll back");
        assertEq(ASSET.balanceOf(FEE_RECIPIENT), before_.feeRecipientAssets, "service assets roll back");
        assertEq(ASSET.balanceOf(address(BOOK)), before_.bookAssets, "book assets roll back");
        assertEq(ASSET.balanceOf(address(VAULT)), before_.vaultAssets, "vault assets roll back");
        assertEq(VAULT.balanceOf(before_.request.owner), before_.ownerShares, "owner shares roll back");
        assertEq(VAULT.balanceOf(FILLER), before_.fillerShares, "filler shares roll back");
        assertEq(
            VAULT.allowance(before_.request.owner, address(BOOK)),
            before_.ownerShareAllowance,
            "owner share allowance rolls back"
        );
    }

    function _assertSuccessfulShareChecks(uint256 fillAssets, FillSnapshot memory before_) internal view {
        uint256 sharesAfter = VAULT.balanceOf(before_.request.owner);
        assertLe(sharesAfter, before_.ownerShares, "owner shares cannot increase on fill");
        uint256 sharesBurned = before_.ownerShares - sharesAfter;
        if (before_.request.maxShareBurn != 0) {
            uint256 maxSharesForFill =
                Math.mulDiv(before_.request.maxShareBurn, fillAssets, before_.request.assetsTotal, Math.Rounding.Ceil);
            assertLe(sharesBurned, maxSharesForFill, "burn respects owner protection");
        }
    }

    function _recordSuccessfulFill(uint256 id, uint256 fillAssets, FillSnapshot memory before_) internal {
        Request memory after_ = BOOK.getExitRequest(id);
        uint256 remaining = before_.request.assetsRemaining - fillAssets;
        assertEq(after_.assetsRemaining, remaining, "exact remainder debit");
        assertEq(uint256(after_.status), uint256(remaining == 0 ? ExitStatus.Filled : ExitStatus.Open), "fill status");

        uint256 receiverPaid = ASSET.balanceOf(before_.request.receiver) - before_.receiverAssets;
        uint256 rewardPaid = ASSET.balanceOf(REWARD_RECIPIENT) - before_.rewardRecipientAssets;
        uint256 servicePaid = ASSET.balanceOf(FEE_RECIPIENT) - before_.feeRecipientAssets;

        assertEq(ASSET.balanceOf(address(VAULT)) + fillAssets, before_.vaultAssets, "source sends exact assets");
        assertEq(ASSET.balanceOf(FILLER), before_.fillerAssets, "fill does not take executor assets");
        assertEq(VAULT.balanceOf(FILLER), before_.fillerShares, "fill does not change executor source shares");
        assertEq(receiverPaid + rewardPaid + servicePaid, fillAssets, "payouts equal exact withdrawal");
        assertEq(ASSET.balanceOf(address(BOOK)), before_.bookAssets, "book retains no fill assets");
        _assertSuccessfulShareChecks(fillAssets, before_);

        expectedRemaining[id] = remaining;
        expectedStatus[id] = remaining == 0 ? ExitStatus.Filled : ExitStatus.Open;
        sumFilledAssets += fillAssets;
        sumReceiverPaid += receiverPaid;
        sumRewardPaid += rewardPaid;
        sumServicePaid += servicePaid;
        fillCount += 1;
        if (before_.request.maxShareBurn != 0) protectedFillCount += 1;
    }

    // ---
    // ACTIONS
    // ---

    /// @dev A lender deposits fresh assets, approves the book for the whole resulting balance, and places an
    ///      asset-native exit with a valid ramp + deadline.
    function place(
        uint256 lenderSeed,
        uint256 depositAmt,
        uint256 assetsSeed,
        uint256 startRate,
        uint256 endRate,
        uint256 rampStart,
        uint256 rampEnd,
        uint256 deadlineSeed
    ) external {
        address a = _lender(lenderSeed);
        if (BOOK.paused()) {
            PriorityRamp memory zeroRamp;
            uint256 lastId = BOOK.lastRequestId();
            vm.prank(a);
            (bool success,) = address(BOOK)
                .call(
                    abi.encodeWithSelector(
                        BOOK.placeExitRequest.selector, VAULT, 1, a, 0, 0, zeroRamp, block.timestamp + 1
                    )
                );
            assertFalse(success, "paused placement must revert");
            assertEq(BOOK.lastRequestId(), lastId, "paused placement cannot append");
            pausedPlacementAttempts += 1;
            return;
        }

        depositAmt = bound(depositAmt, 1 ether, 1_000_000 ether);
        _mint(a, depositAmt);

        vm.startPrank(a);
        ASSET.approve(address(VAULT), depositAmt);
        uint256 minted = VAULT.deposit(depositAmt, a);
        // Approve the entire balance so concurrent requests from this lender all keep their backing check.
        VAULT.approve(address(BOOK), VAULT.balanceOf(a));
        vm.stopPrank();

        if (minted == 0) return;
        assetsSeed = bound(assetsSeed, 1, depositAmt);
        uint256 requiredShares = VAULT.previewWithdraw(assetsSeed);
        if (requiredShares > VAULT.balanceOf(a) || requiredShares > VAULT.allowance(a, address(BOOK))) return;
        uint256 maxShareBurn = lenderSeed % 2 == 0 ? 0 : requiredShares;

        // Valid ramp: endRate in [0, MAX_PRIORITY_FEE]; startRate <= endRate; rampStart <= rampEnd; and
        // rampEnd must leave room before the deadline.
        endRate = bound(endRate, 0, MAX_PRIORITY_FEE);
        startRate = bound(startRate, 0, endRate);
        rampEnd = bound(rampEnd, 0, MAX_LIFETIME - 1);
        rampStart = bound(rampStart, 0, rampEnd);
        uint256 minFillAssets = bound(deadlineSeed, 0, assetsSeed * 2);
        // deadline in (now + rampEnd, now + MAX_LIFETIME].
        deadlineSeed = bound(deadlineSeed, block.timestamp + rampEnd + 1, block.timestamp + MAX_LIFETIME);

        PriorityRamp memory ramp =
            PriorityRamp({startRate: startRate, endRate: endRate, rampStart: rampStart, rampEnd: rampEnd});

        vm.prank(a);
        uint256 id = BOOK.placeExitRequest(VAULT, assetsSeed, a, minFillAssets, maxShareBurn, ramp, deadlineSeed);
        _sync(id);
    }

    /// @dev The filler selects an exact request debit. When requested, it independently deposits into the source
    ///      before calling fill; the liquid reward is routed to a distinct recipient.
    function fill(uint256 idSeed, uint256 fillAssets, bool prepareLiquidity) external {
        uint256 id = _liveId(idSeed);
        if (id == 0) return;

        Request memory r = BOOK.getExitRequest(id);
        bool wasPaused = BOOK.paused();
        uint256 minFillAssets = r.assetsRemaining <= r.minFillAssets ? r.assetsRemaining : Math.max(r.minFillAssets, 1);
        fillAssets = bound(fillAssets, minFillAssets, r.assetsRemaining);
        if (prepareLiquidity && !wasPaused) {
            _mint(FILLER, fillAssets);
            vm.startPrank(FILLER);
            ASSET.approve(address(VAULT), fillAssets);
            VAULT.deposit(fillAssets, FILLER);
            vm.stopPrank();
        }

        FillSnapshot memory before_ = _snapshot(r);
        bool success = _callFill(id, fillAssets);

        if (success) {
            assertFalse(wasPaused, "paused fill cannot succeed");
            _recordSuccessfulFill(id, fillAssets, before_);
        } else {
            _assertRollback(id, before_);
            if (wasPaused) pausedFillFailures += 1;
        }
    }

    /// @dev Realize source loss after placement and prove that max-share protection rolls back the request debit
    ///      and vault withdrawal.
    function attemptLateShareFailure(uint256 idSeed, uint256 fillAssets) external {
        if (BOOK.paused()) return;
        uint256 id = _protectedLiveId(idSeed);
        if (id == 0) return;

        Request memory r = BOOK.getExitRequest(id);
        uint256 minFillAssets = r.assetsRemaining <= r.minFillAssets ? r.assetsRemaining : Math.max(r.minFillAssets, 1);
        fillAssets = bound(fillAssets, minFillAssets, r.assetsRemaining);
        uint256 allocated = Math.min(ASSET.balanceOf(address(VAULT)) / 4, VAULT.totalAssets() / 10);
        if (allocated == 0) return;
        IAllocatableVault(address(VAULT)).allocate(allocated);
        IAllocatableVault(address(VAULT)).realizeLoss(allocated);

        uint256 maximum = Math.mulDiv(r.maxShareBurn, fillAssets, r.assetsTotal, Math.Rounding.Ceil);
        uint256 sharesBurned = VAULT.previewWithdraw(fillAssets);
        if (
            sharesBurned <= maximum || sharesBurned > VAULT.balanceOf(r.owner)
                || VAULT.maxWithdraw(r.owner) < fillAssets
        ) return;

        FillSnapshot memory before_ = _snapshot(r);
        bool success = _callFill(id, fillAssets);

        assertFalse(success, "over-limit burn must revert after withdrawal");
        _assertRollback(id, before_);
        lateShareFailureCount += 1;
    }

    /// @dev The owner cancels a random open request, including one past its deadline.
    function cancel(uint256 idSeed) external {
        uint256 id = _openId(idSeed);
        if (id == 0) return;
        address owner = BOOK.getExitRequest(id).owner;
        vm.prank(owner);
        BOOK.cancelExitRequest(id);

        expectedRemaining[id] = 0;
        expectedStatus[id] = ExitStatus.Cancelled;
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

    /// @dev Probe a closed or expired row directly: no preview is involved and success is never permitted.
    function attemptUnavailableFill(uint256 idSeed) external {
        uint256 id = _unavailableId(idSeed);
        if (id == 0) return;

        Request memory r = BOOK.getExitRequest(id);
        uint256 fillAssets = r.assetsRemaining == 0 ? 1 : r.assetsRemaining;
        FillSnapshot memory before_ = _snapshot(r);
        bool success = _callFill(id, fillAssets);

        assertFalse(success, "closed or expired fill must revert");
        _assertRollback(id, before_);
        unavailableFillAttempts += 1;
        if (r.status == ExitStatus.Open) expiredFillFailures += 1;
        else closedFillFailures += 1;
    }

    function allocateLiquidity(uint256 amount) external {
        uint256 idleAssets = ASSET.balanceOf(address(VAULT));
        if (idleAssets == 0) return;
        IAllocatableVault(address(VAULT)).allocate(bound(amount, 1, idleAssets));
    }

    function setPaused(bool shouldPause) external {
        if (shouldPause) BOOK.pause();
        else BOOK.resume();
    }
}
