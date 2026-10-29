// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {TrailingAnchorOracleBase} from "../../src/oracle/TrailingAnchorOracleBase.sol";
import {UsdyNavOracle} from "../../src/oracle/UsdyNavOracle.sol";
import {OssifiableProxy} from "../../src/proxy/OssifiableProxy.sol";

import {
    TrailingAnchorOracleModel,
    TrailingAnchorOracleState,
    TrailingAnchorOracleUpdate
} from "../setup/TrailingAnchorOracleModel.sol";
import {IOssifiableProxy} from "../setup/IOssifiableProxy.sol";
import {MockERC20} from "../setup/Mocks.sol";
import {CentrifugeNavOracleFixture, NavOracleFixture, UsdyNavOracleFixture} from "../setup/NavOracleFixtures.sol";
import {MockOndoPriceGetter, SourceDown} from "../setup/NavSourceMocks.sol";

/// @notice `TrailingAnchorOracleBase` method by method, run once through each adapter over its source mock.
/// @dev The loan token has 6 decimals, like USDC. Every `updateAnchor()` call goes through `_update()`, which checks
///      the stored state and the exact logs against `TrailingAnchorOracleModel`; the key numbers are also written out
///      with the bound, speed, floor and ceiling formulas in the tests, never read from the oracle.
abstract contract TrailingAnchorOracleBaseTest is NavOracleFixture {
    using TrailingAnchorOracleModel for TrailingAnchorOracleState;

    uint256 internal constant WAD = 1e18;
    uint256 internal constant YEAR = 365 days;
    uint256 internal constant START = 1_760_000_000;
    uint256 internal constant INITIAL_PRICE = 1.112233445566778899e18;
    uint256 internal constant MAX_PRICE_ABOVE_ANCHOR = TrailingAnchorOracleModel.MAX_PRICE_ABOVE_ANCHOR;
    uint256 internal constant MAX_PRICE_BELOW_ANCHOR = TrailingAnchorOracleModel.MAX_PRICE_BELOW_ANCHOR;
    uint256 internal constant MAX_ANCHOR_RISE_PER_YEAR = TrailingAnchorOracleModel.MAX_ANCHOR_RISE_PER_YEAR;
    uint256 internal constant MAX_ANCHOR_FALL_PER_YEAR = TrailingAnchorOracleModel.MAX_ANCHOR_FALL_PER_YEAR;
    uint256 internal constant MAX_ANCHOR_BELOW_MARK = TrailingAnchorOracleModel.MAX_ANCHOR_BELOW_MARK;
    uint256 internal constant MAX_ANCHOR_ABOVE_MARK = TrailingAnchorOracleModel.MAX_ANCHOR_ABOVE_MARK;
    uint256 internal constant DELAY = TrailingAnchorOracleModel.REANCHOR_DELAY;
    uint256 internal constant WINDOW = TrailingAnchorOracleModel.REANCHOR_WINDOW;
    /// @dev The EIP-1967 implementation slot the proxy reads on every call.
    bytes32 internal constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    MockERC20 internal loan;
    TrailingAnchorOracleBase internal oracle;
    /// @dev Recomputed from the token decimals, not read from the oracle.
    uint256 internal priceScale;

    address internal admin = makeAddr("admin");
    address internal manager = makeAddr("manager");
    address internal priceAcceptor = makeAddr("priceAcceptor");
    address internal anyone = makeAddr("anyone");

    function setUp() public {
        vm.warp(START);
        _setUpSource();
        source.setCurrentPrice(INITIAL_PRICE);
        loan = new MockERC20("USD Coin", "USDC", 6);
        priceScale = TrailingAnchorOracleModel.priceScale(6, IERC20Metadata(collateralToken).decimals());
        oracle = _deployOracle(address(loan), admin, TrailingAnchorOracleModel.initializeCall(admin));
        bytes32 managerRole = oracle.MANAGER_ROLE();
        bytes32 priceAcceptorRole = oracle.PRICE_ACCEPTOR_ROLE();
        vm.startPrank(admin);
        oracle.grantRole(managerRole, manager);
        oracle.grantRole(priceAcceptorRole, priceAcceptor);
        vm.stopPrank();
    }

    // ---
    // CONSTRUCTOR AND INITIALIZE
    // ---

    function testRevert_constructor_zeroLoanToken() public {
        vm.expectRevert(TrailingAnchorOracleBase.ZeroAddress.selector);
        _newImplementation(address(0));
    }

    function testRevert_constructor_disablesInitializers() public {
        TrailingAnchorOracleBase impl = TrailingAnchorOracleBase(_newImplementation(address(loan)));
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(admin, TrailingAnchorOracleModel.defaultParameters());
    }

    function test_initialize_seedsAnchor() public {
        address impl = _newImplementation(address(loan));
        TrailingAnchorOracleBase.Parameters memory p = TrailingAnchorOracleModel.defaultParameters();
        vm.expectEmit();
        emit TrailingAnchorOracleBase.ParametersSet(p);
        vm.expectEmit();
        emit TrailingAnchorOracleBase.AnchorSet(INITIAL_PRICE, uint40(START), true);
        TrailingAnchorOracleBase fresh = TrailingAnchorOracleBase(
            address(new OssifiableProxy(impl, admin, TrailingAnchorOracleModel.initializeCall(admin)))
        );

        TrailingAnchorOracleState memory s = TrailingAnchorOracleModel.read(fresh);
        assertEq(s.anchorPrice, INITIAL_PRICE, "anchorPrice");
        assertEq(s.anchorAt, START, "anchorAt");
        assertEq(s.pricingResumesAt, 0, "no suspension");
        assertEq(s.pendingAnchorPrice, 0, "no pending anchor price");
        assertEq(s.pendingAnchorAt, 0, "no pending anchor time");
        assertEq(s.highWaterMark, INITIAL_PRICE, "highWaterMark is the seed");
        _assertParameters(s, p);
        assertTrue(fresh.hasRole(fresh.DEFAULT_ADMIN_ROLE(), admin), "admin role");
        assertEq(fresh.getRoleMemberCount(fresh.DEFAULT_ADMIN_ROLE()), 1, "one admin");
        assertEq(fresh.getRoleMemberCount(fresh.MANAGER_ROLE()), 0, "manager role starts empty");
        assertEq(fresh.getRoleMemberCount(fresh.PRICE_ACCEPTOR_ROLE()), 0, "price acceptor role starts empty");
        assertEq(fresh.price(), INITIAL_PRICE * priceScale, "price is the current price at once");
    }

    function testRevert_initialize_zeroAdmin() public {
        address impl = _newImplementation(address(loan));
        vm.expectRevert(TrailingAnchorOracleBase.ZeroAddress.selector);
        new OssifiableProxy(impl, admin, TrailingAnchorOracleModel.initializeCall(address(0)));
    }

    function testRevert_initialize_twice() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        oracle.initialize(admin, TrailingAnchorOracleModel.defaultParameters());
    }

    function testRevert_initialize_sourceFails() public {
        address impl = _newImplementation(address(loan));
        bytes memory init = TrailingAnchorOracleModel.initializeCall(admin);
        source.setCurrentPrice(0);
        vm.expectRevert(TrailingAnchorOracleBase.ZeroPrice.selector);
        new OssifiableProxy(impl, admin, init);
        source.setCurrentPrice(INITIAL_PRICE);
        source.setDown(true);
        vm.expectRevert(SourceDown.selector);
        new OssifiableProxy(impl, admin, init);
    }

    /// @dev `initialize` validates as `setParameters` does: every invalid case of the validator test refuses it.
    function testRevert_initialize_invalidParameters() public {
        address impl = _newImplementation(address(loan));
        TrailingAnchorOracleBase.Parameters[] memory cases = _invalidParameters();
        for (uint256 i; i < cases.length; ++i) {
            vm.expectRevert(TrailingAnchorOracleBase.InvalidParameters.selector);
            new OssifiableProxy(impl, admin, TrailingAnchorOracleModel.initializeCall(admin, cases[i]));
        }
    }

    // ---
    // ROLES
    // ---

    /// @dev Two roles under the admin: the manager sets the parameters and suspends pricing, the price acceptor
    ///      accepts a price.
    function test_roles_idsAndAdmin() public view {
        assertEq(oracle.MANAGER_ROLE(), keccak256("MANAGER_ROLE"), "MANAGER_ROLE");
        assertEq(oracle.PRICE_ACCEPTOR_ROLE(), keccak256("PRICE_ACCEPTOR_ROLE"), "PRICE_ACCEPTOR_ROLE");
        assertEq(oracle.getRoleAdmin(oracle.MANAGER_ROLE()), oracle.DEFAULT_ADMIN_ROLE(), "manager role admin");
        assertEq(
            oracle.getRoleAdmin(oracle.PRICE_ACCEPTOR_ROLE()), oracle.DEFAULT_ADMIN_ROLE(), "price acceptor role admin"
        );
    }

    // ---
    // PRICE
    // ---

    function test_price_scalesCurrentPrice() public view {
        assertEq(oracle.PRICE_SCALE(), priceScale, "PRICE_SCALE");
        assertEq(oracle.price(), INITIAL_PRICE * priceScale, "the current price times PRICE_SCALE");
    }

    /// @dev The anchor price × (1 − maxPriceBelowAnchor) and × (1 + maxPriceAboveAnchor), rounded down, both edges
    ///      inclusive.
    function test_price_boundsEdgesInclusive() public {
        uint256 low = _lower(INITIAL_PRICE);
        uint256 high = _upper(INITIAL_PRICE);
        source.setCurrentPrice(low);
        assertEq(oracle.price(), low * priceScale, "lower bound");
        source.setCurrentPrice(high);
        assertEq(oracle.price(), high * priceScale, "upper bound");
        source.setCurrentPrice(low - 1);
        vm.expectRevert(abi.encodeWithSelector(TrailingAnchorOracleBase.PriceOutOfBounds.selector, low - 1, low, high));
        oracle.price();
        source.setCurrentPrice(high + 1);
        vm.expectRevert(abi.encodeWithSelector(TrailingAnchorOracleBase.PriceOutOfBounds.selector, high + 1, low, high));
        oracle.price();
    }

    /// @dev The two bounds are separate: the same 0.08% passes below the anchor, inside the 0.1% decrease, and fails
    ///      above it, outside the 0.05% increase.
    function test_price_boundsAreSeparate() public {
        uint256 distance = Math.mulDiv(INITIAL_PRICE, 0.0008e18, WAD);
        source.setCurrentPrice(INITIAL_PRICE - distance);
        assertEq(oracle.price(), (INITIAL_PRICE - distance) * priceScale, "0.08% down");
        source.setCurrentPrice(INITIAL_PRICE + distance);
        vm.expectRevert(
            abi.encodeWithSelector(
                TrailingAnchorOracleBase.PriceOutOfBounds.selector,
                INITIAL_PRICE + distance,
                _lower(INITIAL_PRICE),
                _upper(INITIAL_PRICE)
            )
        );
        oracle.price();
    }

    function testRevert_price_sourceFails() public {
        source.setCurrentPrice(0);
        vm.expectRevert(TrailingAnchorOracleBase.ZeroPrice.selector);
        oracle.price();
        source.setDown(true);
        vm.expectRevert(SourceDown.selector);
        oracle.price();
    }

    /// @dev `price()` checks the anchor's bounds only: a pending anchor in its window does not let the price through
    ///      until an update moves the anchor onto it.
    function test_price_ignoresPendingAnchor() public {
        _withoutFloor();
        uint256 fallen = Math.mulDiv(INITIAL_PRICE, 0.975e18, WAD);
        source.setCurrentPrice(fallen);
        _update();
        assertEq(_read().pendingAnchorPrice, fallen, "the pending anchor is the price itself");
        vm.warp(START + DELAY);
        vm.expectRevert(
            abi.encodeWithSelector(
                TrailingAnchorOracleBase.PriceOutOfBounds.selector, fallen, _lower(INITIAL_PRICE), _upper(INITIAL_PRICE)
            )
        );
        oracle.price();
        _update();
        assertEq(oracle.price(), fallen * priceScale, "priced once the update re-anchors");
    }

    /// @dev Any current price and suspension: the price is the current price scaled, or the revert the rules name.
    function testFuzz_price_matchesRule(uint256 currentPrice, uint256 resumesIn, uint256 elapsed) public {
        currentPrice = bound(currentPrice, 0, INITIAL_PRICE * 2);
        resumesIn = bound(resumesIn, 0, 7 days);
        elapsed = bound(elapsed, 0, 8 days);
        vm.prank(manager);
        oracle.setPricingResumesAt(uint40(START + resumesIn));
        vm.warp(START + elapsed);
        source.setCurrentPrice(currentPrice);
        _assertPriceMatchesRule();
    }

    /// @dev The usual path reads the first two slots of the namespace only, also with a pending anchor and a past
    ///      suspension stored, besides the proxy's implementation slot.
    function test_price_readsTwoSlots() public {
        vm.prank(manager);
        oracle.setPricingResumesAt(uint40(START + 1));
        source.setCurrentPrice(Math.mulDiv(INITIAL_PRICE, 0.9e18, WAD));
        _update();
        source.setCurrentPrice(INITIAL_PRICE);
        vm.warp(START + 1);
        bytes32 base = TrailingAnchorOracleModel.namespaceSlot(_namespace());
        vm.record();
        oracle.price();
        (bytes32[] memory reads,) = vm.accesses(address(oracle));
        bool sawFirst;
        bool sawSecond;
        for (uint256 i; i < reads.length; ++i) {
            if (reads[i] == base) sawFirst = true;
            else if (reads[i] == bytes32(uint256(base) + 1)) sawSecond = true;
            else assertEq(reads[i], IMPLEMENTATION_SLOT, "a slot other than the first two");
        }
        assertTrue(sawFirst && sawSecond, "both slots read");
    }

    // ---
    // UPDATE ANCHOR: DRIFT
    // ---

    /// @dev A current price within the bounds and the reach is taken whole, by anyone: a day at 6% a year reaches
    ///      0.016% up, and 0.01% is inside it.
    function test_updateAnchor_takesPriceInsideReach() public {
        vm.warp(START + 1 days);
        uint256 currentPrice = INITIAL_PRICE + INITIAL_PRICE / 10_000;
        source.setCurrentPrice(currentPrice);
        TrailingAnchorOracleUpdate memory u = _update();
        assertTrue(u.anchorSet, "moved");
        assertEq(_read().anchorPrice, currentPrice, "anchorPrice");
        assertEq(oracle.price(), currentPrice * priceScale, "price is the current price");
    }

    /// @dev A current price on the upper bound moves the anchor by one day of the rise speed, rounded down.
    function test_updateAnchor_risesAtRiseSpeed() public {
        vm.warp(START + 1 days);
        source.setCurrentPrice(_upper(INITIAL_PRICE));
        _update();
        uint256 expected = INITIAL_PRICE + Math.mulDiv(INITIAL_PRICE, MAX_ANCHOR_RISE_PER_YEAR * 1 days, WAD * YEAR);
        assertEq(_read().anchorPrice, expected, "one day of the rise speed");
    }

    /// @dev A current price on the lower bound moves the anchor by one day of the fall speed, rounded down.
    function test_updateAnchor_fallsAtFallSpeed() public {
        vm.warp(START + 1 days);
        source.setCurrentPrice(_lower(INITIAL_PRICE));
        _update();
        uint256 expected = INITIAL_PRICE - Math.mulDiv(INITIAL_PRICE, MAX_ANCHOR_FALL_PER_YEAR * 1 days, WAD * YEAR);
        assertEq(_read().anchorPrice, expected, "one day of the fall speed");
    }

    /// @dev After two years at rest the speeds would reach 12%, but a drift only follows a price within the bounds, so
    ///      the anchor lands on the price: one move never passes the bound.
    function test_updateAnchor_longRestMovesOnlyToThePrice() public {
        vm.warp(START + 2 * YEAR);
        uint256 high = _upper(INITIAL_PRICE);
        source.setCurrentPrice(high);
        _update();
        assertEq(_read().anchorPrice, high, "the upper bound, not the reach");
    }

    /// @dev A whole price a year of fall over three years at rest would take more than the anchor: the fall term is
    ///      held at the anchor price, and the anchor lands on the price.
    function test_updateAnchor_fullFallSpeedAfterLongRest() public {
        TrailingAnchorOracleBase.Parameters memory p = TrailingAnchorOracleModel.defaultParameters();
        p.maxAnchorFallPerYear = uint64(WAD);
        _setParameters(p);
        vm.warp(START + 3 * YEAR);
        uint256 low = _lower(INITIAL_PRICE);
        source.setCurrentPrice(low);
        _update();
        assertEq(_read().anchorPrice, low, "the lower bound");
    }

    /// @dev A second update in the block the anchor moved counts no time, even on a source that moved again within the
    ///      bounds, so updates in one transaction cannot compound.
    function test_updateAnchor_sameBlockDoesNotCompound() public {
        vm.warp(START + 1 days);
        source.setCurrentPrice(_upper(INITIAL_PRICE));
        _update();
        uint256 moved = _read().anchorPrice;
        source.setCurrentPrice(_upper(moved));
        TrailingAnchorOracleUpdate memory u = _update();
        assertFalse(u.anchorSet || u.pendingAnchorSet || u.pendingAnchorCleared, "nothing changes");
        assertEq(_read().anchorPrice, moved, "no second move");
    }

    /// @dev A price on the anchor with no pending anchor changes nothing and does not revert.
    function test_updateAnchor_nothingToDo() public {
        vm.warp(START + 1 days);
        TrailingAnchorOracleUpdate memory u = _update();
        assertFalse(u.anchorSet || u.pendingAnchorSet || u.pendingAnchorCleared, "nothing changes");
        assertEq(_read().anchorAt, START, "anchorAt kept");
    }

    /// @dev Each case returns its own outcome, which `AnchorUpdated` carries too: a price within the bounds, a record,
    ///      a held wait, a re-anchor, a re-anchor onto the floor, an anchor pinned on the floor, a re-anchor onto the
    ///      ceiling, and an anchor pinned on the ceiling.
    function test_updateAnchor_returnsTheOutcomeOfEachCase() public {
        vm.warp(START + 1 days);
        _assertOutcome(TrailingAnchorOracleBase.UpdateOutcome.WithinBounds);

        source.setCurrentPrice(Math.mulDiv(INITIAL_PRICE, 0.995e18, WAD));
        _assertOutcome(TrailingAnchorOracleBase.UpdateOutcome.PendingAnchorRecorded);
        _assertOutcome(TrailingAnchorOracleBase.UpdateOutcome.PendingAnchorHeld);
        vm.warp(block.timestamp + DELAY);
        _assertOutcome(TrailingAnchorOracleBase.UpdateOutcome.PendingAnchorApplied);

        source.setCurrentPrice(Math.mulDiv(INITIAL_PRICE, 0.95e18, WAD));
        _assertOutcome(TrailingAnchorOracleBase.UpdateOutcome.PendingAnchorRecorded);
        vm.warp(block.timestamp + DELAY);
        _assertOutcome(TrailingAnchorOracleBase.UpdateOutcome.PendingAnchorApplied);
        assertEq(_read().anchorPrice, _floor(INITIAL_PRICE), "onto the floor");
        vm.warp(block.timestamp + DELAY);
        _assertOutcome(TrailingAnchorOracleBase.UpdateOutcome.AnchorOnFloor);

        source.setCurrentPrice(Math.mulDiv(INITIAL_PRICE, 1.05e18, WAD));
        _assertOutcome(TrailingAnchorOracleBase.UpdateOutcome.PendingAnchorRecorded);
        vm.warp(block.timestamp + DELAY);
        _assertOutcome(TrailingAnchorOracleBase.UpdateOutcome.PendingAnchorApplied);
        assertEq(_read().anchorPrice, _ceiling(INITIAL_PRICE), "onto the ceiling");
        vm.warp(block.timestamp + DELAY);
        _assertOutcome(TrailingAnchorOracleBase.UpdateOutcome.AnchorOnCeiling);
    }

    /// @dev A price outside the bounds does not drift the anchor, however long it rested: it becomes a pending anchor.
    function test_updateAnchor_noDriftOutsideBounds() public {
        vm.warp(START + 9 days);
        uint256 currentPrice = _upper(INITIAL_PRICE) + 1;
        source.setCurrentPrice(currentPrice);
        TrailingAnchorOracleUpdate memory u = _update();
        assertFalse(u.anchorSet, "no drift");
        assertEq(_read().anchorPrice, INITIAL_PRICE, "anchor kept");
        assertEq(_read().pendingAnchorPrice, currentPrice, "the price is the pending anchor");
    }

    /// @dev A down source bubbles up, and a zero price reverts before any move.
    function testRevert_updateAnchor_sourceFails() public {
        vm.warp(START + 1 days);
        source.setDown(true);
        vm.expectRevert(SourceDown.selector);
        oracle.updateAnchor();
        source.setDown(false);
        source.setCurrentPrice(0);
        vm.expectRevert(TrailingAnchorOracleBase.ZeroPrice.selector);
        oracle.updateAnchor();
    }

    // ---
    // UPDATE ANCHOR: PENDING ANCHOR
    // ---

    /// @dev A price outside the bounds, at any distance, is the pending anchor itself, recorded at the update's time.
    function test_updateAnchor_recordsThePriceAsPendingAnchor() public {
        vm.warp(START + 1 hours);
        uint256 currentPrice = Math.mulDiv(INITIAL_PRICE, 0.5e18, WAD);
        source.setCurrentPrice(currentPrice);
        TrailingAnchorOracleUpdate memory u = _update();
        assertTrue(u.pendingAnchorSet, "PendingAnchorSet");
        assertEq(_read().pendingAnchorPrice, currentPrice, "pendingAnchorPrice");
        assertEq(_read().pendingAnchorAt, START + 1 hours, "pendingAnchorAt");
        assertEq(_read().anchorPrice, INITIAL_PRICE, "anchor kept");
    }

    /// @dev While the price stays outside the bounds on the pending anchor's side, updates before the window change
    ///      nothing, even after a further fall and on the last second of the delay.
    function test_updateAnchor_holdsWhilePendingAnchorWaits() public {
        source.setCurrentPrice(Math.mulDiv(INITIAL_PRICE, 0.9e18, WAD));
        _update();
        TrailingAnchorOracleState memory recorded = _read();
        vm.warp(START + DELAY - 1);
        source.setCurrentPrice(Math.mulDiv(INITIAL_PRICE, 0.8e18, WAD));
        TrailingAnchorOracleUpdate memory u = _update();
        assertFalse(u.anchorSet || u.pendingAnchorSet || u.pendingAnchorCleared, "nothing changes");
        _assertState(recorded);
    }

    /// @dev The window opens exactly `reanchorDelay` after the record: the anchor moves onto the pending anchor.
    function test_updateAnchor_reanchorsWhenTheWindowOpens() public {
        uint256 currentPrice = Math.mulDiv(INITIAL_PRICE, 0.995e18, WAD);
        source.setCurrentPrice(currentPrice);
        _update();
        vm.warp(START + DELAY);
        vm.expectEmit(address(oracle));
        emit TrailingAnchorOracleBase.AnchorSet(currentPrice, uint40(START + DELAY), false);
        vm.expectEmit(address(oracle));
        emit TrailingAnchorOracleBase.PendingAnchorCleared();
        vm.expectEmit(address(oracle));
        emit TrailingAnchorOracleBase.AnchorUpdated(
            TrailingAnchorOracleBase.UpdateOutcome.PendingAnchorApplied, currentPrice
        );
        oracle.updateAnchor();
        assertEq(_read().anchorPrice, currentPrice, "anchor on the pending anchor");
        assertEq(_read().pendingAnchorAt, 0, "the price is within the new bounds");
    }

    /// @dev The window's last second still re-anchors.
    function test_updateAnchor_reanchorsOnTheWindowsLastSecond() public {
        source.setCurrentPrice(Math.mulDiv(INITIAL_PRICE, 0.995e18, WAD));
        _update();
        uint256 pendingAnchorPrice = _read().pendingAnchorPrice;
        vm.warp(START + DELAY + WINDOW);
        _update();
        assertEq(_read().anchorPrice, pendingAnchorPrice, "re-anchored");
    }

    /// @dev One second after the window the pending anchor has expired: the update records it anew from the current
    ///      price, and the delay starts again.
    function test_updateAnchor_expiredPendingAnchorRecordedAnew() public {
        source.setCurrentPrice(Math.mulDiv(INITIAL_PRICE, 0.9e18, WAD));
        _update();
        vm.warp(START + DELAY + WINDOW + 1);
        TrailingAnchorOracleUpdate memory u = _update();
        assertFalse(u.anchorSet, "an expired pending anchor is not used");
        assertTrue(u.pendingAnchorSet, "recorded anew");
        assertEq(_read().pendingAnchorAt, START + DELAY + WINDOW + 1, "the delay restarts");
        assertEq(_read().anchorPrice, INITIAL_PRICE, "anchor kept");
    }

    /// @dev The price falls further while the pending anchor waits: the window moves the anchor onto the published
    ///      pending anchor, not the further price, and records the further price as the next pending anchor in the same
    ///      call.
    function test_updateAnchor_reanchorRecordsAFurtherMove() public {
        _withoutFloor();
        uint256 first = Math.mulDiv(INITIAL_PRICE, 0.9e18, WAD);
        source.setCurrentPrice(first);
        _update();
        vm.warp(START + 1 hours);
        uint256 further = Math.mulDiv(INITIAL_PRICE, 0.8e18, WAD);
        source.setCurrentPrice(further);
        _update();
        vm.warp(START + DELAY);
        vm.expectEmit(address(oracle));
        emit TrailingAnchorOracleBase.AnchorSet(first, uint40(START + DELAY), false);
        vm.expectEmit(address(oracle));
        emit TrailingAnchorOracleBase.PendingAnchorSet(further, uint40(START + DELAY));
        vm.expectEmit(address(oracle));
        emit TrailingAnchorOracleBase.AnchorUpdated(
            TrailingAnchorOracleBase.UpdateOutcome.PendingAnchorApplied, further
        );
        oracle.updateAnchor();
    }

    /// @dev A 10% fall is priced one delay after the update that records it, with no floor in the way.
    function test_updateAnchor_largeFallPricedAfterOneDelay() public {
        _withoutFloor();
        uint256 fallen = Math.mulDiv(INITIAL_PRICE, 0.9e18, WAD);
        source.setCurrentPrice(fallen);
        assertEq(_walk(), 1, "one re-anchor");
        assertEq(block.timestamp, START + DELAY, "one delay");
        assertEq(oracle.price(), fallen * priceScale, "priced at the fall");
    }

    /// @dev A 5% rise is priced one delay after the update that records it, with no ceiling in the way.
    function test_updateAnchor_largeRisePricedAfterOneDelay() public {
        _withoutCeiling();
        uint256 risen = Math.mulDiv(INITIAL_PRICE, 1.05e18, WAD);
        source.setCurrentPrice(risen);
        assertEq(_walk(), 1, "one re-anchor");
        assertEq(oracle.price(), risen * priceScale, "priced at the rise");
    }

    /// @dev A price that falls back short of a downward pending anchor, still outside the bounds, holds it: when the
    ///      window opens the anchor moves onto the price, the nearer of the two, and the pending anchor is dropped.
    function test_updateAnchor_fallShortHoldsAndReanchorsOnThePrice() public {
        _withoutFloor();
        source.setCurrentPrice(Math.mulDiv(INITIAL_PRICE, 0.9e18, WAD));
        _update();
        TrailingAnchorOracleState memory recorded = _read();
        vm.warp(START + 1 hours);
        uint256 recovered = Math.mulDiv(INITIAL_PRICE, 0.98e18, WAD);
        source.setCurrentPrice(recovered);
        TrailingAnchorOracleUpdate memory u = _update();
        assertFalse(u.anchorSet || u.pendingAnchorSet || u.pendingAnchorCleared, "held");
        _assertState(recorded);
        vm.warp(START + DELAY);
        u = _update();
        assertEq(_read().anchorPrice, recovered, "the anchor on the price, not the pending anchor");
        assertTrue(u.pendingAnchorCleared, "the price is within the new bounds");
    }

    /// @dev The same upward: a price that eases back short of an upward pending anchor holds it, and the window moves
    ///      the anchor onto the price.
    function test_updateAnchor_riseShortHoldsAndReanchorsOnThePrice() public {
        _withoutCeiling();
        uint256 risen = Math.mulDiv(INITIAL_PRICE, 1.05e18, WAD);
        source.setCurrentPrice(risen);
        _update();
        vm.warp(START + 1 hours);
        uint256 eased = Math.mulDiv(INITIAL_PRICE, 1.01e18, WAD);
        source.setCurrentPrice(eased);
        _update();
        assertEq(_read().pendingAnchorPrice, risen, "the pending anchor holds");
        vm.warp(START + DELAY);
        _update();
        assertEq(_read().anchorPrice, eased, "the anchor on the price");
    }

    /// @dev A real 1% fall on a source that keeps accruing daily, with a keeper an hour after each step: the step moves
    ///      the price back toward the anchor but leaves it outside the bounds, so the pending anchor holds, and the
    ///      first update after the window opens moves the anchor onto the accrued price.
    function test_updateAnchor_dailyAccrualAfterAFallReanchors() public {
        uint256 fallen = Math.mulDiv(INITIAL_PRICE, 0.99e18, WAD);
        source.setCurrentPrice(fallen);
        _update();
        vm.warp(START + 1 days);
        uint256 accrued = Math.mulDiv(fallen, 1.000115e18, WAD);
        source.setCurrentPrice(accrued);
        vm.warp(START + 1 days + 1 hours);
        TrailingAnchorOracleUpdate memory u = _update();
        assertTrue(u.anchorSet, "re-anchored at the first update after the window opened");
        assertEq(_read().anchorPrice, accrued, "onto the accrued price");
        assertEq(oracle.price(), accrued * priceScale, "priced");
    }

    /// @dev A one-block spike recorded as a pending anchor is dropped by the next update once the price is back within
    ///      the bounds, so the anchor never lands on it.
    function test_updateAnchor_backInBoundsDropsPendingAnchor() public {
        source.setCurrentPrice(Math.mulDiv(INITIAL_PRICE, 1.001e18, WAD));
        _update();
        assertGt(_read().pendingAnchorAt, 0, "a pending anchor");
        source.setCurrentPrice(INITIAL_PRICE);
        TrailingAnchorOracleUpdate memory u = _update();
        assertTrue(u.pendingAnchorCleared, "PendingAnchorCleared");
        vm.warp(START + DELAY);
        _update();
        assertEq(_read().anchorPrice, INITIAL_PRICE, "the anchor never moved");
    }

    /// @dev A price that crosses to the other side of the anchor replaces a downward pending anchor with an upward one.
    function test_updateAnchor_otherSideReplacesPendingAnchor() public {
        source.setCurrentPrice(Math.mulDiv(INITIAL_PRICE, 0.9e18, WAD));
        _update();
        vm.warp(START + 1 hours);
        uint256 risen = Math.mulDiv(INITIAL_PRICE, 1.05e18, WAD);
        source.setCurrentPrice(risen);
        _update();
        assertEq(_read().pendingAnchorPrice, risen, "the rise is the pending anchor");
    }

    /// @dev A delay and a window near the type's maximum, which a manager might set to stop re-anchoring with the rise
    ///      speed off, as the delay rule then allows, do not overflow the window arithmetic.
    function test_updateAnchor_hugeDelayDoesNotOverflow() public {
        TrailingAnchorOracleBase.Parameters memory p = TrailingAnchorOracleModel.defaultParameters();
        p.maxAnchorRisePerYear = 0;
        p.reanchorDelay = type(uint40).max;
        p.reanchorWindow = type(uint40).max;
        _setParameters(p);
        source.setCurrentPrice(Math.mulDiv(INITIAL_PRICE, 0.9e18, WAD));
        _update();
        vm.warp(START + 30 days);
        TrailingAnchorOracleUpdate memory u = _update();
        assertFalse(u.anchorSet || u.pendingAnchorSet || u.pendingAnchorCleared, "still waiting");
    }

    /// @dev Any current price and time, with or without a pending anchor: the update does what the model says, events
    ///      included.
    function testFuzz_updateAnchor_matchesModel(uint256 factor, uint256 elapsed, bool withPendingAnchor) public {
        if (withPendingAnchor) {
            source.setCurrentPrice(Math.mulDiv(INITIAL_PRICE, 0.95e18, WAD));
            _update();
        }
        factor = bound(factor, 0.8e18, 1.2e18);
        elapsed = bound(elapsed, 0, 3 days);
        vm.warp(START + elapsed);
        source.setCurrentPrice(Math.mulDiv(INITIAL_PRICE, factor, WAD));
        _update();
        _assertPriceMatchesRule();
    }

    /// @dev Any walk of prices and times: every anchor move is a drift toward a price within the bounds, inside the
    ///      speeds' reach, or a move onto the nearer of the price and a pending anchor recorded at least the delay
    ///      before, with the price outside the bounds on the pending anchor's side. No move goes under the floor, no
    ///      re-anchor over the ceiling, a re-anchor leaves the high-water mark, and a drift never widens the anchor's
    ///      gap over it nor raises it by more than its own step.
    function testFuzz_updateAnchor_movesOnlyByReachOrWaitedPendingAnchors(uint256 seed) public {
        for (uint256 i; i < 40; ++i) {
            vm.warp(block.timestamp + bound(uint256(keccak256(abi.encode(seed, i, "time"))), 0, 2 days));
            TrailingAnchorOracleState memory s = _read();
            uint256 pick = uint256(keccak256(abi.encode(seed, i, "price")));
            uint256 factor = pick % 3 == 0 ? bound(pick, 0.9996e18, 1.0004e18) : bound(pick, 0.85e18, 1.15e18);
            uint256 currentPrice = Math.mulDiv(s.anchorPrice, factor, WAD);
            source.setCurrentPrice(currentPrice);
            TrailingAnchorOracleUpdate memory u = _update();
            if (u.anchorSet) _assertMoveFollowsTheRules(s, u.next, currentPrice);
        }
    }

    /// @dev The checks of the walk above on one move from `s` to `next`.
    function _assertMoveFollowsTheRules(
        TrailingAnchorOracleState memory s,
        TrailingAnchorOracleState memory next,
        uint256 currentPrice
    ) internal view {
        uint256 moved = next.anchorPrice;
        uint256 low = Math.min(_floor(s.highWaterMark), s.anchorPrice);
        uint256 high = Math.max(_ceiling(s.highWaterMark), s.anchorPrice);
        assertGe(moved, low, "a move under the floor");
        assertGe(next.highWaterMark, s.highWaterMark, "the high-water mark fell");
        bool waited = s.pendingAnchorAt != 0 && block.timestamp >= s.pendingAnchorAt + s.reanchorDelay;
        bool up = s.pendingAnchorPrice > s.anchorPrice;
        bool heldSide = !s.withinBounds(currentPrice) && (currentPrice > s.anchorPrice) == up;
        uint256 nearer = up
            ? Math.min(Math.min(s.pendingAnchorPrice, currentPrice), high)
            : Math.max(Math.max(s.pendingAnchorPrice, currentPrice), low);
        if (waited && heldSide && moved == nearer) {
            assertEq(next.highWaterMark, s.highWaterMark, "a re-anchor moved the high-water mark");
            return;
        }
        assertTrue(s.withinBounds(currentPrice), "a drift toward a price outside the bounds");
        (uint256 lowest, uint256 highest) = s.reach(block.timestamp);
        assertGe(moved, lowest, "a drift under the reach");
        assertLe(moved, highest, "a drift over the reach");
        uint256 gapBefore = s.anchorPrice > s.highWaterMark ? s.anchorPrice - s.highWaterMark : 0;
        uint256 gapAfter = moved > next.highWaterMark ? moved - next.highWaterMark : 0;
        assertLe(gapAfter, gapBefore, "a drift widened the gap over the high-water mark");
        uint256 step = moved > s.anchorPrice ? moved - s.anchorPrice : 0;
        assertLe(next.highWaterMark - s.highWaterMark, step, "the high-water mark rose past the drift's step");
    }

    // ---
    // UPDATE ANCHOR: FLOOR
    // ---

    /// @dev A 5% fall waits out the delay and then moves the anchor only onto the floor, 1% under the high-water mark.
    ///      The price, still outside the floor's bounds, keeps reverting and is recorded as the next pending anchor.
    function test_updateAnchor_reanchorDownStopsAtTheFloor() public {
        uint256 fallen = Math.mulDiv(INITIAL_PRICE, 0.95e18, WAD);
        source.setCurrentPrice(fallen);
        _update();
        vm.warp(START + DELAY);
        TrailingAnchorOracleUpdate memory u = _update();
        uint256 floorPrice = _floor(INITIAL_PRICE);
        assertTrue(u.anchorSet && u.pendingAnchorSet, "onto the floor, and the price recorded again");
        assertEq(_read().anchorPrice, floorPrice, "the anchor on the floor");
        assertEq(_read().pendingAnchorPrice, fallen, "the price is the next pending anchor");
        assertEq(_read().highWaterMark, INITIAL_PRICE, "the high-water mark stays");
        vm.expectRevert(
            abi.encodeWithSelector(
                TrailingAnchorOracleBase.PriceOutOfBounds.selector, fallen, _lower(floorPrice), _upper(floorPrice)
            )
        );
        oracle.price();
    }

    /// @dev On the floor with the price still under its bounds, an update in the next window changes nothing. Once that
    ///      pending anchor expires, the next update records the price again, and the anchor stays on the floor.
    function test_updateAnchor_pinnedOnTheFloorChangesNothing() public {
        source.setCurrentPrice(Math.mulDiv(INITIAL_PRICE, 0.95e18, WAD));
        _update();
        vm.warp(START + DELAY);
        _update();
        TrailingAnchorOracleState memory pinned = _read();
        vm.warp(START + 2 * DELAY);
        TrailingAnchorOracleUpdate memory u = _update();
        assertFalse(u.anchorSet || u.pendingAnchorSet || u.pendingAnchorCleared, "nothing changes");
        _assertState(pinned);
        vm.warp(START + 2 * DELAY + WINDOW + 1);
        u = _update();
        assertFalse(u.anchorSet, "the anchor stays");
        assertTrue(u.pendingAnchorSet, "the price recorded again");
        assertEq(_read().anchorPrice, _floor(INITIAL_PRICE), "on the floor");
    }

    /// @dev A source that leaves the lower bound by 0.2% of the anchor in every window walks the anchor down one step a
    ///      window and stops it on the floor, however many windows follow.
    function test_updateAnchor_walkStopsAtTheFloor() public {
        uint256 floorPrice = _floor(INITIAL_PRICE);
        for (uint256 i; i < 20; ++i) {
            uint256 anchorBefore = _read().anchorPrice;
            source.setCurrentPrice(Math.mulDiv(anchorBefore, 0.998e18, WAD));
            _update();
            vm.warp(block.timestamp + DELAY);
            _update();
            assertLe(_read().anchorPrice, anchorBefore, "never up");
            assertGe(_read().anchorPrice, floorPrice, "never under the floor");
        }
        assertEq(_read().anchorPrice, floorPrice, "on the floor");
        uint256 deeper = Math.mulDiv(floorPrice, 0.998e18, WAD);
        source.setCurrentPrice(deeper);
        vm.expectRevert(
            abi.encodeWithSelector(
                TrailingAnchorOracleBase.PriceOutOfBounds.selector, deeper, _lower(floorPrice), _upper(floorPrice)
            )
        );
        oracle.price();
    }

    /// @dev A drift stops on the floor too: at a fall speed of a whole price a year, a price held on the lower bound
    ///      walks the anchor down every day until the floor, and no further.
    function test_updateAnchor_driftStopsAtTheFloor() public {
        TrailingAnchorOracleBase.Parameters memory p = TrailingAnchorOracleModel.defaultParameters();
        p.maxAnchorFallPerYear = uint64(WAD);
        _setParameters(p);
        uint256 floorPrice = _floor(INITIAL_PRICE);
        for (uint256 day = 1; day <= 30; ++day) {
            vm.warp(START + day * 1 days);
            source.setCurrentPrice(_lower(_read().anchorPrice));
            _update();
            assertGe(_read().anchorPrice, floorPrice, "never under the floor");
        }
        assertEq(_read().anchorPrice, floorPrice, "on the floor");
    }

    /// @dev The high-water mark follows a drift up onto the anchor, stays through a re-anchor up, rises with the next
    ///      drift by its step only, so the anchor keeps its gap over it, and stays when the anchor falls.
    function test_updateAnchor_highWaterMarkFollowsDriftsOnly() public {
        vm.warp(START + 1 days);
        source.setCurrentPrice(_upper(INITIAL_PRICE));
        _update();
        uint256 drifted = _read().anchorPrice;
        assertGt(drifted, INITIAL_PRICE, "drifted up");
        assertEq(_read().highWaterMark, drifted, "follows a drift");

        source.setCurrentPrice(Math.mulDiv(drifted, 1.05e18, WAD));
        _update();
        vm.warp(block.timestamp + DELAY);
        _update();
        uint256 capped = _ceiling(drifted);
        assertEq(_read().anchorPrice, capped, "re-anchored up onto the ceiling");
        assertEq(_read().highWaterMark, drifted, "stays through a re-anchor");

        vm.warp(block.timestamp + 1 days);
        source.setCurrentPrice(_upper(capped));
        _update();
        uint256 step = Math.mulDiv(capped, MAX_ANCHOR_RISE_PER_YEAR * 1 days, WAD * YEAR);
        assertEq(_read().anchorPrice, capped + step, "drifted up from the ceiling");
        assertEq(_read().highWaterMark, drifted + step, "rises by the drift's step");

        uint256 top = capped + step;
        uint256 fallen = Math.mulDiv(top, 0.995e18, WAD);
        source.setCurrentPrice(fallen);
        _update();
        vm.warp(block.timestamp + DELAY);
        _update();
        assertEq(_read().anchorPrice, fallen, "re-anchored down");
        vm.warp(block.timestamp + 1 days);
        source.setCurrentPrice(_lower(fallen));
        _update();
        assertLt(_read().anchorPrice, fallen, "drifted down");
        assertEq(_read().highWaterMark, drifted + step, "stays through both falls");
    }

    /// @dev A zero `maxAnchorBelowMark` stops every open fall: neither a drift nor a re-anchor lowers the anchor, while
    ///      a drift still raises it.
    function test_updateAnchor_zeroBelowMarkStopsEveryOpenFall() public {
        TrailingAnchorOracleBase.Parameters memory p = TrailingAnchorOracleModel.defaultParameters();
        p.maxAnchorBelowMark = 0;
        _setParameters(p);
        vm.warp(START + 1 days);
        source.setCurrentPrice(_lower(INITIAL_PRICE));
        assertFalse(_update().anchorSet, "no drift down");
        source.setCurrentPrice(Math.mulDiv(INITIAL_PRICE, 0.99e18, WAD));
        _update();
        vm.warp(block.timestamp + DELAY);
        assertFalse(_update().anchorSet, "no re-anchor down");
        source.setCurrentPrice(_upper(INITIAL_PRICE));
        assertTrue(_update().anchorSet, "a drift up");
    }

    // ---
    // UPDATE ANCHOR: CEILING
    // ---

    /// @dev A 5% rise waits out the delay and then moves the anchor only onto the ceiling, 0.2% over the high-water
    ///      mark. The price, still outside the ceiling's bounds, keeps reverting and is recorded as the next pending
    ///      anchor, and the high-water mark stays.
    function test_updateAnchor_reanchorUpStopsAtTheCeiling() public {
        uint256 risen = Math.mulDiv(INITIAL_PRICE, 1.05e18, WAD);
        source.setCurrentPrice(risen);
        _update();
        vm.warp(START + DELAY);
        TrailingAnchorOracleUpdate memory u = _update();
        uint256 ceilingPrice = _ceiling(INITIAL_PRICE);
        assertTrue(u.anchorSet && u.pendingAnchorSet, "onto the ceiling, and the price recorded again");
        assertEq(_read().anchorPrice, ceilingPrice, "the anchor on the ceiling");
        assertEq(_read().pendingAnchorPrice, risen, "the price is the next pending anchor");
        assertEq(_read().highWaterMark, INITIAL_PRICE, "the high-water mark stays");
        vm.expectRevert(
            abi.encodeWithSelector(
                TrailingAnchorOracleBase.PriceOutOfBounds.selector, risen, _lower(ceilingPrice), _upper(ceilingPrice)
            )
        );
        oracle.price();
    }

    /// @dev On the ceiling with the price still over its bounds, an update in the next window changes nothing. Once
    ///      that pending anchor expires, the next update records the price again, and the anchor stays on the ceiling.
    function test_updateAnchor_pinnedOnTheCeilingChangesNothing() public {
        source.setCurrentPrice(Math.mulDiv(INITIAL_PRICE, 1.05e18, WAD));
        _update();
        vm.warp(START + DELAY);
        _update();
        TrailingAnchorOracleState memory pinned = _read();
        vm.warp(START + 2 * DELAY);
        TrailingAnchorOracleUpdate memory u = _update();
        assertFalse(u.anchorSet || u.pendingAnchorSet || u.pendingAnchorCleared, "nothing changes");
        assertEq(uint8(u.outcome), uint8(TrailingAnchorOracleBase.UpdateOutcome.AnchorOnCeiling), "AnchorOnCeiling");
        _assertState(pinned);
        vm.warp(START + 2 * DELAY + WINDOW + 1);
        u = _update();
        assertFalse(u.anchorSet, "the anchor stays");
        assertTrue(u.pendingAnchorSet, "the price recorded again");
        assertEq(_read().anchorPrice, _ceiling(INITIAL_PRICE), "on the ceiling");
    }

    /// @dev A source that leaves the upper bound by 0.03% of the anchor in every window walks the anchor up one step a
    ///      window and stops it on the ceiling, however many windows follow.
    function test_updateAnchor_walkStopsAtTheCeiling() public {
        uint256 ceilingPrice = _ceiling(INITIAL_PRICE);
        for (uint256 i; i < 20; ++i) {
            uint256 anchorBefore = _read().anchorPrice;
            source.setCurrentPrice(Math.mulDiv(anchorBefore, 1.0008e18, WAD));
            _update();
            vm.warp(block.timestamp + DELAY);
            _update();
            assertGe(_read().anchorPrice, anchorBefore, "never down");
            assertLe(_read().anchorPrice, ceilingPrice, "never over the ceiling");
            assertEq(_read().highWaterMark, INITIAL_PRICE, "the high-water mark stays");
        }
        assertEq(_read().anchorPrice, ceilingPrice, "on the ceiling");
        uint256 higher = Math.mulDiv(ceilingPrice, 1.0008e18, WAD);
        source.setCurrentPrice(higher);
        vm.expectRevert(
            abi.encodeWithSelector(
                TrailingAnchorOracleBase.PriceOutOfBounds.selector, higher, _lower(ceilingPrice), _upper(ceilingPrice)
            )
        );
        oracle.price();
    }

    /// @dev A zero `maxAnchorAboveMark` keeps every re-anchor up at the high-water mark: from the floor, a rise
    ///      re-anchors back onto it and no higher, while a drift still raises the anchor and the high-water mark with
    ///      it.
    function test_updateAnchor_zeroAboveMarkStopsReanchorsOverTheMark() public {
        TrailingAnchorOracleBase.Parameters memory p = TrailingAnchorOracleModel.defaultParameters();
        p.maxAnchorAboveMark = 0;
        _setParameters(p);
        source.setCurrentPrice(Math.mulDiv(INITIAL_PRICE, 0.95e18, WAD));
        _update();
        vm.warp(START + DELAY);
        _update();
        assertEq(_read().anchorPrice, _floor(INITIAL_PRICE), "on the floor");
        source.setCurrentPrice(Math.mulDiv(INITIAL_PRICE, 1.05e18, WAD));
        _update();
        vm.warp(block.timestamp + DELAY);
        _update();
        assertEq(_read().anchorPrice, INITIAL_PRICE, "back onto the high-water mark, no higher");
        vm.warp(block.timestamp + DELAY);
        assertFalse(_update().anchorSet, "no re-anchor over it");
        vm.warp(block.timestamp + 1 days);
        source.setCurrentPrice(_upper(INITIAL_PRICE));
        assertTrue(_update().anchorSet, "a drift up");
        assertEq(_read().highWaterMark, _read().anchorPrice, "the high-water mark follows the drift");
    }

    // ---
    // ACCEPT PRICE
    // ---

    /// @dev Only the price acceptor: neither the admin nor the manager.
    function testRevert_acceptPrice_notPriceAcceptor() public {
        bytes32 role = oracle.PRICE_ACCEPTOR_ROLE();
        address[3] memory callers = [anyone, admin, manager];
        for (uint256 i; i < callers.length; ++i) {
            vm.expectRevert(
                abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, callers[i], role)
            );
            vm.prank(callers[i]);
            oracle.acceptPrice(0, type(uint256).max);
        }
    }

    /// @dev The price acceptor takes a price at any distance and drops the pending anchor; `price()` returns it at
    ///      once.
    function test_acceptPrice_anyDistanceDropsPendingAnchor() public {
        uint256 currentPrice = INITIAL_PRICE / 2;
        source.setCurrentPrice(currentPrice);
        _update();
        vm.warp(START + 2 days);
        TrailingAnchorOracleState memory expected = _read().accepted(currentPrice, START + 2 days);
        vm.expectEmit(address(oracle));
        emit TrailingAnchorOracleBase.AnchorSet(currentPrice, uint40(START + 2 days), true);
        vm.expectEmit(address(oracle));
        emit TrailingAnchorOracleBase.PendingAnchorCleared();
        vm.prank(priceAcceptor);
        oracle.acceptPrice(currentPrice, currentPrice);
        _assertState(expected);
        assertEq(oracle.price(), currentPrice * priceScale, "price follows at once");
    }

    /// @dev Only an acceptance goes under the floor. It moves the anchor onto the price and restarts the high-water
    ///      mark there, downward too, so the next floor hangs off the accepted price.
    function test_acceptPrice_underTheFloorRestartsTheHighWaterMark() public {
        uint256 fallen = Math.mulDiv(INITIAL_PRICE, 0.95e18, WAD);
        source.setCurrentPrice(fallen);
        _update();
        vm.warp(START + DELAY);
        _update();
        assertEq(_read().anchorPrice, _floor(INITIAL_PRICE), "held on the floor");
        vm.prank(priceAcceptor);
        oracle.acceptPrice(fallen, fallen);
        assertEq(_read().anchorPrice, fallen, "accepted under the floor");
        assertEq(_read().highWaterMark, fallen, "the high-water mark restarts at the accepted price");
        assertEq(oracle.price(), fallen * priceScale, "priced");

        source.setCurrentPrice(Math.mulDiv(fallen, 0.95e18, WAD));
        _update();
        vm.warp(block.timestamp + DELAY);
        _update();
        assertEq(_read().anchorPrice, _floor(fallen), "the next floor, under the accepted price");
    }

    /// @dev Only an acceptance goes over the ceiling. It moves the anchor onto the price and restarts the high-water
    ///      mark there, so the next ceiling hangs off the accepted price.
    function test_acceptPrice_overTheCeilingRestartsTheHighWaterMark() public {
        uint256 risen = Math.mulDiv(INITIAL_PRICE, 1.05e18, WAD);
        source.setCurrentPrice(risen);
        _update();
        vm.warp(START + DELAY);
        _update();
        assertEq(_read().anchorPrice, _ceiling(INITIAL_PRICE), "held on the ceiling");
        vm.prank(priceAcceptor);
        oracle.acceptPrice(risen, risen);
        assertEq(_read().anchorPrice, risen, "accepted over the ceiling");
        assertEq(_read().highWaterMark, risen, "the high-water mark restarts at the accepted price");
        assertEq(oracle.price(), risen * priceScale, "priced");

        source.setCurrentPrice(Math.mulDiv(risen, 1.05e18, WAD));
        _update();
        vm.warp(block.timestamp + DELAY);
        _update();
        assertEq(_read().anchorPrice, _ceiling(risen), "the next ceiling, over the accepted price");
    }

    /// @dev Both edges of the range are taken; a price one wei outside it is refused with the range.
    function test_acceptPrice_rangeEdgesInclusive() public {
        uint256 currentPrice = INITIAL_PRICE / 2;
        source.setCurrentPrice(currentPrice);
        vm.prank(priceAcceptor);
        vm.expectRevert(
            abi.encodeWithSelector(
                TrailingAnchorOracleBase.UnexpectedPrice.selector, currentPrice, currentPrice + 1, currentPrice + 2
            )
        );
        oracle.acceptPrice(currentPrice + 1, currentPrice + 2);
        vm.prank(priceAcceptor);
        vm.expectRevert(
            abi.encodeWithSelector(
                TrailingAnchorOracleBase.UnexpectedPrice.selector, currentPrice, currentPrice - 2, currentPrice - 1
            )
        );
        oracle.acceptPrice(currentPrice - 2, currentPrice - 1);

        vm.prank(priceAcceptor);
        oracle.acceptPrice(currentPrice, currentPrice + 1);
        assertEq(_read().anchorPrice, currentPrice, "the lower edge");
        source.setCurrentPrice(currentPrice + 7);
        vm.prank(priceAcceptor);
        oracle.acceptPrice(currentPrice + 6, currentPrice + 7);
        assertEq(_read().anchorPrice, currentPrice + 7, "the upper edge");
    }

    /// @dev An acceptance needs no time since the anchor moved and runs during a suspension.
    function test_acceptPrice_inTheSeedsBlockDuringSuspension() public {
        vm.prank(manager);
        oracle.setPricingResumesAt(uint40(START + 1 days));
        source.setCurrentPrice(INITIAL_PRICE + 1);
        vm.prank(priceAcceptor);
        oracle.acceptPrice(INITIAL_PRICE + 1, INITIAL_PRICE + 1);
        assertEq(_read().anchorPrice, INITIAL_PRICE + 1, "accepted in the seed's block");
        assertEq(_read().anchorAt, START, "at the seed's time");
    }

    function testRevert_acceptPrice_sourceFails() public {
        source.setCurrentPrice(0);
        vm.prank(priceAcceptor);
        vm.expectRevert(TrailingAnchorOracleBase.ZeroPrice.selector);
        oracle.acceptPrice(0, 0);
        source.setCurrentPrice(INITIAL_PRICE);
        source.setDown(true);
        vm.prank(priceAcceptor);
        vm.expectRevert(SourceDown.selector);
        oracle.acceptPrice(0, type(uint256).max);
    }

    // ---
    // PRICING SUSPENSION
    // ---

    function testRevert_setPricingResumesAt_notManager() public {
        bytes32 role = oracle.MANAGER_ROLE();
        address[3] memory callers = [anyone, admin, priceAcceptor];
        for (uint256 i; i < callers.length; ++i) {
            vm.expectRevert(
                abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, callers[i], role)
            );
            vm.prank(callers[i]);
            oracle.setPricingResumesAt(uint40(START + 1 days));
        }
    }

    /// @dev `price()` reverts with the resume time until it, and returns from that second on.
    function test_setPricingResumesAt_suspendsUntilTheTime() public {
        vm.expectEmit(address(oracle));
        emit TrailingAnchorOracleBase.PricingResumesAtSet(uint40(START + 1 days));
        vm.prank(manager);
        oracle.setPricingResumesAt(uint40(START + 1 days));
        vm.warp(START + 1 days - 1);
        vm.expectRevert(
            abi.encodeWithSelector(TrailingAnchorOracleBase.PricingSuspended.selector, uint40(START + 1 days))
        );
        oracle.price();
        vm.warp(START + 1 days);
        assertEq(oracle.price(), INITIAL_PRICE * priceScale, "priced at the resume time");
    }

    /// @dev At most `MAX_PRICING_SUSPENSION` from the call, inclusive.
    function test_setPricingResumesAt_capEdge() public {
        vm.startPrank(manager);
        oracle.setPricingResumesAt(uint40(START + 7 days));
        assertEq(oracle.pricingResumesAt(), START + 7 days, "the cap itself");
        vm.expectRevert(
            abi.encodeWithSelector(TrailingAnchorOracleBase.InvalidPricingResumesAt.selector, START + 7 days + 1)
        );
        oracle.setPricingResumesAt(uint40(START + 7 days + 1));
        vm.stopPrank();
        assertEq(oracle.MAX_PRICING_SUSPENSION(), 7 days, "MAX_PRICING_SUSPENSION");
    }

    /// @dev A time not in the future lifts a suspension at once.
    function test_setPricingResumesAt_pastLifts() public {
        vm.startPrank(manager);
        oracle.setPricingResumesAt(uint40(START + 3 days));
        oracle.setPricingResumesAt(uint40(START));
        vm.stopPrank();
        assertEq(oracle.price(), INITIAL_PRICE * priceScale, "lifted");
    }

    /// @dev Updates run during a suspension: the anchor follows the price and a pending anchor is recorded.
    function test_setPricingResumesAt_updatesRunDuringSuspension() public {
        _withoutFloor();
        vm.prank(manager);
        oracle.setPricingResumesAt(uint40(START + 3 days));
        source.setCurrentPrice(Math.mulDiv(INITIAL_PRICE, 0.9e18, WAD));
        _update();
        assertGt(_read().pendingAnchorAt, 0, "a pending anchor");
        vm.warp(START + DELAY);
        _update();
        assertEq(_read().anchorPrice, Math.mulDiv(INITIAL_PRICE, 0.9e18, WAD), "re-anchored while suspended");
    }

    // ---
    // PARAMETERS
    // ---

    /// @dev Only the manager: neither the admin nor the price acceptor.
    function testRevert_setParameters_notManager() public {
        bytes32 role = oracle.MANAGER_ROLE();
        TrailingAnchorOracleBase.Parameters memory p = TrailingAnchorOracleModel.defaultParameters();
        address[3] memory callers = [anyone, admin, priceAcceptor];
        for (uint256 i; i < callers.length; ++i) {
            vm.expectRevert(
                abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, callers[i], role)
            );
            vm.prank(callers[i]);
            oracle.setParameters(p);
        }
    }

    /// @dev The manager stores every parameter at once; the anchor stays and the pending anchor is dropped.
    function test_setParameters_storesAndDropsPendingAnchor() public {
        source.setCurrentPrice(Math.mulDiv(INITIAL_PRICE, 0.9e18, WAD));
        _update();
        vm.warp(START + 3 days);
        TrailingAnchorOracleBase.Parameters memory p = TrailingAnchorOracleBase.Parameters({
            maxPriceAboveAnchor: 0.001e18,
            maxPriceBelowAnchor: 0.002e18,
            maxAnchorRisePerYear: 0.1e18,
            maxAnchorFallPerYear: 0.05e18,
            maxAnchorBelowMark: 0.02e18,
            maxAnchorAboveMark: 0.005e18,
            reanchorDelay: 12 hours,
            reanchorWindow: 2 days
        });
        TrailingAnchorOracleState memory expected = _read().withParameters(p);
        vm.expectEmit(address(oracle));
        emit TrailingAnchorOracleBase.ParametersSet(p);
        vm.expectEmit(address(oracle));
        emit TrailingAnchorOracleBase.PendingAnchorCleared();
        vm.prank(manager);
        oracle.setParameters(p);
        _assertState(expected);
    }

    /// @dev Narrower bounds apply at once: they refuse a price the old ones took.
    function test_setParameters_boundsApplyAtOnce() public {
        uint256 currentPrice = Math.mulDiv(INITIAL_PRICE, 1.0004e18, WAD);
        source.setCurrentPrice(currentPrice);
        assertEq(oracle.price(), currentPrice * priceScale, "0.04% up inside 0.05%");
        TrailingAnchorOracleBase.Parameters memory p = TrailingAnchorOracleModel.defaultParameters();
        p.maxPriceAboveAnchor = 0.0003e18;
        _setParameters(p);
        assertFalse(_read().withinBounds(currentPrice), "0.04% up outside 0.03%");
        _assertPriceMatchesRule();
    }

    /// @dev A narrower `maxAnchorBelowMark` leaves an anchor already under its floor where it is: no update lifts it, a
    ///      drift does not lower it, and the next fall finds it pinned.
    function test_setParameters_narrowerBelowMarkKeepsADeeperAnchor() public {
        uint256 fallen = Math.mulDiv(INITIAL_PRICE, 0.992e18, WAD);
        source.setCurrentPrice(fallen);
        _update();
        vm.warp(START + DELAY);
        _update();
        assertEq(_read().anchorPrice, fallen, "0.8% down, inside the 1% floor");
        TrailingAnchorOracleBase.Parameters memory p = TrailingAnchorOracleModel.defaultParameters();
        p.maxAnchorBelowMark = 0.005e18;
        _setParameters(p);
        vm.warp(block.timestamp + 1 days);
        assertFalse(_update().anchorSet, "not lifted onto the narrower floor");
        source.setCurrentPrice(_lower(fallen));
        assertFalse(_update().anchorSet, "no drift under the anchor");
        source.setCurrentPrice(Math.mulDiv(fallen, 0.99e18, WAD));
        _update();
        vm.warp(block.timestamp + DELAY);
        assertFalse(_update().anchorSet, "pinned");
        assertEq(_read().anchorPrice, fallen, "kept");
    }

    /// @dev A narrower `maxAnchorAboveMark` leaves an anchor already over its ceiling where it is: no update lowers it,
    ///      a drift up moves it with the high-water mark and keeps its gap over it, and the next rise finds it pinned.
    function test_setParameters_narrowerAboveMarkKeepsAHigherAnchor() public {
        uint256 risen = Math.mulDiv(INITIAL_PRICE, 1.0015e18, WAD);
        source.setCurrentPrice(risen);
        _update();
        vm.warp(START + DELAY);
        _update();
        assertEq(_read().anchorPrice, risen, "0.15% up, inside the 0.2% ceiling");
        TrailingAnchorOracleBase.Parameters memory p = TrailingAnchorOracleModel.defaultParameters();
        p.maxAnchorAboveMark = 0.001e18;
        _setParameters(p);
        vm.warp(block.timestamp + 1 days);
        assertFalse(_update().anchorSet, "not lowered onto the narrower ceiling");
        vm.warp(block.timestamp + 1 days);
        source.setCurrentPrice(_upper(risen));
        _update();
        uint256 step = Math.mulDiv(risen, MAX_ANCHOR_RISE_PER_YEAR * 2 days, WAD * YEAR);
        assertEq(_read().anchorPrice, risen + step, "a drift up");
        assertEq(_read().highWaterMark, INITIAL_PRICE + step, "the gap kept");
        source.setCurrentPrice(Math.mulDiv(risen + step, 1.001e18, WAD));
        _update();
        vm.warp(block.timestamp + DELAY);
        assertFalse(_update().anchorSet, "pinned");
        assertEq(_read().anchorPrice, risen + step, "kept");
    }

    /// @dev Each validator edge: the last valid value is taken and the first invalid one refused.
    function test_setParameters_validatorEdges() public {
        TrailingAnchorOracleBase.Parameters memory p = TrailingAnchorOracleModel.defaultParameters();
        // A one-wei upper bound leaves the delay rule room only with the rise speed off.
        p.maxPriceAboveAnchor = 1;
        p.maxPriceBelowAnchor = 1;
        p.maxAnchorRisePerYear = 0;
        _setParameters(p);
        p = TrailingAnchorOracleModel.defaultParameters();
        p.maxPriceAboveAnchor = uint64(WAD - 1);
        p.maxPriceBelowAnchor = uint64(WAD - 1);
        _setParameters(p);
        p = TrailingAnchorOracleModel.defaultParameters();
        p.maxAnchorRisePerYear = uint64(WAD);
        p.maxAnchorFallPerYear = 0;
        p.reanchorDelay = 1 hours;
        p.reanchorWindow = 1;
        _setParameters(p);
        // The longest delay the rule takes: the rise speed covers exactly the upper bound in it.
        p = TrailingAnchorOracleModel.defaultParameters();
        p.reanchorDelay = uint40(MAX_PRICE_ABOVE_ANCHOR * YEAR / MAX_ANCHOR_RISE_PER_YEAR);
        _setParameters(p);
        p = TrailingAnchorOracleModel.defaultParameters();
        p.maxAnchorBelowMark = 0;
        _setParameters(p);
        p.maxAnchorBelowMark = uint64(WAD - 1);
        _setParameters(p);
        p = TrailingAnchorOracleModel.defaultParameters();
        p.maxAnchorAboveMark = 0;
        _setParameters(p);
        p.maxAnchorAboveMark = uint64(WAD - 1);
        _setParameters(p);
        TrailingAnchorOracleBase.Parameters[] memory cases = _invalidParameters();
        for (uint256 i; i < cases.length; ++i) {
            vm.prank(manager);
            vm.expectRevert(TrailingAnchorOracleBase.InvalidParameters.selector);
            oracle.setParameters(cases[i]);
        }
    }

    // ---
    // STORAGE
    // ---

    /// @dev The base's state lives in the adapter's own namespace, low bits first: the bounds, `anchorAt` and
    ///      `pricingResumesAt` in the first slot, the anchor price in the second, the speeds, the delay, the window and
    ///      `pendingAnchorAt` in the third, the pending anchor price in the fourth, `maxAnchorBelowMark` and
    ///      `maxAnchorAboveMark` in the fifth and `highWaterMark` in the sixth.
    function test_storage_namespaceLayout() public {
        vm.prank(manager);
        oracle.setPricingResumesAt(uint40(START + 1 days));
        vm.warp(START + 1 hours);
        uint256 currentPrice = Math.mulDiv(INITIAL_PRICE, 0.9e18, WAD);
        source.setCurrentPrice(currentPrice);
        _update();
        bytes32 base = TrailingAnchorOracleModel.namespaceSlot(_namespace());
        uint256 first = uint256(vm.load(address(oracle), base));
        assertEq(uint64(first), MAX_PRICE_ABOVE_ANCHOR, "maxPriceAboveAnchor in bits 0-63");
        assertEq(uint64(first >> 64), MAX_PRICE_BELOW_ANCHOR, "maxPriceBelowAnchor in bits 64-127");
        assertEq(uint40(first >> 128), START, "anchorAt in bits 128-167");
        assertEq(uint40(first >> 168), START + 1 days, "pricingResumesAt in bits 168-207");
        assertEq(first >> 208, 0, "nothing above in the first slot");
        assertEq(uint256(vm.load(address(oracle), _slot(base, 1))), INITIAL_PRICE, "anchorPrice in the second slot");
        uint256 third = uint256(vm.load(address(oracle), _slot(base, 2)));
        assertEq(uint64(third), MAX_ANCHOR_RISE_PER_YEAR, "maxAnchorRisePerYear in bits 0-63");
        assertEq(uint64(third >> 64), MAX_ANCHOR_FALL_PER_YEAR, "maxAnchorFallPerYear in bits 64-127");
        assertEq(uint40(third >> 128), DELAY, "reanchorDelay in bits 128-167");
        assertEq(uint40(third >> 168), WINDOW, "reanchorWindow in bits 168-207");
        assertEq(uint40(third >> 208), START + 1 hours, "pendingAnchorAt in bits 208-247");
        assertEq(third >> 248, 0, "nothing above in the third slot");
        assertEq(
            uint256(vm.load(address(oracle), _slot(base, 3))), currentPrice, "pendingAnchorPrice in the fourth slot"
        );
        uint256 fifth = uint256(vm.load(address(oracle), _slot(base, 4)));
        assertEq(uint64(fifth), MAX_ANCHOR_BELOW_MARK, "maxAnchorBelowMark in bits 0-63");
        assertEq(uint64(fifth >> 64), MAX_ANCHOR_ABOVE_MARK, "maxAnchorAboveMark in bits 64-127");
        assertEq(fifth >> 128, 0, "nothing above in the fifth slot");
        assertEq(uint256(vm.load(address(oracle), _slot(base, 5))), INITIAL_PRICE, "highWaterMark in the sixth slot");
        assertEq(uint256(vm.load(address(oracle), _slot(base, 6))), 0, "nothing in the seventh slot");
    }

    // ---
    // HELPERS
    // ---

    function _read() internal view returns (TrailingAnchorOracleState memory) {
        return TrailingAnchorOracleModel.read(oracle);
    }

    /// @dev Runs `updateAnchor()` as anyone and checks it against the model: the revert, or the stored state and the
    ///      exact logs.
    function _update() internal returns (TrailingAnchorOracleUpdate memory u) {
        TrailingAnchorOracleState memory s = _read();
        u = s.update(source.currentPrice(), source.isDown(), block.timestamp);
        if (u.revertData.length != 0) {
            vm.expectRevert(u.revertData);
            oracle.updateAnchor();
            _assertState(s);
            return u;
        }
        vm.recordLogs();
        vm.prank(anyone);
        TrailingAnchorOracleBase.UpdateOutcome outcome = oracle.updateAnchor();
        assertEq(uint8(outcome), uint8(u.outcome), "outcome");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 i;
        if (u.anchorSet) {
            assertEq(logs[i].topics[0], TrailingAnchorOracleBase.AnchorSet.selector, "AnchorSet");
            assertEq(logs[i].data, abi.encode(u.next.anchorPrice, uint40(block.timestamp), false), "AnchorSet data");
            ++i;
        }
        if (u.pendingAnchorSet) {
            assertEq(logs[i].topics[0], TrailingAnchorOracleBase.PendingAnchorSet.selector, "PendingAnchorSet");
            assertEq(
                logs[i].data, abi.encode(u.next.pendingAnchorPrice, uint40(block.timestamp)), "PendingAnchorSet data"
            );
            ++i;
        }
        if (u.pendingAnchorCleared) {
            assertEq(logs[i].topics[0], TrailingAnchorOracleBase.PendingAnchorCleared.selector, "PendingAnchorCleared");
            ++i;
        }
        assertEq(logs[i].topics[0], TrailingAnchorOracleBase.AnchorUpdated.selector, "AnchorUpdated last");
        assertEq(logs[i].topics[1], bytes32(uint256(uint8(u.outcome))), "AnchorUpdated outcome");
        assertEq(logs[i].data, abi.encode(source.currentPrice()), "AnchorUpdated currentPrice");
        assertEq(logs.length, i + 1, "no other logs");
        _assertState(u.next);
    }

    /// @dev Runs `_update()` and checks the outcome it returned against `expected`, written out in the test.
    function _assertOutcome(TrailingAnchorOracleBase.UpdateOutcome expected) internal {
        assertEq(uint8(_update().outcome), uint8(expected), "outcome");
    }

    /// @dev Updates, then waits for each pending anchor's window, until the price sits within the bounds. Returns the
    ///      number of re-anchors.
    function _walk() internal returns (uint256 reanchors) {
        _update();
        while (!_read().withinBounds(source.currentPrice())) {
            vm.warp(_read().pendingAnchorAt + _read().reanchorDelay);
            assertTrue(_update().anchorSet, "re-anchored when the window opened");
            ++reanchors;
        }
    }

    /// @dev `price()` against the rules over the stored state, the source and the time.
    function _assertPriceMatchesRule() internal {
        TrailingAnchorOracleState memory s = _read();
        bytes memory expected = s.priceRevert(source.currentPrice(), source.isDown(), block.timestamp);
        if (expected.length != 0) {
            vm.expectRevert(expected);
            oracle.price();
            return;
        }
        assertEq(oracle.price(), source.currentPrice() * priceScale, "price != current price x PRICE_SCALE");
    }

    function _assertState(TrailingAnchorOracleState memory e) internal view {
        TrailingAnchorOracleState memory s = _read();
        assertEq(s.anchorPrice, e.anchorPrice, "anchorPrice");
        assertEq(s.anchorAt, e.anchorAt, "anchorAt");
        assertEq(s.pricingResumesAt, e.pricingResumesAt, "pricingResumesAt");
        assertEq(s.pendingAnchorPrice, e.pendingAnchorPrice, "pendingAnchorPrice");
        assertEq(s.pendingAnchorAt, e.pendingAnchorAt, "pendingAnchorAt");
        assertEq(s.highWaterMark, e.highWaterMark, "highWaterMark");
        assertEq(s.maxPriceAboveAnchor, e.maxPriceAboveAnchor, "maxPriceAboveAnchor");
        assertEq(s.maxPriceBelowAnchor, e.maxPriceBelowAnchor, "maxPriceBelowAnchor");
        assertEq(s.maxAnchorRisePerYear, e.maxAnchorRisePerYear, "maxAnchorRisePerYear");
        assertEq(s.maxAnchorFallPerYear, e.maxAnchorFallPerYear, "maxAnchorFallPerYear");
        assertEq(s.maxAnchorBelowMark, e.maxAnchorBelowMark, "maxAnchorBelowMark");
        assertEq(s.maxAnchorAboveMark, e.maxAnchorAboveMark, "maxAnchorAboveMark");
        assertEq(s.reanchorDelay, e.reanchorDelay, "reanchorDelay");
        assertEq(s.reanchorWindow, e.reanchorWindow, "reanchorWindow");
    }

    function _assertParameters(TrailingAnchorOracleState memory s, TrailingAnchorOracleBase.Parameters memory p)
        internal
        pure
    {
        assertEq(s.maxPriceAboveAnchor, p.maxPriceAboveAnchor, "maxPriceAboveAnchor");
        assertEq(s.maxPriceBelowAnchor, p.maxPriceBelowAnchor, "maxPriceBelowAnchor");
        assertEq(s.maxAnchorRisePerYear, p.maxAnchorRisePerYear, "maxAnchorRisePerYear");
        assertEq(s.maxAnchorFallPerYear, p.maxAnchorFallPerYear, "maxAnchorFallPerYear");
        assertEq(s.maxAnchorBelowMark, p.maxAnchorBelowMark, "maxAnchorBelowMark");
        assertEq(s.maxAnchorAboveMark, p.maxAnchorAboveMark, "maxAnchorAboveMark");
        assertEq(s.reanchorDelay, p.reanchorDelay, "reanchorDelay");
        assertEq(s.reanchorWindow, p.reanchorWindow, "reanchorWindow");
    }

    function _setParameters(TrailingAnchorOracleBase.Parameters memory p) internal {
        assertEq(TrailingAnchorOracleModel.parametersRevert(p).length, 0, "the model takes the parameters");
        vm.prank(manager);
        oracle.setParameters(p);
    }

    /// @dev Moves the floor out of the way, a wei or two above zero, for the tests of the re-anchor mechanics on falls
    ///      past the working floor; the floor has tests of its own.
    function _withoutFloor() internal {
        TrailingAnchorOracleBase.Parameters memory p = TrailingAnchorOracleModel.defaultParameters();
        p.maxAnchorBelowMark = uint64(WAD - 1);
        _setParameters(p);
    }

    /// @dev Moves the ceiling out of the way, almost a whole price over the high-water mark, for the tests of the
    ///      re-anchor mechanics on rises past the working ceiling; the ceiling has tests of its own.
    function _withoutCeiling() internal {
        TrailingAnchorOracleBase.Parameters memory p = TrailingAnchorOracleModel.defaultParameters();
        p.maxAnchorAboveMark = uint64(WAD - 1);
        _setParameters(p);
    }

    /// @dev `mark` × (1 − `MAX_ANCHOR_BELOW_MARK`), the distance term rounded down.
    function _floor(uint256 mark) internal pure returns (uint256) {
        return mark - Math.mulDiv(mark, MAX_ANCHOR_BELOW_MARK, WAD);
    }

    /// @dev `mark` × (1 + `MAX_ANCHOR_ABOVE_MARK`), the distance term rounded down.
    function _ceiling(uint256 mark) internal pure returns (uint256) {
        return mark + Math.mulDiv(mark, MAX_ANCHOR_ABOVE_MARK, WAD);
    }

    /// @dev One parameter past its range in each case: a zero bound, a bound at a whole price, a speed over a whole
    ///      price a year, a delay under an hour or longer than the rise speed takes to cover the upper bound, a zero
    ///      window, and a `maxAnchorBelowMark` or `maxAnchorAboveMark` of a whole price.
    function _invalidParameters() internal pure returns (TrailingAnchorOracleBase.Parameters[] memory cases) {
        cases = new TrailingAnchorOracleBase.Parameters[](11);
        for (uint256 i; i < cases.length; ++i) {
            cases[i] = TrailingAnchorOracleModel.defaultParameters();
        }
        cases[0].maxPriceAboveAnchor = 0;
        cases[1].maxPriceBelowAnchor = 0;
        cases[2].maxPriceAboveAnchor = uint64(WAD);
        cases[3].maxPriceBelowAnchor = uint64(WAD);
        cases[4].maxAnchorRisePerYear = uint64(WAD + 1);
        cases[5].maxAnchorFallPerYear = uint64(WAD + 1);
        cases[6].reanchorDelay = 1 hours - 1;
        cases[7].reanchorWindow = 0;
        cases[8].reanchorDelay = uint40(MAX_PRICE_ABOVE_ANCHOR * YEAR / MAX_ANCHOR_RISE_PER_YEAR + 1);
        cases[9].maxAnchorBelowMark = uint64(WAD);
        cases[10].maxAnchorAboveMark = uint64(WAD);
        for (uint256 i; i < cases.length; ++i) {
            assertGt(TrailingAnchorOracleModel.parametersRevert(cases[i]).length, 0, "the model refuses the case");
        }
    }

    function _lower(uint256 center) internal pure returns (uint256) {
        return Math.mulDiv(center, WAD - MAX_PRICE_BELOW_ANCHOR, WAD);
    }

    function _upper(uint256 center) internal pure returns (uint256) {
        return Math.mulDiv(center, WAD + MAX_PRICE_ABOVE_ANCHOR, WAD);
    }

    function _slot(bytes32 base, uint256 offset) internal pure returns (bytes32) {
        return bytes32(uint256(base) + offset);
    }
}

