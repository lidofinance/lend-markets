// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IMorpho, Id, MarketParams, Position} from "@lido-lend/src/interfaces/IMorpho.sol";
import {MorphoBalancesLib} from "@lido-lend/src/libraries/periphery/MorphoBalancesLib.sol";
import {SharesMathLib} from "@lido-lend/src/libraries/SharesMathLib.sol";

import {MorphoExitBook} from "../../src/periphery/MorphoExitBook.sol";
import {ExitBookBase} from "../../src/periphery/ExitBookBase.sol";
import {IExitBook} from "../../src/interfaces/IExitBook.sol";
import {Request, ExitStatus, PriorityRamp, RequestPreview} from "../../src/types/ExitBookTypes.sol";
import {WAD} from "../../src/libs/Constants.sol";

import {LidoLendSetup} from "../setup/LidoLendSetup.sol";
import {Market} from "../setup/Types.sol";
import {MarketActions} from "../setup/MarketActions.sol";
import {MockERC20} from "../setup/Mocks.sol";

/// @notice L2 scenario coverage for `MorphoExitBook` — the Direct-mode exit book over a LidoLend/Morpho
///         supply position. Built on the `new`-based `LidoLendSetup` (one core, one market). The lender's
///         backing is its CORE supply position (not a vault share); the book is authorized on the core to
///         withdraw on the lender's behalf at fill time. Every payout is recomputed independently from the
///         on-chain full-request quote, the previewed `assetsOut`, the ramp rate, and `serviceFee`
///         (mirrors `ExitBookFeeSplit.t.sol`): owed/fee/fillerGross/serviceCut/lenderAssets are derived and
///         `assertEq`'d, with the three legs reconstructing `assetsOut` exactly.
contract MorphoExitBookTest is LidoLendSetup {
    using MarketActions for Market;
    using SharesMathLib for uint256;

    uint256 internal constant MAX_LIFETIME = 30 days;
    uint256 internal constant SERVICE_FEE = 0.05e18; // 5% cut of filler gross (WAD)

    MorphoExitBook internal book;
    address internal feeRecipient = address(0xFEE);

    function setUp() public {
        MockERC20 loan = new MockERC20("Loan", "LOAN", 18);
        MockERC20 collateral = new MockERC20("Collateral", "COLL", 18);
        _deployProtocol(_defaultConfig(address(loan), address(collateral), address(collateral)));

        book = new MorphoExitBook(address(protocol.core), address(this), MAX_LIFETIME);
        book.grantRole(book.ALLOWLIST_MANAGER_ROLE(), address(this));
        book.grantRole(book.FEE_MANAGER_ROLE(), address(this));
        book.setServiceFee(feeRecipient, SERVICE_FEE);
        book.setMarketAllowed(_m().params, true);
    }

    function _m() internal view returns (Market storage) {
        return protocol.markets[0];
    }

    // ---
    // HELPERS
    // ---

    function _ramp() internal pure returns (PriorityRamp memory) {
        return PriorityRamp({startRate: 0.02e18, endRate: 0.08e18, rampStart: 1 hours, rampEnd: 1 days});
    }

    /// @dev Lender supplies `amount` of the loan token DIRECTLY into the core supply position and authorizes
    ///      the book to manage it. Returns the supply shares it received.
    function _lenderSupply(address lender, uint256 amount) internal returns (uint256 shares) {
        Market storage m = _m();
        _fund(m.loanToken, lender, amount);

        vm.startPrank(lender);
        m.loanToken.approve(address(m.core), amount);
        (, shares) = m.core.supply(m.params, amount, 0, lender, "");
        m.core.setAuthorization(address(book), true);
        vm.stopPrank();

        assertEq(m.core.position(m.id, lender).supplyShares, shares, "supply: shares credited to position");
    }

    /// @dev Loan assets `shares` of supply are worth right now — the request is sized in assets.
    function _quote(uint256 shares) internal view returns (uint256) {
        Market storage m = _m();
        (uint256 totalSupplyAssets, uint256 totalSupplyShares,,) =
            MorphoBalancesLib.expectedMarketBalances(m.core, m.params);
        return shares.toAssetsDown(totalSupplyAssets, totalSupplyShares);
    }

    /// @dev Place for the position `shares` are worth, with a minimum single-fill size also given in shares.
    ///      The book takes assets now, so the helper quotes both back; the round trip may shave a share, which is
    ///      fine for size-agnostic assertions. `type(uint256).max` is passed through unquoted — it is the sentinel
    ///      that demands a single closing fill.
    function _place(address lender, uint256 shares, uint256 minFillShares) internal returns (uint256 id) {
        uint256 assets = _quote(shares);
        uint256 minFillAssets = minFillShares == type(uint256).max ? minFillShares : _quote(minFillShares);
        vm.prank(lender);
        id = book.placeExitRequest(_m().id, assets, lender, minFillAssets, _ramp(), block.timestamp + MAX_LIFETIME);
    }

    /// @dev Forge a malformed but representable market price where the lender's full share amount quotes to zero.
    ///      This reaches the placement guard without relying on an economically realistic share rate.
    function _forceSupplyQuoteZero() internal {
        Market storage m = _m();
        bytes32 base = keccak256(abi.encode(Id.unwrap(m.id), uint256(3)));
        vm.store(address(m.core), base, bytes32((uint256(1e36) << 128) | uint256(1)));

        assertEq(m.core.market(m.id).totalSupplyAssets, 1, "slot check: TSA");
        assertEq(m.core.market(m.id).totalSupplyShares, 1e36, "slot check: TSS");
    }

    function _priorityRate(PriorityRamp memory ramp, uint256 elapsed) internal pure returns (uint256) {
        if (elapsed < ramp.rampStart) return ramp.startRate;
        if (elapsed >= ramp.rampEnd) return ramp.endRate;
        return
            ramp.startRate + (ramp.endRate - ramp.startRate) * (elapsed - ramp.rampStart)
                / (ramp.rampEnd - ramp.rampStart);
    }

    struct Split {
        uint256 lenderAssets;
        uint256 fillerFee;
        uint256 serviceCut;
        uint256 assetsOut;
    }

    /// @dev Independent cumulative-quote recompute, mirroring `ExitBookBase.fillExitRequest`.
    function _expectedSplit(
        uint256 quotedAssets,
        uint256 sizeTotal,
        uint256 sizeRemaining,
        uint256 filledShares,
        uint256 assetsOut,
        uint256 rate,
        uint256 serviceFee
    ) internal pure returns (Split memory s) {
        uint256 filledBefore = sizeTotal - sizeRemaining;
        uint256 owedBefore = Math.mulDiv(quotedAssets, filledBefore, sizeTotal);
        uint256 owedAfter = Math.mulDiv(quotedAssets, filledBefore + filledShares, sizeTotal);
        uint256 owed = Math.min(owedAfter - owedBefore, assetsOut);
        uint256 fee = Math.mulDiv(owed, rate, WAD);
        uint256 fillerGross = (assetsOut - owed) + fee;
        s.serviceCut = Math.mulDiv(fillerGross, serviceFee, WAD);
        s.fillerFee = fillerGross - s.serviceCut;
        s.lenderAssets = owed - fee;
        s.assetsOut = assetsOut;
    }

    /// @dev Fill request `id` (filler brings no liquidity) and assert the exact three-way split + conservation.
    ///      `elapsed` is the time since placement (sets the ramp rate). Reads the placement quote and
    ///      `filledShares`/`assetsOut` from the contract's own preview, then recomputes the split.
    function _fillAndAssert(uint256 id, uint256 elapsed) internal {
        Market storage m = _m();
        vm.warp(block.timestamp + elapsed);

        RequestPreview memory pv = book.previewFill(id);
        Request memory request = pv.request;
        Split memory s = _expectedSplit(
            request.quotedAssets,
            request.sizeTotal,
            request.sizeRemaining,
            pv.filledShares,
            pv.assetsOut,
            _priorityRate(_ramp(), block.timestamp - request.createdAt),
            SERVICE_FEE
        );

        address lender = book.getExitRequest(id).owner;
        uint256[3] memory pre = [
            m.loanToken.balanceOf(lender), m.loanToken.balanceOf(address(0x2000)), m.loanToken.balanceOf(feeRecipient)
        ];

        vm.prank(address(0x2000));
        book.fillExitRequest(id, 0, 0);

        uint256 lenderGot = m.loanToken.balanceOf(lender) - pre[0];
        uint256 fillerGot = m.loanToken.balanceOf(address(0x2000)) - pre[1];
        uint256 feeGot = m.loanToken.balanceOf(feeRecipient) - pre[2];

        assertEq(lenderGot, s.lenderAssets, "lender share exact");
        assertEq(fillerGot, s.fillerFee, "filler share exact");
        assertEq(feeGot, s.serviceCut, "service cut exact");
        assertEq(lenderGot + fillerGot + feeGot, s.assetsOut, "three-way conservation == assetsOut");

        // The book never holds anything between fills.
        assertEq(m.loanToken.balanceOf(address(book)), 0, "book holds nothing post-fill");
    }

    /// @dev Borrower posts collateral, matures it, and borrows `amount` — drains idle liquidity from the market.
    function _borrowOut(address borrower, uint256 amount) internal {
        Market storage m = _m();
        uint256 collat = amount * 1e36 / oraclePrice * 2; // over-collateralized at the seeded price
        _fund(m.collateralToken, borrower, collat);
        m.supplyCollateral(borrower, collat);
        m.activateCollateral();
        m.borrow(borrower, amount);
    }

    function _repayAndFillRemainder(uint256 id, address borrower) internal {
        Market storage m = _m();
        uint256 borrowShares = m.core.position(m.id, borrower).borrowShares;
        _fund(m.loanToken, borrower, m.repayAssets(borrowShares));
        m.repay(borrower, borrowShares);

        _fillAndAssert(id, 0);
    }

    // ---
    // G7 — full fill pushes payouts
    // ---

    /// @dev Supply 10e18, authorize, place full, fill: no borrower so idle == full supply -> full fill.
    ///      Position supply shares drop to zero, exact 3-way split + conservation, book balance 0.
    function test_fill_pushesPayouts() public {
        Market storage m = _m();
        address lender = _actor("lender");

        uint256 shares = _lenderSupply(lender, 10 ether);
        uint256 id = _place(lender, shares, type(uint256).max);

        // Preview before fill: full position is fillable (idle == full supply).
        RequestPreview memory pv = book.previewFill(id);
        assertEq(pv.filledShares, shares, "full fill available");

        _fillAndAssert(id, 12 hours); // mid-ramp

        assertEq(m.core.position(m.id, lender).supplyShares, 0, "supply position drained");
        assertEq(uint8(book.getExitRequest(id).status), uint8(ExitStatus.Filled), "request filled");
    }

    // ---
    // G8 — place against a market that was never allowed
    // ---

    /// @dev Placing against a market the fresh book never allow-listed reverts, even though the lender authorized it on
    /// core.
    function testRevert_place_marketNotAllowed() public {
        // A fresh book with NO setMarketAllowed call.
        MorphoExitBook fresh = new MorphoExitBook(address(protocol.core), address(this), MAX_LIFETIME);
        address lender = _actor("lender");

        Market storage m = _m();
        _fund(m.loanToken, lender, 10 ether);
        vm.startPrank(lender);
        m.loanToken.approve(address(m.core), 10 ether);
        (, uint256 shares) = m.core.supply(m.params, 10 ether, 0, lender, "");
        m.core.setAuthorization(address(fresh), true);

        uint256 exitAssets = _quote(shares);
        vm.expectRevert(MorphoExitBook.MarketNotAllowed.selector);
        fresh.placeExitRequest(m.id, exitAssets, lender, 0, _ramp(), block.timestamp + MAX_LIFETIME);
        vm.stopPrank();
    }

    // ---
    // G9 — supplied but never authorized the book on Morpho
    // ---

    /// @dev Supplying to core without authorizing the book to manage the position reverts at placement.
    function testRevert_place_notAuthorized() public {
        Market storage m = _m();
        address lender = _actor("lender");

        _fund(m.loanToken, lender, 10 ether);
        vm.startPrank(lender);
        m.loanToken.approve(address(m.core), 10 ether);
        (, uint256 shares) = m.core.supply(m.params, 10 ether, 0, lender, "");
        // NOTE: no setAuthorization.

        uint256 exitAssets = _quote(shares);
        vm.expectRevert(MorphoExitBook.NotAuthorizedOnMorpho.selector);
        book.placeExitRequest(m.id, exitAssets, lender, 0, _ramp(), block.timestamp + MAX_LIFETIME);
        vm.stopPrank();
    }

    // ---
    // G10 — authorized, but placing more than the backing
    // ---

    /// @dev Placement takes the lender at their word: an amount past what their position backs is accepted, and
    ///      the fill closes only what it does back.
    function test_place_acceptsMoreThanThePositionBacks() public {
        address lender = _actor("lender");
        uint256 shares = _lenderSupply(lender, 10 ether);

        vm.prank(lender);
        uint256 id = book.placeExitRequest(_m().id, 100 ether, lender, 0, _ramp(), block.timestamp + MAX_LIFETIME);
        assertGt(book.getExitRequest(id).sizeTotal, shares, "request is larger than the position");

        assertEq(book.previewFill(id).filledShares, shares, "only the backed part is fillable");
    }

    /// @dev A zero full-request quote would pay the lender nothing on every fill, so placement rejects it even
    ///      when the request is otherwise authorized and fully backed.
    function testRevert_place_amountBuysNoShares() public {
        address lender = _actor("lender");
        uint256 shares = _lenderSupply(lender, 10 ether);
        _forceSupplyQuoteZero();

        uint256 exitAssets = _quote(shares);
        vm.prank(lender);
        vm.expectRevert(ExitBookBase.ZeroShares.selector);
        book.placeExitRequest(_m().id, exitAssets, lender, 0, _ramp(), block.timestamp + MAX_LIFETIME);
    }

    /// @dev The Morpho request stores the exact full-share quote derived from the live market totals.
    function testFuzz_place_quoteMatchesSupplyShareConversion(uint128 amountSeed) public {
        Market storage m = _m();
        address lender = _actor("lender");
        uint256 amount = bound(amountSeed, 1, 1e24);
        uint256 shares = _lenderSupply(lender, amount);

        (uint256 totalSupplyAssets, uint256 totalSupplyShares,,) =
            MorphoBalancesLib.expectedMarketBalances(m.core, m.params);
        uint256 expectedQuote = shares.toAssetsDown(totalSupplyAssets, totalSupplyShares);

        uint256 id = _place(lender, shares, 0);
        assertEq(book.getExitRequest(id).quotedAssets, expectedQuote, "exact Morpho quote");
    }

    // ---
    // G11 — setMarketAllowed on a never-created market reverts (on disallow too)
    // ---

    /// @dev setMarketAllowed on a never-created market reverts on both allow and disallow (live-market check always
    /// runs).
    function testRevert_setMarketAllowed_marketNotCreated() public {
        Market storage m = _m();
        // Real tokens, bogus oracle/irm/lltv -> an id that was never created on the core.
        MarketParams memory ghost = MarketParams({
            loanToken: address(m.loanToken),
            collateralToken: address(m.collateralToken),
            oracle: address(0xDEAD),
            irm: address(0xBEEF),
            lltv: 0.5e18
        });

        vm.expectRevert(MorphoExitBook.MarketNotCreated.selector);
        book.setMarketAllowed(ghost, true);

        // Fires on disallow too (the live-market check runs regardless of `allowed`).
        vm.expectRevert(MorphoExitBook.MarketNotCreated.selector);
        book.setMarketAllowed(ghost, false);
    }

    // ---
    // G12 — disallowing a market blocks new places but not the fill of an in-flight request
    // ---

    /// @dev Disallowing a market blocks new placements but an in-flight request still fills (fill uses stored params).
    function test_disallowMarket_blocksPlaceNotFill() public {
        Market storage m = _m();
        address lender = _actor("lender");

        uint256 shares = _lenderSupply(lender, 10 ether);
        uint256 id = _place(lender, shares, type(uint256).max); // placed while allowed

        // Disallow the market.
        book.setMarketAllowed(m.params, false);
        assertFalse(book.isMarketAllowed(m.id), "market disallowed");

        // A NEW place now reverts.
        address lender2 = _actor("lender2");
        uint256 shares2 = _lenderSupply(lender2, 5 ether);
        uint256 exitAssets = _quote(shares2);
        vm.prank(lender2);
        vm.expectRevert(MorphoExitBook.MarketNotAllowed.selector);
        book.placeExitRequest(m.id, exitAssets, lender, 0, _ramp(), block.timestamp + MAX_LIFETIME);

        // BUT the in-flight request still fills (fill uses stored params, never re-checks isMarketAllowed).
        _fillAndAssert(id, 12 hours);
        assertEq(uint8(book.getExitRequest(id).status), uint8(ExitStatus.Filled), "in-flight request still fills");
    }

    // ---
    // G13 — previewFill and fill reflect a revoked authorization
    // ---

    /// @dev Revoking the book's core authorization drops previewFill to zero and makes the fill revert.
    function test_previewFill_reflectsDeauthorize() public {
        Market storage m = _m();
        address lender = _actor("lender");

        uint256 shares = _lenderSupply(lender, 10 ether);
        uint256 id = _place(lender, shares, type(uint256).max);

        // Authorized: there is something fillable.
        assertGt(book.previewFill(id).filledShares, 0, "authorized: fillable");

        // Revoke authorization -> nothing fillable, fill reverts.
        vm.prank(lender);
        m.core.setAuthorization(address(book), false);

        assertEq(book.previewFill(id).filledShares, 0, "deauthorized: nothing fillable");

        vm.prank(address(0x2000));
        vm.expectRevert(ExitBookBase.NoFillableShares.selector);
        book.fillExitRequest(id, 0, 0);
    }

    // ---
    // BONUS — partial fill when a borrower drains idle below the owed
    // ---

    /// @dev A borrower drains most idle liquidity so `idleAssets < owed`. The request first fills the partial
    ///      idle amount and stays Open. Once the borrower repays, the final fill closes it and receives the
    ///      cumulative quote remainder; both splits conserve exactly.
    function test_partialFill_borrowerDrainsIdle() public {
        Market storage m = _m();
        address lender = _actor("lender");
        address borrower = _actor("borrower");

        uint256 shares = _lenderSupply(lender, 100 ether);
        uint256 id = _place(lender, shares, 0); // partial fills allowed
        uint256 createdAt = book.getExitRequest(id).createdAt;

        // Borrower draws 90 ether, leaving ~10 ether idle. (`_borrowOut` warps past the activation delay.)
        _borrowOut(borrower, 90 ether);

        RequestPreview memory pv = book.previewFill(id);
        assertGt(pv.filledShares, 0, "some idle is fillable");
        assertLt(pv.filledShares, shares, "but less than the full position");

        uint256[3] memory pre = [
            m.loanToken.balanceOf(lender), m.loanToken.balanceOf(address(0x2000)), m.loanToken.balanceOf(feeRecipient)
        ];

        Request memory requestBefore = book.getExitRequest(id);

        vm.prank(address(0x2000));
        book.fillExitRequest(id, 0, 0);

        uint256 lenderGot = m.loanToken.balanceOf(lender) - pre[0];
        uint256 fillerGot = m.loanToken.balanceOf(address(0x2000)) - pre[1];
        uint256 feeGot = m.loanToken.balanceOf(feeRecipient) - pre[2];

        // The `filledShares` is debited atomically so it is exactly the preview; but the loan token's
        // share-to-asset rate accrues inside the withdraw, so `assetsOut` is measured from the actual legs,
        // not the pre-fill preview. Recompute every leg from that measured `assetsOut` and assert exact.
        uint256 assetsOut = lenderGot + fillerGot + feeGot;
        uint256 rate = _priorityRate(_ramp(), block.timestamp - createdAt);
        Split memory s = _expectedSplit(
            requestBefore.quotedAssets,
            requestBefore.sizeTotal,
            requestBefore.sizeRemaining,
            pv.filledShares,
            assetsOut,
            rate,
            SERVICE_FEE
        );

        assertEq(lenderGot, s.lenderAssets, "partial: lender share exact");
        assertEq(fillerGot, s.fillerFee, "partial: filler share exact");
        assertEq(feeGot, s.serviceCut, "partial: service cut exact");
        assertEq(lenderGot + fillerGot + feeGot, s.assetsOut, "partial: conservation == assetsOut");

        // Request stays Open, size reduced by exactly the filled shares.
        Request memory req = book.getExitRequest(id);
        assertEq(uint8(req.status), uint8(ExitStatus.Open), "partial: request stays open");
        assertEq(
            uint256(requestBefore.sizeRemaining) - req.sizeRemaining,
            pv.filledShares,
            "partial: size reduced by filled shares"
        );

        _repayAndFillRemainder(id, borrower);
        assertEq(
            uint8(book.getExitRequest(id).status), uint8(ExitStatus.Filled), "final cumulative fill closes request"
        );
    }

    // ---
    // BONUS — filler supplies liquidity to enable the fill, ends with a supply position
    // ---

    /// @dev Borrower drains ALL idle, so without liquidity nothing is fillable. The filler passes
    ///      `depositAssets`: `_depositLiquidity` supplies it to the core on the filler's behalf (the filler
    ///      ends with a supply position), which then lets the withdraw pull the lender's position out.
    function test_fillWithLiquidity_fillerGainsSupplyPosition() public {
        Market storage m = _m();
        address lender = _actor("lender");
        address borrower = _actor("borrower");
        address filler = _actor("filler");

        uint256 shares = _lenderSupply(lender, 100 ether);
        uint256 id = _place(lender, shares, 0);

        // Borrower drains essentially all idle liquidity.
        _borrowOut(borrower, 100 ether);

        // No idle -> nothing fillable from the position alone.
        assertEq(book.previewFill(id).filledShares, 0, "no idle: nothing fillable without liquidity");

        // Filler brings liquidity to back the fill.
        uint256 deposit = 40 ether;
        _fund(m.loanToken, filler, deposit);
        vm.prank(filler);
        m.loanToken.approve(address(book), deposit);

        uint256 lenderBefore = m.loanToken.balanceOf(lender);

        vm.prank(filler);
        book.fillExitRequest(id, deposit, 0);

        // The filler now holds a supply position credited from its deposit.
        assertGt(m.core.position(m.id, filler).supplyShares, 0, "filler gained a supply position");
        // The lender received their owed payout from the freshly-supplied idle.
        assertGt(m.loanToken.balanceOf(lender), lenderBefore, "lender paid out from filler liquidity");
        // The book holds nothing afterward.
        assertEq(m.loanToken.balanceOf(address(book)), 0, "book holds nothing post-fill");
    }

    // ---
    // L1 — full-fill must not be rejected by asset->share rounding at the liquidity boundary
    // ---

    /// @dev A fullFillOnly request sized at the exact-share liquidity boundary. The core's exact-share withdraw
    ///      admits `shares` when `toAssetsDown(shares) <= idle`, so the whole position would come out. Capping
    ///      availability at `toSharesDown(idle)` rounds strictly below that boundary and wrongly reported nothing
    ///      fillable (reverting the fill). The full request must be fillable in one shot.
    /// @dev The core's exact-share withdraw quotes shares down to assets, so it releases every share up to
    ///      `sMax` — the largest share count whose down-quote still fits idle liquidity — which sits about
    ///      `VIRTUAL_SHARES` above `toSharesDown(idle)`. A request landing in that band must be reported fully
    ///      fillable, not capped a share short. Once interest has accrued the assets/shares round trip loses a
    ///      unit, which is what lets an asset-denominated size land there at all.
    function test_fullFill_atLiquidityBoundary_notRejectedByRounding() public {
        Market storage m = _m();
        address lender = _actor("lender");

        _lenderSupply(lender, 100 ether);
        _borrowOut(_actor("borrower"), 90 ether); // drain idle well below the position
        vm.warp(block.timestamp + 30 days); // accrue, so shares are no longer a clean multiple of assets

        (uint256 tsa, uint256 tss, uint256 tba,) =
            MorphoBalancesLib.expectedMarketBalances(IMorpho(address(m.core)), m.params);
        uint256 idle = tsa - tba;
        uint256 cap = idle.toSharesDown(tsa, tss);

        vm.prank(lender);
        uint256 id =
            book.placeExitRequest(m.id, idle + 1, lender, type(uint256).max, _ramp(), block.timestamp + MAX_LIFETIME);

        uint256 size = book.getExitRequest(id).sizeTotal;
        assertGt(size, cap, "the request sits above the naive liquidity cap");
        assertLe(size.toAssetsDown(tsa, tss), idle, "yet its down-quote still fits idle, so the core releases it");

        assertEq(book.previewFill(id).filledShares, size, "full request fillable, not understated");

        uint256 positionBefore = m.core.position(m.id, lender).supplyShares;
        vm.prank(address(0x2000));
        book.fillExitRequest(id, 0, 0);
        assertEq(positionBefore - m.core.position(m.id, lender).supplyShares, size, "the whole request came out");
        assertEq(book.getExitRequest(id).sizeRemaining, 0, "closed in one fill");
    }

    /// @dev The same boundary with a partial-fill request. The old `toSharesDown(idle)` cap would fill only
    ///      `available` and leave the sub-1-asset remainder as dust (request stays Open). The whole `sMax` fits
    ///      idle, so the fill now clears it in one shot with nothing left over.
    function test_partialFill_atLiquidityBoundary_leavesNoDust() public {
        Market storage m = _m();
        address lender = _actor("lender");
        address borrower = _actor("borrower");

        uint256 ownerShares = _lenderSupply(lender, 100 ether);
        _borrowOut(borrower, 90 ether);

        (uint256 tsa, uint256 tss, uint256 tba,) =
            MorphoBalancesLib.expectedMarketBalances(IMorpho(address(m.core)), m.params);
        uint256 idle = tsa - tba;
        uint256 available = idle.toSharesDown(tsa, tss);
        uint256 sMax = ((idle + 1) * (tss + 1e6) - 1) / (tsa + 1);
        assertGt(sMax, available, "rounding gap exists at the boundary");
        assertLe(sMax, ownerShares, "owner backs the full request");

        uint256 id = _place(lender, sMax, 0); // partial fills allowed

        vm.prank(address(0x2000));
        book.fillExitRequest(id, 0, 0);

        Request memory req = book.getExitRequest(id);
        assertEq(req.sizeRemaining, 0, "no dust left: full sMax filled in one shot");
        assertEq(uint8(req.status), uint8(ExitStatus.Filled), "request filled");
    }

    /// @dev Constructing the book with a zero core (Morpho) address reverts.
    function testRevert_constructor_zeroMorpho() public {
        vm.expectRevert(MorphoExitBook.ZeroMorpho.selector);
        new MorphoExitBook(address(0), address(this), MAX_LIFETIME);
    }

    /// @dev marketParamsOf(id) returns the full market params of the request's market.
    function test_marketParamsOf_returnsRequestMarket() public {
        address lender = address(0xA11CE);
        uint256 shares = _lenderSupply(lender, 10 ether);
        uint256 id = _place(lender, shares, 0);

        MarketParams memory p = book.marketParamsOf(id);
        assertEq(p.loanToken, _m().params.loanToken, "loan token matches the request market");
        assertEq(p.collateralToken, _m().params.collateralToken, "collateral token");
        assertEq(p.oracle, _m().params.oracle, "oracle");
        assertEq(p.irm, _m().params.irm, "irm");
        assertEq(p.lltv, _m().params.lltv, "lltv");
    }
}
