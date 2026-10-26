// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {CentrifugeNavOracle} from "../../src/oracle/CentrifugeNavOracle.sol";
import {TrailingAnchorOracleBase} from "../../src/oracle/TrailingAnchorOracleBase.sol";
import {UsdyNavOracle} from "../../src/oracle/UsdyNavOracle.sol";
import {OssifiableProxy} from "../../src/proxy/OssifiableProxy.sol";

import {TrailingAnchorOracleModel, TrailingAnchorOracleState} from "../setup/TrailingAnchorOracleModel.sol";
import {IOssifiableProxy} from "../setup/IOssifiableProxy.sol";
import {MockERC20} from "../setup/Mocks.sol";
import {CentrifugeNavOracleFixture, NavOracleFixture, UsdyNavOracleFixture} from "../setup/NavOracleFixtures.sol";
import {MockCentrifugeSpoke, MockOndoPriceGetter, SourceDown} from "../setup/NavSourceMocks.sol";

/// @notice `TrailingAnchorOracleBase` method by method, run once through each adapter over its source mock.
/// @dev The loan token has 6 decimals, like USDC. Every expected value comes from `TrailingAnchorOracleModel` over the
///      stored state and the source the test set, or from the speed formula written out in the test, never from a value
///      the oracle computed.
abstract contract TrailingAnchorOracleBaseTest is NavOracleFixture {
    using TrailingAnchorOracleModel for TrailingAnchorOracleState;

    uint256 internal constant WAD = 1e18;
    uint256 internal constant YEAR = 365 days;
    uint256 internal constant START = 1_760_000_000;
    uint256 internal constant INITIAL_PRICE = 1.112233445566778899e18;
    uint256 internal constant MAX_PRICE_INCREASE = TrailingAnchorOracleModel.MAX_PRICE_INCREASE;
    uint256 internal constant MAX_PRICE_DECREASE = TrailingAnchorOracleModel.MAX_PRICE_DECREASE;
    uint256 internal constant ANCHOR_LIFETIME = TrailingAnchorOracleModel.ANCHOR_LIFETIME;
    uint256 internal constant MAX_ANCHOR_RISE = TrailingAnchorOracleModel.MAX_ANCHOR_RISE;
    uint256 internal constant MAX_ANCHOR_FALL = TrailingAnchorOracleModel.MAX_ANCHOR_FALL;
    uint256 internal constant MAX_ANCHOR_LIFETIME = TrailingAnchorOracleModel.MAX_ANCHOR_LIFETIME;

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
        impl.initialize(
            admin, MAX_PRICE_INCREASE, MAX_PRICE_DECREASE, ANCHOR_LIFETIME, MAX_ANCHOR_RISE, MAX_ANCHOR_FALL
        );
    }

    function test_initialize_seedsAnchor() public {
        address impl = _newImplementation(address(loan));

        vm.expectEmit();
        emit TrailingAnchorOracleBase.MaxPriceIncreaseSet(MAX_PRICE_INCREASE);
        vm.expectEmit();
        emit TrailingAnchorOracleBase.MaxPriceDecreaseSet(MAX_PRICE_DECREASE);
        vm.expectEmit();
        emit TrailingAnchorOracleBase.AnchorLifetimeSet(ANCHOR_LIFETIME);
        vm.expectEmit();
        emit TrailingAnchorOracleBase.MaxAnchorRiseSet(MAX_ANCHOR_RISE);
        vm.expectEmit();
        emit TrailingAnchorOracleBase.MaxAnchorFallSet(MAX_ANCHOR_FALL);
        vm.expectEmit();
        emit TrailingAnchorOracleBase.AnchorSet(INITIAL_PRICE, uint40(START), true);
        TrailingAnchorOracleBase fresh = TrailingAnchorOracleBase(
            address(new OssifiableProxy(impl, admin, TrailingAnchorOracleModel.initializeCall(admin)))
        );

        TrailingAnchorOracleState memory s = TrailingAnchorOracleModel.read(fresh);
        assertEq(s.anchorPrice, INITIAL_PRICE, "anchorPrice");
        assertEq(s.anchorAt, START, "anchorAt");
        assertEq(s.sourcePrice, INITIAL_PRICE, "sourcePrice");
        assertEq(s.maxPriceIncrease, MAX_PRICE_INCREASE, "maxPriceIncrease");
        assertEq(s.maxPriceDecrease, MAX_PRICE_DECREASE, "maxPriceDecrease");
        assertEq(s.anchorLifetime, ANCHOR_LIFETIME, "anchorLifetime");
        assertEq(s.maxAnchorRise, MAX_ANCHOR_RISE, "maxAnchorRise");
        assertEq(s.maxAnchorFall, MAX_ANCHOR_FALL, "maxAnchorFall");
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
        oracle.initialize(
            admin, MAX_PRICE_INCREASE, MAX_PRICE_DECREASE, ANCHOR_LIFETIME, MAX_ANCHOR_RISE, MAX_ANCHOR_FALL
        );
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

    /// @dev Each parameter is validated on its own: both bounds, the lifetime and both speeds.
    function testRevert_initialize_invalidParameters() public {
        address impl = _newImplementation(address(loan));
        uint256[5] memory valid =
            [MAX_PRICE_INCREASE, MAX_PRICE_DECREASE, ANCHOR_LIFETIME, MAX_ANCHOR_RISE, MAX_ANCHOR_FALL];
        _expectInitializeRevert(
            impl,
            _with(valid, 0, 0),
            abi.encodeWithSelector(TrailingAnchorOracleBase.InvalidMaxPriceIncrease.selector, 0)
        );
        _expectInitializeRevert(
            impl,
            _with(valid, 0, WAD),
            abi.encodeWithSelector(TrailingAnchorOracleBase.InvalidMaxPriceIncrease.selector, WAD)
        );
        _expectInitializeRevert(
            impl,
            _with(valid, 1, 0),
            abi.encodeWithSelector(TrailingAnchorOracleBase.InvalidMaxPriceDecrease.selector, 0)
        );
        _expectInitializeRevert(
            impl,
            _with(valid, 1, WAD),
            abi.encodeWithSelector(TrailingAnchorOracleBase.InvalidMaxPriceDecrease.selector, WAD)
        );
        _expectInitializeRevert(
            impl, _with(valid, 2, 0), abi.encodeWithSelector(TrailingAnchorOracleBase.InvalidAnchorLifetime.selector, 0)
        );
        _expectInitializeRevert(
            impl,
            _with(valid, 2, MAX_ANCHOR_LIFETIME),
            abi.encodeWithSelector(TrailingAnchorOracleBase.InvalidAnchorLifetime.selector, MAX_ANCHOR_LIFETIME)
        );
        _expectInitializeRevert(
            impl,
            _with(valid, 3, WAD + 1),
            abi.encodeWithSelector(TrailingAnchorOracleBase.InvalidMaxAnchorRise.selector, WAD + 1)
        );
        _expectInitializeRevert(
            impl,
            _with(valid, 4, WAD + 1),
            abi.encodeWithSelector(TrailingAnchorOracleBase.InvalidMaxAnchorFall.selector, WAD + 1)
        );
    }

    // ---
    // ROLES
    // ---

    /// @dev Two roles under the admin: the manager sets the parameters, the price acceptor accepts a price.
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

    /// @dev The anchor price × (1 − maxPriceDecrease) and × (1 + maxPriceIncrease), rounded down, both edges
    ///      inclusive.
    function test_price_boundsEdgesInclusive() public {
        TrailingAnchorOracleState memory s = _read();
        uint256 low = s.lowerBound();
        uint256 high = s.upperBound();
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
        TrailingAnchorOracleState memory s = _read();
        vm.expectRevert(
            abi.encodeWithSelector(
                TrailingAnchorOracleBase.PriceOutOfBounds.selector,
                INITIAL_PRICE + distance,
                s.lowerBound(),
                s.upperBound()
            )
        );
        oracle.price();
    }

    /// @dev Stale strictly after `anchorLifetime`: at the lifetime itself the price still returns.
    function test_price_staleEdge() public {
        vm.warp(START + ANCHOR_LIFETIME);
        assertEq(oracle.price(), INITIAL_PRICE * priceScale, "at the lifetime");
        vm.warp(START + ANCHOR_LIFETIME + 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                TrailingAnchorOracleBase.StaleAnchor.selector, uint40(START), uint40(ANCHOR_LIFETIME)
            )
        );
        oracle.price();
    }

    /// @dev Any current price and any elapsed time: the price is the current price scaled, or the revert the rules
    ///      name, staleness first.
    function testFuzz_price_matchesRule(uint256 currentPrice, uint256 elapsed) public {
        currentPrice = bound(currentPrice, INITIAL_PRICE * 997 / 1000, INITIAL_PRICE * 1003 / 1000);
        elapsed = bound(elapsed, 0, 2 * ANCHOR_LIFETIME);
        vm.warp(START + elapsed);
        source.setCurrentPrice(currentPrice);
        _assertPriceMatchesRule();
    }

    function testRevert_price_sourceFails() public {
        source.setCurrentPrice(0);
        vm.expectRevert(TrailingAnchorOracleBase.ZeroPrice.selector);
        oracle.price();
        source.setDown(true);
        vm.expectRevert(SourceDown.selector);
        oracle.price();
    }

    /// @dev A stale anchor reverts as stale before the source is read: a down source does not hide it.
    function test_price_staleCheckedBeforeSource() public {
        vm.warp(START + ANCHOR_LIFETIME + 1);
        source.setDown(true);
        vm.expectRevert(
            abi.encodeWithSelector(
                TrailingAnchorOracleBase.StaleAnchor.selector, uint40(START), uint40(ANCHOR_LIFETIME)
            )
        );
        oracle.price();
    }

    // ---
    // UPDATE ANCHOR
    // ---

    /// @dev A current price inside the reach is taken whole, by anyone, as an open update: a day at 6% a year reaches
    ///      0.016% up, and 0.01% is inside it.
    function test_updateAnchor_takesPriceInsideReach() public {
        vm.warp(START + 1 days);
        uint256 currentPrice = INITIAL_PRICE + INITIAL_PRICE / 10_000;
        source.setCurrentPrice(currentPrice);
        vm.expectEmit();
        emit TrailingAnchorOracleBase.AnchorSet(currentPrice, uint40(START + 1 days), false);
        vm.prank(anyone);
        oracle.updateAnchor();
        TrailingAnchorOracleState memory s = _read();
        assertEq(s.anchorPrice, currentPrice, "anchorPrice");
        assertEq(s.anchorAt, START + 1 days, "anchorAt");
        assertEq(s.sourcePrice, currentPrice, "sourcePrice");
        assertEq(oracle.price(), currentPrice * priceScale, "price is the current price");
    }

    /// @dev A current price above the reach moves the anchor by the rise speed for the day since it moved, rounded
    ///      down, and no further.
    function test_updateAnchor_risesAtRiseSpeed() public {
        vm.warp(START + 1 days);
        uint256 currentPrice = INITIAL_PRICE + INITIAL_PRICE / 2500;
        source.setCurrentPrice(currentPrice);
        oracle.updateAnchor();
        uint256 expected = INITIAL_PRICE + Math.mulDiv(INITIAL_PRICE, MAX_ANCHOR_RISE * 1 days, WAD * YEAR);
        assertEq(_read().anchorPrice, expected, "one day of the rise speed");
        assertLt(expected, currentPrice, "short of the current price");
        assertEq(_read().sourcePrice, currentPrice, "the source price the move read");
    }

    /// @dev A current price below the reach moves the anchor by the fall speed for the day since it moved, rounded
    ///      down, and no further.
    function test_updateAnchor_fallsAtFallSpeed() public {
        vm.warp(START + 1 days);
        uint256 currentPrice = INITIAL_PRICE - INITIAL_PRICE / 2500;
        source.setCurrentPrice(currentPrice);
        oracle.updateAnchor();
        uint256 expected = INITIAL_PRICE - Math.mulDiv(INITIAL_PRICE, MAX_ANCHOR_FALL * 1 days, WAD * YEAR);
        assertEq(_read().anchorPrice, expected, "one day of the fall speed");
        assertGt(expected, currentPrice, "short of the current price");
    }

    /// @dev Updates work while `price()` reverts on the bounds: a day at a time the anchor follows a price 0.1% up,
    ///      outside the 0.05% bound, that the source keeps publishing, at the rise speed, until the price is back
    ///      inside the bounds and returns without the price acceptor.
    function test_updateAnchor_followsPriceOutsideBounds() public {
        uint256 currentPrice = INITIAL_PRICE + INITIAL_PRICE / 1000;
        source.setCurrentPrice(currentPrice);
        TrailingAnchorOracleState memory s = _read();
        vm.expectRevert(
            abi.encodeWithSelector(
                TrailingAnchorOracleBase.PriceOutOfBounds.selector, currentPrice, s.lowerBound(), s.upperBound()
            )
        );
        oracle.price();

        for (uint256 day = 1; day <= 30 && !_read().withinBounds(currentPrice); ++day) {
            vm.warp(START + day * 1 days);
            // A new value every day, as a source that keeps publishing gives.
            currentPrice += 1;
            source.setCurrentPrice(currentPrice);
            s = _read();
            oracle.updateAnchor();
            assertEq(_read().anchorPrice, s.nextAnchor(currentPrice, block.timestamp), "the day's move");
        }
        assertEq(oracle.price(), currentPrice * priceScale, "priced again");
        assertGt(block.timestamp, START + 1 days, "more than one day's move");
    }

    /// @dev An update at exactly the lifetime, the last second the anchor is fresh, counts all of it: it moves the
    ///      anchor by one lifetime of the rise speed.
    function test_updateAnchor_countsUpToTheLifetime() public {
        vm.warp(START + ANCHOR_LIFETIME);
        source.setCurrentPrice(INITIAL_PRICE * 2);
        oracle.updateAnchor();
        uint256 expected = INITIAL_PRICE + Math.mulDiv(INITIAL_PRICE, MAX_ANCHOR_RISE * ANCHOR_LIFETIME, WAD * YEAR);
        assertEq(_read().anchorPrice, expected, "one lifetime of the rise speed");
    }

    /// @dev The cap on the fall speed keeps the fall term under the anchor: a whole price a year over the longest
    ///      lifetime lowers the anchor by under a tenth.
    function test_updateAnchor_fullFallOverLongestLifetime() public {
        vm.startPrank(manager);
        oracle.setAnchorLifetime(MAX_ANCHOR_LIFETIME - 1);
        oracle.setMaxAnchorFall(WAD);
        vm.stopPrank();
        vm.warp(START + MAX_ANCHOR_LIFETIME - 1);
        source.setCurrentPrice(1);
        oracle.updateAnchor();
        uint256 expected = INITIAL_PRICE - Math.mulDiv(INITIAL_PRICE, WAD * (MAX_ANCHOR_LIFETIME - 1), WAD * YEAR);
        assertEq(_read().anchorPrice, expected, "one lifetime at a whole price a year");
        assertGt(expected, INITIAL_PRICE * 9 / 10, "under a tenth lower");
    }

    /// @dev A second update in the block the anchor moved has no time to count, even on a source that moved again
    ///      within the block, so updates in one transaction cannot compound.
    function testRevert_updateAnchor_sameBlock() public {
        vm.warp(START + 1 days);
        source.setCurrentPrice(INITIAL_PRICE * 2);
        oracle.updateAnchor();
        uint256 movedAgain = INITIAL_PRICE * 2 + 1;
        source.setCurrentPrice(movedAgain);
        vm.expectRevert(abi.encodeWithSelector(TrailingAnchorOracleBase.AnchorUnchanged.selector, movedAgain));
        oracle.updateAnchor();
    }

    /// @dev A price the anchor already moved on is refused, so a frozen source cannot keep the anchor fresh and the
    ///      oracle goes stale.
    function testRevert_updateAnchor_frozenSourceGoesStale() public {
        vm.warp(START + 1 days);
        vm.expectRevert(abi.encodeWithSelector(TrailingAnchorOracleBase.SourceUnchanged.selector, INITIAL_PRICE));
        oracle.updateAnchor();
        vm.warp(START + ANCHOR_LIFETIME + 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                TrailingAnchorOracleBase.StaleAnchor.selector, uint40(START), uint40(ANCHOR_LIFETIME)
            )
        );
        oracle.price();
    }

    /// @dev A source that falls 0.09%, inside the decrease bound, and then freezes, with an update tried every day: the
    ///      first update reads the new price and moves the anchor a day of the fall speed toward it, and every later
    ///      one reads the same price and is refused. So the oracle goes stale one lifetime after that update although
    ///      the anchor still trails the source, and no update revives it.
    function testRevert_updateAnchor_frozenSourceGoesStaleWhileTrailing() public {
        uint256 frozen = INITIAL_PRICE - Math.mulDiv(INITIAL_PRICE, 0.0009e18, WAD);
        source.setCurrentPrice(frozen);
        vm.warp(START + 1 days);
        oracle.updateAnchor();
        uint256 trailing = _read().anchorPrice;
        assertGt(trailing, frozen, "the anchor trails above the frozen price");

        bytes memory unchanged = abi.encodeWithSelector(TrailingAnchorOracleBase.SourceUnchanged.selector, frozen);
        for (uint256 day = 2; day <= 1 + ANCHOR_LIFETIME / 1 days; ++day) {
            vm.warp(START + day * 1 days);
            assertEq(oracle.price(), frozen * priceScale, "priced within a lifetime of the move");
            vm.expectRevert(unchanged);
            oracle.updateAnchor();
        }
        bytes memory stale = abi.encodeWithSelector(
            TrailingAnchorOracleBase.StaleAnchor.selector, uint40(START + 1 days), uint40(ANCHOR_LIFETIME)
        );
        vm.warp(START + 1 days + ANCHOR_LIFETIME + 1);
        vm.expectRevert(stale);
        oracle.price();

        vm.warp(START + 120 days);
        vm.expectRevert(stale);
        oracle.updateAnchor();
        vm.expectRevert(stale);
        oracle.price();
        assertEq(_read().anchorPrice, trailing, "the anchor still trails");
    }

    /// @dev A stale anchor refuses an update before the source is read, even on a value no update has read yet and
    ///      however late the update comes: the source falls an hour after the seed and goes silent, and on day 120 the
    ///      oracle stays stale. Only the price acceptor revives it.
    function testRevert_updateAnchor_staleAnchor() public {
        vm.warp(START + 1 hours);
        source.setCurrentPrice(INITIAL_PRICE - Math.mulDiv(INITIAL_PRICE, 0.0009e18, WAD));
        bytes memory stale = abi.encodeWithSelector(
            TrailingAnchorOracleBase.StaleAnchor.selector, uint40(START), uint40(ANCHOR_LIFETIME)
        );
        vm.warp(START + ANCHOR_LIFETIME + 1);
        vm.expectRevert(stale);
        oracle.updateAnchor();
        vm.warp(START + 120 days);
        vm.expectRevert(stale);
        oracle.updateAnchor();
        vm.expectRevert(stale);
        oracle.price();
        source.setDown(true);
        vm.expectRevert(stale);
        oracle.updateAnchor();
    }

    /// @dev A zero rise speed stops open updates from raising the anchor.
    function testRevert_updateAnchor_zeroRiseSpeed() public {
        vm.prank(manager);
        oracle.setMaxAnchorRise(0);
        vm.warp(START + 1 days);
        uint256 currentPrice = INITIAL_PRICE + INITIAL_PRICE / 2500;
        source.setCurrentPrice(currentPrice);
        vm.expectRevert(abi.encodeWithSelector(TrailingAnchorOracleBase.AnchorUnchanged.selector, currentPrice));
        oracle.updateAnchor();
    }

    /// @dev A zero fall speed stops open updates from lowering the anchor.
    function testRevert_updateAnchor_zeroFallSpeed() public {
        vm.prank(manager);
        oracle.setMaxAnchorFall(0);
        vm.warp(START + 1 days);
        uint256 currentPrice = INITIAL_PRICE - INITIAL_PRICE / 2500;
        source.setCurrentPrice(currentPrice);
        vm.expectRevert(abi.encodeWithSelector(TrailingAnchorOracleBase.AnchorUnchanged.selector, currentPrice));
        oracle.updateAnchor();
    }

    /// @dev A down source bubbles up, and a zero price reverts before any move, which would otherwise pull the anchor
    ///      down at the fall speed and keep it fresh.
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

    /// @dev Any current price and time: an update sets the anchor the rules name, or reverts with the error they name
    ///      and leaves the state.
    function testFuzz_updateAnchor_matchesRule(uint256 currentPrice, uint256 elapsed) public {
        currentPrice = bound(currentPrice, 1, INITIAL_PRICE * 2);
        elapsed = bound(elapsed, 0, 3 * ANCHOR_LIFETIME);
        vm.warp(START + elapsed);
        source.setCurrentPrice(currentPrice);
        TrailingAnchorOracleState memory s = _read();
        bytes memory expected = s.updateRevert(currentPrice, false, block.timestamp);
        if (expected.length != 0) {
            vm.expectRevert(expected);
            oracle.updateAnchor();
            assertEq(_read().anchorPrice, s.anchorPrice, "anchorPrice kept");
            assertEq(_read().anchorAt, s.anchorAt, "anchorAt kept");
            assertEq(_read().sourcePrice, s.sourcePrice, "sourcePrice kept");
        } else {
            oracle.updateAnchor();
            assertEq(_read().anchorPrice, s.nextAnchor(currentPrice, block.timestamp), "anchorPrice");
            assertEq(_read().anchorAt, block.timestamp, "anchorAt");
            assertEq(_read().sourcePrice, currentPrice, "sourcePrice");
        }
        _assertPriceMatchesRule();
    }

    /// @dev A walk of updates at random times toward random prices, far outside the bounds too: each stays within the
    ///      reach of the anchor before it, so the walk stays within the speeds compounded update by update.
    function testFuzz_updateAnchor_speedsCompound(uint256 seed, uint8 steps) public {
        steps = uint8(bound(steps, 1, 40));
        uint256 highest = INITIAL_PRICE;
        uint256 lowest = INITIAL_PRICE;
        for (uint256 i; i < steps; ++i) {
            vm.warp(block.timestamp + bound(uint256(keccak256(abi.encode(seed, i, "time"))), 1, 3 days));
            uint256 currentPrice =
                bound(uint256(keccak256(abi.encode(seed, i, "price"))), INITIAL_PRICE / 2, INITIAL_PRICE * 2);
            source.setCurrentPrice(currentPrice);
            TrailingAnchorOracleState memory s = _read();
            (uint256 reachLow, uint256 reachHigh) = s.reach(block.timestamp);
            uint256 counted = s.countedTime(block.timestamp);

            bytes memory expected = s.updateRevert(currentPrice, false, block.timestamp);
            if (expected.length != 0) vm.expectRevert(expected);
            oracle.updateAnchor();
            // A refused update leaves the time it would have counted to the next one.
            if (expected.length == 0) {
                highest += Math.mulDiv(highest, MAX_ANCHOR_RISE * counted, WAD * YEAR);
                lowest -= Math.mulDiv(lowest, MAX_ANCHOR_FALL * counted, WAD * YEAR);
            }

            uint256 anchorPrice = _read().anchorPrice;
            assertGe(anchorPrice, reachLow, "step under the reach");
            assertLe(anchorPrice, reachHigh, "step over the reach");
            assertGe(anchorPrice, lowest, "under the compounded fall");
            assertLe(anchorPrice, highest, "over the compounded rise");
        }
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

    /// @dev The price acceptor takes a price at any distance, and `price()` returns it at once.
    function test_acceptPrice_anyDistance() public {
        vm.warp(START + 2 days);
        uint256 currentPrice = INITIAL_PRICE / 2;
        source.setCurrentPrice(currentPrice);
        vm.expectEmit();
        emit TrailingAnchorOracleBase.AnchorSet(currentPrice, uint40(START + 2 days), true);
        vm.prank(priceAcceptor);
        oracle.acceptPrice(currentPrice, currentPrice);
        TrailingAnchorOracleState memory s = _read();
        assertEq(s.anchorPrice, currentPrice, "anchorPrice");
        assertEq(s.anchorAt, START + 2 days, "anchorAt");
        assertEq(s.sourcePrice, currentPrice, "sourcePrice");
        assertEq(oracle.price(), currentPrice * priceScale, "price follows at once");
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

    /// @dev The range covers a source that keeps moving between the check and the execution: a committee checks one
    ///      price, the source moves on, and the acceptance still lands inside the range it set.
    function test_acceptPrice_rangeCoversMovingSource() public {
        uint256 checked = INITIAL_PRICE * 95 / 100;
        source.setCurrentPrice(checked);
        vm.warp(START + 3 days);
        uint256 moved = checked + checked / 10_000;
        source.setCurrentPrice(moved);
        vm.prank(priceAcceptor);
        oracle.acceptPrice(checked, Math.mulDiv(checked, WAD + 0.0002e18, WAD));
        assertEq(_read().anchorPrice, moved, "the moved price, inside the range");
    }

    /// @dev An acceptance clears a stale anchor, even on an unchanged price that `updateAnchor()` refuses.
    function test_acceptPrice_clearsStaleAnchor() public {
        uint256 later = START + ANCHOR_LIFETIME + 1;
        vm.warp(later);
        vm.prank(priceAcceptor);
        oracle.acceptPrice(INITIAL_PRICE, INITIAL_PRICE);
        assertEq(_read().anchorAt, later, "anchorAt");
        assertEq(oracle.price(), INITIAL_PRICE * priceScale, "fresh again on the same price");
    }

    /// @dev An acceptance needs no time since the anchor moved: it lands in the seed's block, where an update has
    ///      nothing to count.
    function test_acceptPrice_inTheSeedsBlock() public {
        source.setCurrentPrice(INITIAL_PRICE + 1);
        vm.prank(priceAcceptor);
        oracle.acceptPrice(INITIAL_PRICE + 1, INITIAL_PRICE + 1);
        assertEq(_read().anchorPrice, INITIAL_PRICE + 1, "accepted in the seed's block");
    }

    /// @dev An acceptance restarts the time an update counts: the next day's update moves one day of the rise speed,
    ///      not the days before the acceptance.
    function test_acceptPrice_restartsCountedTime() public {
        vm.warp(START + 5 days);
        vm.prank(priceAcceptor);
        oracle.acceptPrice(INITIAL_PRICE, INITIAL_PRICE);
        source.setCurrentPrice(INITIAL_PRICE * 2);
        vm.warp(START + 6 days);
        oracle.updateAnchor();
        uint256 expected = INITIAL_PRICE + Math.mulDiv(INITIAL_PRICE, MAX_ANCHOR_RISE * 1 days, WAD * YEAR);
        assertEq(_read().anchorPrice, expected, "one day of the rise speed");
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
    // PARAMETERS
    // ---

    /// @dev Only the manager sets any parameter: neither the admin nor the price acceptor.
    function testRevert_setters_notManager() public {
        bytes32 role = oracle.MANAGER_ROLE();
        address[3] memory callers = [anyone, admin, priceAcceptor];
        for (uint256 i; i < callers.length; ++i) {
            bytes memory err =
                abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, callers[i], role);
            vm.startPrank(callers[i]);
            vm.expectRevert(err);
            oracle.setMaxPriceIncrease(0.01e18);
            vm.expectRevert(err);
            oracle.setMaxPriceDecrease(0.01e18);
            vm.expectRevert(err);
            oracle.setAnchorLifetime(3 days);
            vm.expectRevert(err);
            oracle.setMaxAnchorRise(0.1e18);
            vm.expectRevert(err);
            oracle.setMaxAnchorFall(0.1e18);
            vm.stopPrank();
        }
    }

    function test_setMaxPriceIncrease_storesAndKeepsAnchor() public {
        vm.warp(START + 3 days);
        vm.expectEmit();
        emit TrailingAnchorOracleBase.MaxPriceIncreaseSet(0.01e18);
        vm.prank(manager);
        oracle.setMaxPriceIncrease(0.01e18);
        _assertStored(0.01e18, MAX_PRICE_DECREASE, ANCHOR_LIFETIME, MAX_ANCHOR_RISE, MAX_ANCHOR_FALL);
    }

    function test_setMaxPriceDecrease_storesAndKeepsAnchor() public {
        vm.warp(START + 3 days);
        vm.expectEmit();
        emit TrailingAnchorOracleBase.MaxPriceDecreaseSet(0.01e18);
        vm.prank(manager);
        oracle.setMaxPriceDecrease(0.01e18);
        _assertStored(MAX_PRICE_INCREASE, 0.01e18, ANCHOR_LIFETIME, MAX_ANCHOR_RISE, MAX_ANCHOR_FALL);
    }

    function test_setAnchorLifetime_storesAndKeepsAnchor() public {
        vm.warp(START + 3 days);
        vm.expectEmit();
        emit TrailingAnchorOracleBase.AnchorLifetimeSet(3 days);
        vm.prank(manager);
        oracle.setAnchorLifetime(3 days);
        _assertStored(MAX_PRICE_INCREASE, MAX_PRICE_DECREASE, 3 days, MAX_ANCHOR_RISE, MAX_ANCHOR_FALL);
    }

    function test_setMaxAnchorRise_storesAndKeepsAnchor() public {
        vm.warp(START + 3 days);
        vm.expectEmit();
        emit TrailingAnchorOracleBase.MaxAnchorRiseSet(0.1e18);
        vm.prank(manager);
        oracle.setMaxAnchorRise(0.1e18);
        _assertStored(MAX_PRICE_INCREASE, MAX_PRICE_DECREASE, ANCHOR_LIFETIME, 0.1e18, MAX_ANCHOR_FALL);
    }

    function test_setMaxAnchorFall_storesAndKeepsAnchor() public {
        vm.warp(START + 3 days);
        vm.expectEmit();
        emit TrailingAnchorOracleBase.MaxAnchorFallSet(0.1e18);
        vm.prank(manager);
        oracle.setMaxAnchorFall(0.1e18);
        _assertStored(MAX_PRICE_INCREASE, MAX_PRICE_DECREASE, ANCHOR_LIFETIME, MAX_ANCHOR_RISE, 0.1e18);
    }

    /// @dev A narrower increase applies at once: it refuses a rise the old one took.
    function test_setMaxPriceIncrease_appliesAtOnce() public {
        uint256 currentPrice = INITIAL_PRICE + INITIAL_PRICE / 2500;
        source.setCurrentPrice(currentPrice);
        assertEq(oracle.price(), currentPrice * priceScale, "0.04% up inside 0.05%");
        vm.prank(manager);
        oracle.setMaxPriceIncrease(0.0003e18);
        assertFalse(_read().withinBounds(currentPrice), "0.04% up outside 0.03%");
        _assertPriceMatchesRule();
    }

    /// @dev A narrower decrease applies at once: it refuses a fall the old one took.
    function test_setMaxPriceDecrease_appliesAtOnce() public {
        uint256 currentPrice = INITIAL_PRICE - Math.mulDiv(INITIAL_PRICE, 0.0008e18, WAD);
        source.setCurrentPrice(currentPrice);
        assertEq(oracle.price(), currentPrice * priceScale, "0.08% down inside 0.1%");
        vm.prank(manager);
        oracle.setMaxPriceDecrease(0.0005e18);
        assertFalse(_read().withinBounds(currentPrice), "0.08% down outside 0.05%");
        _assertPriceMatchesRule();
    }

    /// @dev A shorter lifetime makes the same anchor stale at once, and a longer one revives it.
    function test_setAnchorLifetime_appliesAtOnce() public {
        vm.prank(manager);
        oracle.setAnchorLifetime(1 days);
        vm.warp(START + 1 days + 1);
        vm.expectRevert(
            abi.encodeWithSelector(TrailingAnchorOracleBase.StaleAnchor.selector, uint40(START), uint40(1 days))
        );
        oracle.price();
        vm.prank(manager);
        oracle.setAnchorLifetime(2 days);
        assertEq(oracle.price(), INITIAL_PRICE * priceScale, "a longer lifetime revives the anchor");
    }

    /// @dev A new rise speed applies at once, also to the day since the anchor last moved.
    function test_setMaxAnchorRise_appliesToTimeSinceMove() public {
        vm.warp(START + 1 days);
        vm.prank(manager);
        oracle.setMaxAnchorRise(0.5e18);
        source.setCurrentPrice(INITIAL_PRICE * 2);
        oracle.updateAnchor();
        uint256 expected = INITIAL_PRICE + Math.mulDiv(INITIAL_PRICE, 0.5e18 * 1 days, WAD * YEAR);
        assertEq(_read().anchorPrice, expected, "the day before the change at the new speed");
    }

    /// @dev A new fall speed applies at once, also to the day since the anchor last moved.
    function test_setMaxAnchorFall_appliesToTimeSinceMove() public {
        vm.warp(START + 1 days);
        vm.prank(manager);
        oracle.setMaxAnchorFall(0.5e18);
        source.setCurrentPrice(INITIAL_PRICE / 2);
        oracle.updateAnchor();
        uint256 expected = INITIAL_PRICE - Math.mulDiv(INITIAL_PRICE, 0.5e18 * 1 days, WAD * YEAR);
        assertEq(_read().anchorPrice, expected, "the day before the change at the new speed");
    }

    function test_validator_maxPriceIncrease() public {
        vm.startPrank(manager);
        vm.expectRevert(abi.encodeWithSelector(TrailingAnchorOracleBase.InvalidMaxPriceIncrease.selector, 0));
        oracle.setMaxPriceIncrease(0);
        vm.expectRevert(abi.encodeWithSelector(TrailingAnchorOracleBase.InvalidMaxPriceIncrease.selector, WAD));
        oracle.setMaxPriceIncrease(WAD);
        oracle.setMaxPriceIncrease(1);
        assertEq(oracle.maxPriceIncrease(), 1, "one wei");
        oracle.setMaxPriceIncrease(WAD - 1);
        assertEq(oracle.maxPriceIncrease(), WAD - 1, "just under a whole price");
        vm.stopPrank();
    }

    function test_validator_maxPriceDecrease() public {
        vm.startPrank(manager);
        vm.expectRevert(abi.encodeWithSelector(TrailingAnchorOracleBase.InvalidMaxPriceDecrease.selector, 0));
        oracle.setMaxPriceDecrease(0);
        vm.expectRevert(abi.encodeWithSelector(TrailingAnchorOracleBase.InvalidMaxPriceDecrease.selector, WAD));
        oracle.setMaxPriceDecrease(WAD);
        oracle.setMaxPriceDecrease(1);
        assertEq(oracle.maxPriceDecrease(), 1, "one wei");
        oracle.setMaxPriceDecrease(WAD - 1);
        assertEq(oracle.maxPriceDecrease(), WAD - 1, "just under a whole price");
        vm.stopPrank();
    }

    /// @dev Strictly above zero and strictly below `MAX_ANCHOR_LIFETIME`.
    function test_validator_anchorLifetime() public {
        vm.startPrank(manager);
        vm.expectRevert(abi.encodeWithSelector(TrailingAnchorOracleBase.InvalidAnchorLifetime.selector, 0));
        oracle.setAnchorLifetime(0);
        vm.expectRevert(
            abi.encodeWithSelector(TrailingAnchorOracleBase.InvalidAnchorLifetime.selector, MAX_ANCHOR_LIFETIME)
        );
        oracle.setAnchorLifetime(MAX_ANCHOR_LIFETIME);
        oracle.setAnchorLifetime(1);
        assertEq(oracle.anchorLifetime(), 1, "one second");
        oracle.setAnchorLifetime(MAX_ANCHOR_LIFETIME - 1);
        assertEq(oracle.anchorLifetime(), MAX_ANCHOR_LIFETIME - 1, "one second under the cap");
        vm.stopPrank();
    }

    /// @dev From zero to a whole price a year, both inclusive.
    function test_validator_maxAnchorRise() public {
        vm.startPrank(manager);
        vm.expectRevert(abi.encodeWithSelector(TrailingAnchorOracleBase.InvalidMaxAnchorRise.selector, WAD + 1));
        oracle.setMaxAnchorRise(WAD + 1);
        oracle.setMaxAnchorRise(0);
        assertEq(oracle.maxAnchorRise(), 0, "zero");
        oracle.setMaxAnchorRise(WAD);
        assertEq(oracle.maxAnchorRise(), WAD, "a whole price a year");
        vm.stopPrank();
    }

    /// @dev From zero to a whole price a year, both inclusive.
    function test_validator_maxAnchorFall() public {
        vm.startPrank(manager);
        vm.expectRevert(abi.encodeWithSelector(TrailingAnchorOracleBase.InvalidMaxAnchorFall.selector, WAD + 1));
        oracle.setMaxAnchorFall(WAD + 1);
        oracle.setMaxAnchorFall(0);
        assertEq(oracle.maxAnchorFall(), 0, "zero");
        oracle.setMaxAnchorFall(WAD);
        assertEq(oracle.maxAnchorFall(), WAD, "a whole price a year");
        vm.stopPrank();
    }

    // ---
    // STORAGE
    // ---

    /// @dev The base's state lives in the adapter's own namespace: both bounds, the lifetime and the anchor time packed
    ///      into the first slot, low bits first, the anchor price in the second, both speeds in the third and the
    ///      source price in the fourth. The source is out of a day's reach, so the two prices differ.
    function test_storage_namespaceLayout() public {
        vm.warp(START + 1 days);
        source.setCurrentPrice(INITIAL_PRICE * 2);
        oracle.updateAnchor();
        uint256 anchorPrice = INITIAL_PRICE + Math.mulDiv(INITIAL_PRICE, MAX_ANCHOR_RISE * 1 days, WAD * YEAR);
        bytes32 base = TrailingAnchorOracleModel.namespaceSlot(_namespace());
        uint256 first = uint256(vm.load(address(oracle), base));
        assertEq(uint64(first), MAX_PRICE_INCREASE, "maxPriceIncrease in bits 0-63");
        assertEq(uint64(first >> 64), MAX_PRICE_DECREASE, "maxPriceDecrease in bits 64-127");
        assertEq(uint40(first >> 128), ANCHOR_LIFETIME, "anchorLifetime in bits 128-167");
        assertEq(uint40(first >> 168), START + 1 days, "anchorAt in bits 168-207");
        assertEq(first >> 208, 0, "nothing above in the first slot");
        uint256 second = uint256(vm.load(address(oracle), bytes32(uint256(base) + 1)));
        assertEq(second, anchorPrice, "anchorPrice in the second slot");
        uint256 third = uint256(vm.load(address(oracle), bytes32(uint256(base) + 2)));
        assertEq(uint64(third), MAX_ANCHOR_RISE, "maxAnchorRise in bits 0-63");
        assertEq(uint64(third >> 64), MAX_ANCHOR_FALL, "maxAnchorFall in bits 64-127");
        assertEq(third >> 128, 0, "nothing above in the third slot");
        uint256 fourth = uint256(vm.load(address(oracle), bytes32(uint256(base) + 3)));
        assertEq(fourth, INITIAL_PRICE * 2, "sourcePrice in the fourth slot");
        assertEq(uint256(vm.load(address(oracle), bytes32(uint256(base) + 4))), 0, "nothing in the fifth slot");
    }

    // ---
    // HELPERS
    // ---

    function _read() internal view returns (TrailingAnchorOracleState memory) {
        return TrailingAnchorOracleModel.read(oracle);
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

    /// @dev The stored parameters, and the anchor the setup seeded.
    function _assertStored(uint256 increase, uint256 decrease, uint256 lifetime, uint256 rise, uint256 fall)
        internal
        view
    {
        TrailingAnchorOracleState memory s = _read();
        assertEq(s.maxPriceIncrease, increase, "maxPriceIncrease");
        assertEq(s.maxPriceDecrease, decrease, "maxPriceDecrease");
        assertEq(s.anchorLifetime, lifetime, "anchorLifetime");
        assertEq(s.maxAnchorRise, rise, "maxAnchorRise");
        assertEq(s.maxAnchorFall, fall, "maxAnchorFall");
        assertEq(s.anchorPrice, INITIAL_PRICE, "anchorPrice kept");
        assertEq(s.anchorAt, START, "anchorAt kept");
        assertEq(s.sourcePrice, INITIAL_PRICE, "sourcePrice kept");
    }

    /// @dev A copy of `parameters` with the one at `index` replaced by `value`; assigning the memory array would
    ///      alias it.
    function _with(uint256[5] memory parameters, uint256 index, uint256 value)
        internal
        pure
        returns (uint256[5] memory changed)
    {
        for (uint256 i; i < parameters.length; ++i) {
            changed[i] = parameters[i];
        }
        changed[index] = value;
    }

    function _expectInitializeRevert(address impl, uint256[5] memory parameters, bytes memory err) internal {
        bytes memory init = TrailingAnchorOracleModel.initializeCall(
            admin, parameters[0], parameters[1], parameters[2], parameters[3], parameters[4]
        );
        vm.expectRevert(err);
        new OssifiableProxy(impl, admin, init);
    }
}

contract TrailingAnchorOracleBaseUsdyTest is TrailingAnchorOracleBaseTest, UsdyNavOracleFixture {}

contract TrailingAnchorOracleBaseCentrifugeTest is TrailingAnchorOracleBaseTest, CentrifugeNavOracleFixture {}

/// @notice An upgrade behind one proxy. To a new version of the same adapter it keeps the state; to another adapter it
///         reads an empty namespace and fails closed until the manager and the price acceptor restore it.
contract TrailingAnchorOracleUpgradeTest is Test {
    using TrailingAnchorOracleModel for TrailingAnchorOracleState;

    uint256 internal constant START = 1_760_000_000;
    uint256 internal constant INITIAL_PRICE = 1.112233445566778899e18;
    uint64 internal constant POOL_ID = 281474976710662;
    bytes16 internal constant SHARE_CLASS_ID = 0x00010000000000060000000000000001;

    MockERC20 internal loan;
    MockERC20 internal usdy;
    MockERC20 internal share;
    MockOndoPriceGetter internal getter;
    MockCentrifugeSpoke internal spoke;
    TrailingAnchorOracleBase internal oracle;

    address internal admin = makeAddr("admin");
    address internal manager = makeAddr("manager");
    address internal priceAcceptor = makeAddr("priceAcceptor");

    function setUp() public {
        vm.warp(START);
        loan = new MockERC20("USD Coin", "USDC", 6);
        usdy = new MockERC20("Ondo US Dollar Yield", "USDY", 18);
        share = new MockERC20("Share", "SHARE", 18);
        getter = new MockOndoPriceGetter();
        getter.setCurrentPrice(INITIAL_PRICE);
        spoke = new MockCentrifugeSpoke(POOL_ID, SHARE_CLASS_ID);
        spoke.setCurrentPrice(INITIAL_PRICE);
        address impl = address(new UsdyNavOracle(address(getter), address(loan), address(usdy)));
        oracle = TrailingAnchorOracleBase(
            address(new OssifiableProxy(impl, admin, TrailingAnchorOracleModel.initializeCall(admin)))
        );
        bytes32 managerRole = oracle.MANAGER_ROLE();
        bytes32 priceAcceptorRole = oracle.PRICE_ACCEPTOR_ROLE();
        vm.startPrank(admin);
        oracle.grantRole(managerRole, manager);
        oracle.grantRole(priceAcceptorRole, priceAcceptor);
        vm.stopPrank();
    }

    function test_upgrade_sameAdapterKeepsState() public {
        vm.warp(START + 1 days);
        getter.setCurrentPrice(INITIAL_PRICE + 1);
        oracle.updateAnchor();
        TrailingAnchorOracleState memory before = TrailingAnchorOracleModel.read(oracle);

        _upgradeTo(address(new UsdyNavOracle(address(getter), address(loan), address(usdy))));
        TrailingAnchorOracleState memory s = TrailingAnchorOracleModel.read(oracle);
        assertEq(s.anchorPrice, before.anchorPrice, "anchorPrice");
        assertEq(s.anchorAt, before.anchorAt, "anchorAt");
        assertEq(s.sourcePrice, before.sourcePrice, "sourcePrice");
        assertEq(s.maxPriceIncrease, before.maxPriceIncrease, "maxPriceIncrease");
        assertEq(s.maxPriceDecrease, before.maxPriceDecrease, "maxPriceDecrease");
        assertEq(s.anchorLifetime, before.anchorLifetime, "anchorLifetime");
        assertEq(s.maxAnchorRise, before.maxAnchorRise, "maxAnchorRise");
        assertEq(s.maxAnchorFall, before.maxAnchorFall, "maxAnchorFall");
        assertEq(oracle.price(), (INITIAL_PRICE + 1) * 1e6, "still priced");
    }

    /// @dev The other adapter's namespace is empty: zero lifetime makes the oracle stale and refuses an open update,
    ///      the shared initializer flag refuses a second `initialize`, and the shared roles survive.
    function test_upgrade_otherAdapterFailsClosed() public {
        _upgradeToCentrifuge();
        TrailingAnchorOracleState memory s = TrailingAnchorOracleModel.read(oracle);
        assertEq(s.anchorPrice, 0, "no anchor price");
        assertEq(s.anchorAt, 0, "no anchor time");
        assertEq(s.anchorLifetime, 0, "no lifetime");
        assertEq(s.sourcePrice, 0, "no source price");
        vm.expectRevert(abi.encodeWithSelector(TrailingAnchorOracleBase.StaleAnchor.selector, uint40(0), uint40(0)));
        oracle.price();
        vm.expectRevert(abi.encodeWithSelector(TrailingAnchorOracleBase.StaleAnchor.selector, uint40(0), uint40(0)));
        oracle.updateAnchor();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        oracle.initialize(
            admin,
            TrailingAnchorOracleModel.MAX_PRICE_INCREASE,
            TrailingAnchorOracleModel.MAX_PRICE_DECREASE,
            TrailingAnchorOracleModel.ANCHOR_LIFETIME,
            TrailingAnchorOracleModel.MAX_ANCHOR_RISE,
            TrailingAnchorOracleModel.MAX_ANCHOR_FALL
        );
        assertTrue(oracle.hasRole(oracle.MANAGER_ROLE(), manager), "manager kept");
        assertTrue(oracle.hasRole(oracle.PRICE_ACCEPTOR_ROLE(), priceAcceptor), "price acceptor kept");
    }

    /// @dev Recovery: the manager sets every parameter, and the price acceptor seeds an anchor.
    function test_upgrade_otherAdapterRecovers() public {
        _upgradeToCentrifuge();
        vm.startPrank(manager);
        oracle.setAnchorLifetime(TrailingAnchorOracleModel.ANCHOR_LIFETIME);
        oracle.setMaxPriceIncrease(TrailingAnchorOracleModel.MAX_PRICE_INCREASE);
        oracle.setMaxPriceDecrease(TrailingAnchorOracleModel.MAX_PRICE_DECREASE);
        oracle.setMaxAnchorRise(TrailingAnchorOracleModel.MAX_ANCHOR_RISE);
        oracle.setMaxAnchorFall(TrailingAnchorOracleModel.MAX_ANCHOR_FALL);
        vm.stopPrank();
        vm.expectRevert(
            abi.encodeWithSelector(
                TrailingAnchorOracleBase.StaleAnchor.selector,
                uint40(0),
                uint40(TrailingAnchorOracleModel.ANCHOR_LIFETIME)
            )
        );
        oracle.price();

        vm.prank(priceAcceptor);
        oracle.acceptPrice(INITIAL_PRICE, INITIAL_PRICE);
        assertEq(oracle.price(), INITIAL_PRICE * 1e6, "priced from the new source");
    }

    function _upgradeToCentrifuge() internal {
        _upgradeTo(
            address(new CentrifugeNavOracle(address(spoke), POOL_ID, SHARE_CLASS_ID, address(loan), address(share)))
        );
    }

    function _upgradeTo(address impl) internal {
        vm.prank(admin);
        IOssifiableProxy(address(oracle)).proxy__upgradeTo(impl);
    }
}
