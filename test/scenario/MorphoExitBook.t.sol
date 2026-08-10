// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {MarketParams} from "@lido-lend/src/interfaces/IMorpho.sol";
import {MorphoBalancesLib} from "@lido-lend/src/libraries/periphery/MorphoBalancesLib.sol";
import {SharesMathLib} from "@lido-lend/src/libraries/SharesMathLib.sol";

import {MorphoExitBook} from "../../src/periphery/MorphoExitBook.sol";
import {ExitBookBase} from "../../src/periphery/ExitBookBase.sol";
import {Request, ExitStatus, PriorityRamp} from "../../src/types/ExitBookTypes.sol";
import {WAD} from "../../src/libs/Constants.sol";
import {PausableUntil} from "../../src/utils/PausableUntil.sol";

import {LidoLendSetup} from "../setup/LidoLendSetup.sol";
import {Market} from "../setup/Types.sol";
import {MarketActions} from "../setup/MarketActions.sol";
import {MockERC20, MockPriceOracle} from "../setup/Mocks.sol";

/// @notice L2 scenario coverage for `MorphoExitBook` — the Direct-mode exit book over a LidoLend/Morpho
///         supply position. The lender's backing is its CORE supply position (not a vault share); the book is
///         authorized on the core to withdraw exact assets from the lender's position at fill time.
contract MorphoExitBookTest is LidoLendSetup {
    using MarketActions for Market;
    using SharesMathLib for uint256;

    uint256 internal constant MAX_LIFETIME = 30 days;
    uint256 internal constant SERVICE_FEE = 0.05e18; // 5% cut of the priority fee (WAD)
    uint256 internal constant PRIORITY_FEE = 0.04e18;

    MorphoExitBook internal book;
    address internal feeRecipient = address(0xFEE);
    address internal rewardRecipient = address(0xB0B);

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

    function _flat(uint256 rate) internal pure returns (PriorityRamp memory) {
        return PriorityRamp({startRate: rate, endRate: rate, rampStart: 0, rampEnd: 0});
    }

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

    function _place(address lender, uint256 assets, address receiver, uint256 minFillAssets, PriorityRamp memory ramp)
        internal
        returns (uint256 id)
    {
        vm.prank(lender);
        id = book.placeExitRequest(_m().id, assets, receiver, minFillAssets, 0, ramp, block.timestamp + MAX_LIFETIME);
    }

    function _positionAssets(address lender) internal view returns (uint256 assets) {
        Market storage m = _m();
        (uint256 totalSupplyAssets, uint256 totalSupplyShares,,) =
            MorphoBalancesLib.expectedMarketBalances(m.core, m.params);
        return m.core.position(m.id, lender).supplyShares.toAssetsDown(totalSupplyAssets, totalSupplyShares);
    }

    function _idleAssets() internal view returns (uint256) {
        Market storage m = _m();
        (uint256 totalSupplyAssets,, uint256 totalBorrowAssets,) =
            MorphoBalancesLib.expectedMarketBalances(m.core, m.params);
        return totalSupplyAssets - totalBorrowAssets;
    }

    function _priorityRate(Request memory request) internal view returns (uint256) {
        uint256 elapsed = block.timestamp - request.createdAt;
        if (elapsed < request.rampStart) return request.startRate;
        if (elapsed >= request.rampEnd) return request.endRate;
        return request.startRate + (request.endRate - request.startRate) * (elapsed - request.rampStart)
            / (request.rampEnd - request.rampStart);
    }

    function _fillAndAssert(uint256 id, uint256 fillAssets, address filler) internal {
        Market storage m = _m();
        Request memory requestBefore = book.getExitRequest(id);
        (uint256 totalSupplyAssets, uint256 totalSupplyShares,,) =
            MorphoBalancesLib.expectedMarketBalances(m.core, m.params);
        uint256 sharesToBurn = fillAssets.toSharesUp(totalSupplyAssets, totalSupplyShares);
        uint256 ownerSharesBefore = m.core.position(m.id, requestBefore.owner).supplyShares;
        uint256[3] memory balancesBefore = [
            m.loanToken.balanceOf(requestBefore.receiver),
            m.loanToken.balanceOf(filler),
            m.loanToken.balanceOf(feeRecipient)
        ];

        uint256 priorityFee = Math.mulDiv(fillAssets, _priorityRate(requestBefore), WAD);
        uint256 serviceCut = Math.mulDiv(priorityFee, SERVICE_FEE, WAD);

        vm.prank(filler);
        book.fillExitRequest(id, fillAssets, filler);

        assertEq(
            m.loanToken.balanceOf(requestBefore.receiver) - balancesBefore[0],
            fillAssets - priorityFee,
            "receiver payout"
        );
        assertEq(m.loanToken.balanceOf(filler) - balancesBefore[1], priorityFee - serviceCut, "filler reward");
        assertEq(m.loanToken.balanceOf(feeRecipient) - balancesBefore[2], serviceCut, "service cut");
        assertEq(
            ownerSharesBefore - m.core.position(m.id, requestBefore.owner).supplyShares,
            sharesToBurn,
            "live shares burned"
        );

        Request memory requestAfter = book.getExitRequest(id);
        assertEq(requestBefore.assetsRemaining - requestAfter.assetsRemaining, fillAssets, "exact request debit");
        assertEq(m.loanToken.balanceOf(address(book)), 0, "book retains no assets");
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

    function _repayAll(address borrower) internal {
        Market storage m = _m();
        uint256 borrowShares = m.core.position(m.id, borrower).borrowShares;
        _fund(m.loanToken, borrower, m.repayAssets(borrowShares));
        m.repay(borrower, borrowShares);
    }

    function _realizeBadDebt(address borrower) internal {
        Market storage m = _m();
        MockPriceOracle(address(m.oracle)).setPrice(oraclePrice / 10);
        address keeper = _actor("keeper");
        _fund(m.loanToken, keeper, 1_000 ether);
        m.liquidateBadDebt(keeper, borrower, m.core.position(m.id, borrower).collateral, 0);
    }

    // ---
    // G7 — full fill pushes payouts
    // ---

    /// @dev Supply 10e18, authorize, place full, fill: no borrower so idle == full supply -> full fill.
    ///      Position supply shares drop to zero, exact 3-way split + conservation, book balance 0.
    function test_fill_pushesPayouts() public {
        Market storage m = _m();
        address lender = _actor("lender");
        address receiver = _actor("receiver");
        address filler = _actor("filler");
        uint256 shares = _lenderSupply(lender, 10 ether);
        uint256 id = _place(lender, 10 ether, receiver, 10 ether, _flat(PRIORITY_FEE));

        _fillAndAssert(id, 10 ether, filler);

        assertEq(m.core.position(m.id, lender).supplyShares, 0, "position drained");
        assertGt(shares, 0, "nonzero initial position");
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
        m.core.supply(m.params, 10 ether, 0, lender, "");
        m.core.setAuthorization(address(fresh), true);

        vm.expectRevert(MorphoExitBook.MarketNotAllowed.selector);
        fresh.placeExitRequest(m.id, 10 ether, lender, 0, 0, _flat(0), block.timestamp + MAX_LIFETIME);
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
        m.core.supply(m.params, 10 ether, 0, lender, "");
        // NOTE: no setAuthorization.

        vm.expectRevert(MorphoExitBook.NotAuthorizedOnMorpho.selector);
        book.placeExitRequest(m.id, 10 ether, lender, 0, 0, _flat(0), block.timestamp + MAX_LIFETIME);
        vm.stopPrank();
    }

    // ---
    // G10 — authorized, but placing more than the backing
    // ---

    /// @dev Placing for more assets than the lender's position backs reverts at placement.
    function testRevert_place_insufficientBacking() public {
        address lender = _actor("lender");
        _lenderSupply(lender, 10 ether);

        vm.prank(lender);
        vm.expectRevert(MorphoExitBook.InsufficientBacking.selector);
        book.placeExitRequest(_m().id, 10 ether + 1, lender, 0, 0, _flat(0), block.timestamp + MAX_LIFETIME);
    }

    function testFuzz_place_storesAssetRequestAndEmits(uint128 amountSeed, uint128 assetsSeed, uint128 minFillSeed)
        public
    {
        Market storage m = _m();
        address lender = _actor("lender");
        address receiver = _actor("receiver");
        uint256 amount = bound(amountSeed, 1, 1e24);
        uint256 assets = bound(assetsSeed, 1, amount);
        uint256 minFillAssets = bound(minFillSeed, 0, 2e24);
        _lenderSupply(lender, amount);
        PriorityRamp memory ramp = _ramp();
        uint256 deadline = block.timestamp + MAX_LIFETIME;
        uint256 expectedId = book.lastRequestId() + 1;

        vm.expectEmit(true, true, true, true, address(book));
        emit ExitBookBase.ExitRequested(
            expectedId,
            lender,
            receiver,
            address(m.loanToken),
            assets,
            Math.min(minFillAssets, assets),
            0,
            ramp,
            deadline
        );
        vm.prank(lender);
        uint256 id = book.placeExitRequest(m.id, assets, receiver, minFillAssets, 0, ramp, deadline);
        Request memory request = book.getExitRequest(id);

        assertEq(address(request.asset), address(m.loanToken), "stored asset");
        assertEq(request.receiver, receiver, "stored receiver");
        assertEq(request.assetsTotal, assets, "exact total assets");
        assertEq(request.assetsRemaining, assets, "exact remaining assets");
        assertEq(request.minFillAssets, Math.min(minFillAssets, assets), "minimum capped to total");
    }

    function testRevert_place_maxShareBurnBelowPlacementQuote() public {
        Market storage m = _m();
        address lender = _actor("lender");
        uint256 assets = 10 ether;
        _lenderSupply(lender, assets);
        (uint256 totalSupplyAssets, uint256 totalSupplyShares,,) =
            MorphoBalancesLib.expectedMarketBalances(m.core, m.params);
        uint256 requiredShares = assets.toSharesUp(totalSupplyAssets, totalSupplyShares);

        vm.prank(lender);
        vm.expectRevert(
            abi.encodeWithSelector(ExitBookBase.MaxShareBurnBelowQuote.selector, requiredShares - 1, requiredShares)
        );
        book.placeExitRequest(m.id, assets, lender, 0, requiredShares - 1, _flat(0), block.timestamp + MAX_LIFETIME);
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
        _lenderSupply(lender, 10 ether);
        uint256 id = _place(lender, 10 ether, lender, 0, _flat(0));

        // Disallow the market.
        vm.expectEmit(true, false, false, true, address(book));
        emit MorphoExitBook.MarketAllowedSet(m.id, false);
        book.setMarketAllowed(m.params, false);
        assertFalse(book.isMarketAllowed(m.id), "market disallowed");

        // A NEW place now reverts.
        address lender2 = _actor("lender2");
        _lenderSupply(lender2, 5 ether);
        vm.prank(lender2);
        vm.expectRevert(MorphoExitBook.MarketNotAllowed.selector);
        book.placeExitRequest(m.id, 5 ether, lender2, 0, 0, _flat(0), block.timestamp + MAX_LIFETIME);

        // BUT the in-flight request still fills (fill uses stored params, never re-checks isMarketAllowed).
        _fillAndAssert(id, 10 ether, _actor("filler"));
        assertEq(uint8(book.getExitRequest(id).status), uint8(ExitStatus.Filled), "in-flight request still fills");
    }

    function testRevert_revokedAuthorization_blocksExactFillAndRollsBack() public {
        Market storage m = _m();
        address lender = _actor("lender");
        _lenderSupply(lender, 10 ether);
        uint256 id = _place(lender, 10 ether, lender, 0, _flat(0));
        vm.prank(lender);
        m.core.setAuthorization(address(book), false);

        address filler = _actor("filler");
        vm.prank(filler);
        vm.expectRevert();
        book.fillExitRequest(id, 10 ether, filler);

        assertEq(book.getExitRequest(id).assetsRemaining, 10 ether, "request debit rolled back");
    }

    function testRevert_revokedAuthorization_afterExternalSupplyRollsBackOnlyFill() public {
        Market storage m = _m();
        address lender = _actor("lender");
        address filler = _actor("filler");
        _lenderSupply(lender, 100 ether);
        _borrowOut(_actor("borrower"), 90 ether);
        uint256 id = _place(lender, 40 ether, lender, 0, _flat(0));
        uint256 requiredSupply = 40 ether - _idleAssets();
        assertGt(requiredSupply, 0, "positive external supply required");

        vm.prank(lender);
        m.core.setAuthorization(address(book), false);
        _fund(m.loanToken, filler, requiredSupply);
        vm.startPrank(filler);
        m.loanToken.approve(address(m.core), requiredSupply);
        m.core.supply(m.params, requiredSupply, 0, filler, "");
        vm.stopPrank();

        bytes32 requestBefore = keccak256(abi.encode(book.getExitRequest(id)));
        bytes32 marketBefore = keccak256(abi.encode(m.core.market(m.id)));
        uint256 fillerAssetsBefore = m.loanToken.balanceOf(filler);
        uint256 fillerSharesBefore = m.core.position(m.id, filler).supplyShares;
        uint256 lenderSharesBefore = m.core.position(m.id, lender).supplyShares;

        vm.prank(filler);
        vm.expectRevert(bytes("unauthorized"));
        book.fillExitRequest(id, 40 ether, filler);

        assertEq(keccak256(abi.encode(book.getExitRequest(id))), requestBefore, "request rolled back");
        assertEq(keccak256(abi.encode(m.core.market(m.id))), marketBefore, "fill leaves supplied market state intact");
        assertEq(m.loanToken.balanceOf(filler), fillerAssetsBefore, "fill does not take executor assets");
        assertEq(m.core.position(m.id, filler).supplyShares, fillerSharesBefore, "external position remains intact");
        assertEq(m.core.position(m.id, lender).supplyShares, lenderSharesBefore, "lender shares rolled back");
        assertEq(m.loanToken.balanceOf(address(book)), 0, "book retains no assets");
    }

    function test_partialFill_borrowerDrainsIdle() public {
        address lender = _actor("lender");
        address borrower = _actor("borrower");
        address filler = _actor("filler");
        _lenderSupply(lender, 100 ether);
        _borrowOut(borrower, 90 ether);
        uint256 idleAssets = _idleAssets();
        uint256 tailAssets = 1 ether;
        uint256 id = _place(lender, idleAssets + tailAssets, lender, idleAssets, _flat(0));

        _fillAndAssert(id, idleAssets, filler);
        Request memory request = book.getExitRequest(id);
        assertEq(request.assetsRemaining, tailAssets, "small tail remains");
        assertLt(request.assetsRemaining, request.minFillAssets, "tail below minimum");

        _repayAll(borrower);
        _fillAndAssert(id, tailAssets, filler);
        assertEq(uint8(book.getExitRequest(id).status), uint8(ExitStatus.Filled), "final tail filled");
    }

    function test_externalSupplyThenFill_routesPositionAndRewardIndependently() public {
        Market storage m = _m();
        address lender = _actor("lender");
        address filler = _actor("filler");
        _lenderSupply(lender, 100 ether);
        _borrowOut(_actor("borrower"), 90 ether);
        uint256 id = _place(lender, 40 ether, lender, 0, _flat(PRIORITY_FEE));
        vm.warp(block.timestamp + 20 days);

        uint256 requiredSupply;
        uint256 expectedSupplyShares;
        {
            (uint256 totalSupplyAssets, uint256 totalSupplyShares,,) =
                MorphoBalancesLib.expectedMarketBalances(m.core, m.params);
            requiredSupply = 40 ether - _idleAssets();
            expectedSupplyShares = requiredSupply.toSharesDown(totalSupplyAssets, totalSupplyShares);
        }
        _fund(m.loanToken, filler, requiredSupply + 5 ether);
        uint256[5] memory balancesBefore = [
            m.loanToken.balanceOf(filler),
            m.core.position(m.id, filler).supplyShares,
            m.loanToken.balanceOf(lender),
            m.loanToken.balanceOf(feeRecipient),
            m.loanToken.balanceOf(rewardRecipient)
        ];
        uint256 priorityFee = Math.mulDiv(40 ether, PRIORITY_FEE, WAD);
        uint256 serviceCut = Math.mulDiv(priorityFee, SERVICE_FEE, WAD);

        vm.startPrank(filler);
        m.loanToken.approve(address(m.core), requiredSupply);
        m.core.supply(m.params, requiredSupply, 0, filler, "");
        vm.expectEmit(true, true, true, true, address(book));
        emit ExitBookBase.ExitProcessed(
            id,
            filler,
            rewardRecipient,
            address(m.loanToken),
            40 ether,
            40 ether - priorityFee,
            priorityFee - serviceCut,
            serviceCut
        );
        book.fillExitRequest(id, 40 ether, rewardRecipient);
        vm.stopPrank();

        assertEq(
            m.loanToken.balanceOf(filler), balancesBefore[0] - requiredSupply, "executor funds its chosen strategy"
        );
        assertEq(
            m.core.position(m.id, filler).supplyShares - balancesBefore[1],
            expectedSupplyShares,
            "external supply position credited"
        );
        assertEq(m.core.position(m.id, rewardRecipient).supplyShares, 0, "source position stays with provider");
        assertEq(m.loanToken.balanceOf(lender) - balancesBefore[2], 40 ether - priorityFee, "receiver payout");
        assertEq(m.loanToken.balanceOf(feeRecipient) - balancesBefore[3], serviceCut, "service cut");
        assertEq(
            m.loanToken.balanceOf(rewardRecipient) - balancesBefore[4],
            priorityFee - serviceCut,
            "reward routed separately"
        );
        assertEq(uint8(book.getExitRequest(id).status), uint8(ExitStatus.Filled), "request filled");
    }

    function test_repayPreparesLiquidityWithoutUsingExecutorAssets() public {
        Market storage m = _m();
        address lender = _actor("lender");
        address borrower = _actor("borrower");
        address filler = _actor("filler");
        _lenderSupply(lender, 100 ether);
        _borrowOut(borrower, 90 ether);
        uint256 id = _place(lender, 40 ether, lender, 0, _flat(0));
        _repayAll(borrower);
        uint256 assetsBefore = m.loanToken.balanceOf(filler);
        uint256 sharesBefore = m.core.position(m.id, filler).supplyShares;

        vm.prank(filler);
        book.fillExitRequest(id, 40 ether, filler);

        assertEq(m.loanToken.balanceOf(filler), assetsBefore, "fill does not take executor assets");
        assertEq(m.core.position(m.id, filler).supplyShares, sharesBefore, "fill does not create a source position");
    }

    function testRevert_insufficientSourceLiquidity_rollsBackRequestWithoutUsingExecutorAssets() public {
        Market storage m = _m();
        address lender = _actor("lender");
        address filler = _actor("filler");
        _lenderSupply(lender, 100 ether);
        address borrower = _actor("borrower");
        _borrowOut(borrower, 80 ether);
        uint256 id = _place(lender, 40 ether, lender, 0, _flat(0));
        m.borrow(borrower, 10 ether);
        assertLt(_idleAssets(), 40 ether, "source is illiquid");
        _fund(m.loanToken, filler, 40 ether);
        uint256 assetsBefore = m.loanToken.balanceOf(filler);

        vm.prank(filler);
        vm.expectRevert(bytes("insufficient liquidity"));
        book.fillExitRequest(id, 40 ether, filler);

        assertEq(m.loanToken.balanceOf(filler), assetsBefore, "executor assets are untouched");
        assertEq(book.getExitRequest(id).assetsRemaining, 40 ether, "request debit rolled back");
    }

    function testRevert_insufficientSourceLiquidity_doesNotClipRequestedFill() public {
        address lender = _actor("lender");
        _lenderSupply(lender, 100 ether);
        _borrowOut(_actor("borrower"), 90 ether);
        uint256 id = _place(lender, 40 ether, lender, 0, _flat(0));

        address filler = _actor("filler");
        vm.prank(filler);
        vm.expectRevert(bytes("insufficient liquidity"));
        book.fillExitRequest(id, 40 ether, filler);

        assertEq(book.getExitRequest(id).assetsRemaining, 40 ether, "request is never auto-clipped");
    }

    function test_place_pendingInterestWithDifferentFeeRecipient_usesExpectedBacking() public {
        Market storage m = _m();
        address lender = _actor("lender");
        uint256 ownerShares = _lenderSupply(lender, 1_000 ether);
        _borrowOut(_actor("borrower"), 800 ether);
        m.core.setFeeRecipient(_actor("coreFeeRecipient"));
        m.core.setFee(m.params, 0.1e18);

        uint256 storedSupplyShares = m.core.market(m.id).totalSupplyShares;
        uint256 storedBorrowAssets = m.core.market(m.id).totalBorrowAssets;
        uint256 storedLastUpdate = m.core.market(m.id).lastUpdate;
        vm.warp(block.timestamp + 20 days);
        (uint256 totalSupplyAssets, uint256 totalSupplyShares, uint256 totalBorrowAssets,) =
            MorphoBalancesLib.expectedMarketBalances(m.core, m.params);
        uint256 expectedOwnerAssets = ownerShares.toAssetsDown(totalSupplyAssets, totalSupplyShares);
        assertGt(totalSupplyShares, storedSupplyShares, "pending fee shares included");
        assertGt(totalBorrowAssets, storedBorrowAssets, "pending interest included");

        uint256 id = _place(lender, expectedOwnerAssets, lender, 0, _flat(0));

        assertEq(m.core.market(m.id).lastUpdate, storedLastUpdate, "placement does not accrue");
        assertEq(book.getExitRequest(id).assetsTotal, expectedOwnerAssets, "expected backing boundary accepted");
    }

    function test_fill_pendingInterestWithDifferentFeeRecipient_usesLiveBurn() public {
        Market storage m = _m();
        address lender = _actor("lender");
        address filler = _actor("filler");
        address coreFeeRecipient = _actor("coreFeeRecipient");
        _lenderSupply(lender, 1_000 ether);
        _borrowOut(_actor("borrower"), 800 ether);
        m.core.setFeeRecipient(coreFeeRecipient);
        m.core.setFee(m.params, 0.1e18);

        uint256 fillAssets = 100 ether;
        uint256 id = _place(lender, fillAssets, lender, 0, _flat(0));
        vm.warp(block.timestamp + 20 days);
        (uint256 totalSupplyAssets, uint256 totalSupplyShares,,) =
            MorphoBalancesLib.expectedMarketBalances(m.core, m.params);
        uint256 expectedShares = fillAssets.toSharesUp(totalSupplyAssets, totalSupplyShares);
        uint256 ownerSharesBefore = m.core.position(m.id, lender).supplyShares;
        uint256 ownerAssetsBefore = ownerSharesBefore.toAssetsDown(totalSupplyAssets, totalSupplyShares);

        _fillAndAssert(id, fillAssets, filler);

        assertEq(ownerSharesBefore - m.core.position(m.id, lender).supplyShares, expectedShares, "expected live burn");
        assertApproxEqAbs(_positionAssets(lender), ownerAssetsBefore - fillAssets, 2, "accrued yield stays with lender");
        assertGt(_positionAssets(lender), 900 ether, "filler does not claim accrued yield");
        assertGt(m.core.position(m.id, coreFeeRecipient).supplyShares, 0, "fees minted to distinct recipient");
    }

    function test_badDebtLoss_stillFillsExactAssetsWhenBackingRemains() public {
        Market storage m = _m();
        address lender = _actor("lender");
        address borrower = _actor("borrower");
        address filler = _actor("filler");
        _lenderSupply(lender, 200 ether);
        _borrowOut(borrower, 80 ether);

        uint256 fillAssets = 50 ether;
        uint256 sharesAtPlacement;
        {
            (uint256 supplyAssets, uint256 supplyShares,,) = MorphoBalancesLib.expectedMarketBalances(m.core, m.params);
            sharesAtPlacement = fillAssets.toSharesUp(supplyAssets, supplyShares);
        }
        uint256 id = _place(lender, fillAssets, lender, 0, _flat(0));

        _realizeBadDebt(borrower);

        (uint256 supplyAssets, uint256 supplyShares,,) = MorphoBalancesLib.expectedMarketBalances(m.core, m.params);
        uint256 liveShares = fillAssets.toSharesUp(supplyAssets, supplyShares);
        assertGt(liveShares, sharesAtPlacement, "loss increases live share burn");
        assertLe(liveShares, m.core.position(m.id, lender).supplyShares, "request remains backed");

        _fillAndAssert(id, fillAssets, filler);
        assertEq(uint8(book.getExitRequest(id).status), uint8(ExitStatus.Filled), "exact request filled after loss");
    }

    function testRevert_maxShareBurn_badDebtLossUsesActualBurnAndRollsBack() public {
        Market storage m = _m();
        address lender = _actor("lender");
        address borrower = _actor("borrower");
        address filler = _actor("filler");
        _lenderSupply(lender, 200 ether);
        _borrowOut(borrower, 80 ether);

        uint256 fillAssets = 50 ether;
        (uint256 supplyAssets, uint256 supplyShares,,) = MorphoBalancesLib.expectedMarketBalances(m.core, m.params);
        uint128 maxShareBurn = uint128(fillAssets.toSharesUp(supplyAssets, supplyShares));
        vm.prank(lender);
        uint256 id =
            book.placeExitRequest(m.id, fillAssets, lender, 0, maxShareBurn, _flat(0), block.timestamp + MAX_LIFETIME);

        _realizeBadDebt(borrower);
        (supplyAssets, supplyShares,,) = MorphoBalancesLib.expectedMarketBalances(m.core, m.params);
        uint256 liveShares = fillAssets.toSharesUp(supplyAssets, supplyShares);
        assertGt(liveShares, maxShareBurn, "bad debt increases the actual burn");
        assertLe(liveShares, m.core.position(m.id, lender).supplyShares, "withdrawal reaches the cap check");

        uint256 ownerSharesBefore = m.core.position(m.id, lender).supplyShares;
        uint256 coreAssetsBefore = m.loanToken.balanceOf(address(m.core));
        uint256 lenderAssetsBefore = m.loanToken.balanceOf(lender);
        vm.prank(filler);
        vm.expectRevert(
            abi.encodeWithSelector(ExitBookBase.ShareBurnExceedsMaximum.selector, liveShares, uint256(maxShareBurn))
        );
        book.fillExitRequest(id, fillAssets, filler);

        assertEq(book.getExitRequest(id).assetsRemaining, fillAssets, "request debit rolled back");
        assertEq(m.core.position(m.id, lender).supplyShares, ownerSharesBefore, "actual share burn rolled back");
        assertEq(m.loanToken.balanceOf(address(m.core)), coreAssetsBefore, "core withdrawal rolled back");
        assertEq(m.loanToken.balanceOf(lender), lenderAssetsBefore, "receiver payout rolled back");
        assertEq(m.loanToken.balanceOf(address(book)), 0, "book balance rolled back");
    }

    function test_badDebtUnderbacking_requiresFillerToChooseSmallerExactFill() public {
        Market storage m = _m();
        address lender = _actor("lender");
        address borrower = _actor("borrower");
        address filler = _actor("filler");
        _lenderSupply(lender, 100 ether);
        _borrowOut(borrower, 80 ether);
        uint256 requestedAssets = 60 ether;
        uint256 id = _place(lender, requestedAssets, lender, 0, _flat(0));

        _realizeBadDebt(borrower);
        uint256 liveBacking = _positionAssets(lender);
        assertLt(liveBacking, requestedAssets, "loss underbacks full request");

        vm.prank(filler);
        vm.expectRevert();
        book.fillExitRequest(id, requestedAssets, filler);
        assertEq(book.getExitRequest(id).assetsRemaining, requestedAssets, "failed exact fill is not clipped");

        _fillAndAssert(id, liveBacking, filler);
        Request memory request = book.getExitRequest(id);
        assertEq(request.assetsRemaining, requestedAssets - liveBacking, "explicit smaller fill leaves exact tail");
        assertEq(uint8(request.status), uint8(ExitStatus.Open), "underbacked tail remains open");
    }

    function test_externalSelfSupplyThenFill_preservesLenderAssets() public {
        Market storage m = _m();
        address lender = _actor("lender");
        _lenderSupply(lender, 100 ether);
        _borrowOut(_actor("borrower"), 100 ether);
        uint256 id = _place(lender, 40 ether, lender, 0, _flat(0));

        _fund(m.loanToken, lender, 40 ether);
        uint256 assetsBefore = m.loanToken.balanceOf(lender);

        vm.startPrank(lender);
        m.loanToken.approve(address(m.core), 40 ether);
        m.core.supply(m.params, 40 ether, 0, lender, "");
        book.fillExitRequest(id, 40 ether, lender);
        vm.stopPrank();

        assertEq(m.loanToken.balanceOf(lender), assetsBefore, "self-filler recovers externally supplied assets");
        assertEq(uint8(book.getExitRequest(id).status), uint8(ExitStatus.Filled), "request filled");
    }

    function testRevert_sourcePause_blocksExactWithdrawalAndRollsBackRequest() public {
        Market storage m = _m();
        address lender = _actor("lender");
        _lenderSupply(lender, 20 ether);
        uint256 id = _place(lender, 10 ether, lender, 0, _flat(0));

        m.controller.grantRole(m.controller.PAUSER_ROLE(), address(this));
        m.controller.pauseFor(1 days);
        address filler = _actor("filler");
        vm.prank(filler);
        vm.expectRevert(PausableUntil.ResumedExpected.selector);
        book.fillExitRequest(id, 10 ether, filler);

        assertEq(book.getExitRequest(id).assetsRemaining, 10 ether, "request debit rolled back");
    }

    function test_sourceFreeze_allowsExternalSupplyAndExactWithdrawal() public {
        Market storage m = _m();
        address lender = _actor("lender");
        address filler = _actor("filler");
        _lenderSupply(lender, 100 ether);
        _borrowOut(_actor("borrower"), 90 ether);
        uint256 id = _place(lender, 40 ether, lender, 0, _flat(0));
        uint256 requiredSupply = 40 ether - _idleAssets();
        _fund(m.loanToken, filler, requiredSupply);
        m.controller.grantRole(m.controller.FREEZER_ROLE(), address(this));
        m.controller.freeze();

        vm.startPrank(filler);
        m.loanToken.approve(address(m.core), requiredSupply);
        m.core.supply(m.params, requiredSupply, 0, filler, "");
        book.fillExitRequest(id, 40 ether, filler);
        vm.stopPrank();

        assertEq(uint8(book.getExitRequest(id).status), uint8(ExitStatus.Filled), "freeze leaves lender exits open");
    }

    /// @dev Constructing the book with a zero core (Morpho) address reverts.
    function testRevert_constructor_zeroMorpho() public {
        vm.expectRevert(MorphoExitBook.ZeroMorpho.selector);
        new MorphoExitBook(address(0), address(this), MAX_LIFETIME);
    }

    /// @dev marketParamsOf(id) returns the full market params of the request's market.
    function test_marketParamsOf_returnsRequestMarket() public {
        address lender = address(0xA11CE);
        _lenderSupply(lender, 10 ether);
        uint256 id = _place(lender, 10 ether, lender, 0, _flat(0));

        MarketParams memory p = book.marketParamsOf(id);
        assertEq(p.loanToken, _m().params.loanToken, "loan token matches the request market");
        assertEq(p.collateralToken, _m().params.collateralToken, "collateral token");
        assertEq(p.oracle, _m().params.oracle, "oracle");
        assertEq(p.irm, _m().params.irm, "irm");
        assertEq(p.lltv, _m().params.lltv, "lltv");
    }
}