contract TrailingAnchorOracleBaseUsdyTest is TrailingAnchorOracleBaseTest, UsdyNavOracleFixture {}

contract TrailingAnchorOracleBaseCentrifugeTest is TrailingAnchorOracleBaseTest, CentrifugeNavOracleFixture {}

/// @notice An upgrade behind one proxy to a new version of the same adapter keeps the state.
contract TrailingAnchorOracleUpgradeTest is Test {
    using TrailingAnchorOracleModel for TrailingAnchorOracleState;

    uint256 internal constant START = 1_760_000_000;
    uint256 internal constant INITIAL_PRICE = 1.112233445566778899e18;

    MockERC20 internal loan;
    MockERC20 internal usdy;
    MockOndoPriceGetter internal getter;
    TrailingAnchorOracleBase internal oracle;

    address internal admin = makeAddr("admin");
    address internal manager = makeAddr("manager");

    function setUp() public {
        vm.warp(START);
        loan = new MockERC20("USD Coin", "USDC", 6);
        usdy = new MockERC20("Ondo US Dollar Yield", "USDY", 18);
        getter = new MockOndoPriceGetter();
        getter.setCurrentPrice(INITIAL_PRICE);
        address impl = address(new UsdyNavOracle(address(getter), address(loan), address(usdy)));
        oracle = TrailingAnchorOracleBase(
            address(new OssifiableProxy(impl, admin, TrailingAnchorOracleModel.initializeCall(admin)))
        );
        bytes32 managerRole = oracle.MANAGER_ROLE();
        vm.startPrank(admin);
        oracle.grantRole(managerRole, manager);
        vm.stopPrank();
    }

    /// @dev A drift, a pending anchor and a suspension all survive an upgrade to a new version of the same adapter.
    function test_upgrade_sameAdapterKeepsState() public {
        vm.warp(START + 1 days);
        getter.setCurrentPrice(INITIAL_PRICE + 1);
        oracle.updateAnchor();
        getter.setCurrentPrice(INITIAL_PRICE / 2);
        oracle.updateAnchor();
        vm.prank(manager);
        oracle.setPricingResumesAt(uint40(START + 2 days));
        TrailingAnchorOracleState memory before = TrailingAnchorOracleModel.read(oracle);
        assertGt(before.pendingAnchorAt, 0, "a pending anchor");

        _upgradeTo(address(new UsdyNavOracle(address(getter), address(loan), address(usdy))));
        TrailingAnchorOracleState memory s = TrailingAnchorOracleModel.read(oracle);
        assertEq(abi.encode(s), abi.encode(before), "every stored value");
        vm.warp(START + 2 days);
        getter.setCurrentPrice(INITIAL_PRICE + 1);
        assertEq(oracle.price(), (INITIAL_PRICE + 1) * 1e6, "still priced");
    }

    function _upgradeTo(address impl) internal {
        vm.prank(admin);
        IOssifiableProxy(address(oracle)).proxy__upgradeTo(impl);
    }
}
