// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {Market as MorphoMarket} from "@lido-lend/src/interfaces/IMorpho.sol";
import {SharesMathLib} from "@lido-lend/src/libraries/SharesMathLib.sol";

import {IMorphoExitBook} from "../../src/interfaces/IMorphoExitBook.sol";
import {IErc4626ExitBook} from "../../src/interfaces/IErc4626ExitBook.sol";
import {ExitBookBase} from "../../src/periphery/ExitBookBase.sol";
import {PausableUntil} from "../../src/utils/PausableUntil.sol";
import {ExitStatus, PriorityRamp, Request} from "../../src/types/ExitBookTypes.sol";
import {WAD} from "../../src/libs/Constants.sol";
import {Erc4626Math} from "../setup/Erc4626Math.sol";
import {Market} from "../setup/Types.sol";
import {MarketActions} from "../setup/MarketActions.sol";
import {ForkMarketStack} from "./helpers/ForkMarketStack.sol";

/// @notice The two deployed exit books over one market: a lender opens an asset-denominated exit against a core
///         supply position (Morpho book) or the Lido vault's shares (ERC-4626 book), a filler pays it and earns
///         the priority fee net of the live service cut, and the owner can cancel. Quotes and payouts are
///         recomputed from the share maths and the fee schedule. Skips when the run records no exit books.
abstract contract ExitBooksForkBase is ForkMarketStack {
    using MarketActions for Market;
    using SharesMathLib for uint256;

    uint256 internal constant PRIORITY_RATE = 0.037e18;
    uint256 internal constant REQUEST_LIFETIME = 3 days;

    IMorphoExitBook internal morphoBook;
    IErc4626ExitBook internal erc4626Book;
    address internal bookPauser;

    address internal RECEIVER;
    address internal FILLER;
    address internal STRANGER;

    /// @dev The lender's request size: whole loan tokens plus a non-round tail, backed twice over (core position
    ///      and vault shares) so each book has its own source.
    uint256 internal requestAssets;

    constructor(string memory role) ForkMarketStack(role) {}

    function setUp() public {
        _fork();
        _bindRole();
        _skipUnlessArtifact("exit-books.toml");
        morphoBook = IMorphoExitBook(_artifactAddr("exit-books.toml", "exit_books.morpho"));
        erc4626Book = IErc4626ExitBook(_artifactAddr("exit-books.toml", "exit_books.erc4626"));
        bookPauser = _artifactAddr("exit-books.toml", "exit_books.pauser");

        LENDER = _freshActor(deployed, "exitBooks.lender");
        RECEIVER = _freshActor(deployed, "exitBooks.receiver");
        FILLER = _freshActor(deployed, "exitBooks.filler");
        STRANGER = _freshActor(deployed, "exitBooks.stranger");

        requestAssets = 5 * _loanUnit(deployed) + 4_321;
        _requireSupplyHeadroom(deployed, 2 * requestAssets);
        deal(address(deployed.loanToken), LENDER, 2 * requestAssets);
        market.coreSupply(LENDER, requestAssets);
        lenderShares = market.vaultDeposit(LENDER, requestAssets);

        // The Morpho book withdraws on the lender's behalf; the ERC-4626 book spends a share allowance.
        vm.prank(LENDER);
        deployed.core.setAuthorization(address(morphoBook), true);
        vm.prank(LENDER);
        deployed.vault.approve(address(erc4626Book), type(uint256).max);
    }

    // ---
    // MORPHO BOOK
    // ---

    function test_morphoBook_place_storesRequest_quoteMatchesSharesMath() public {
        uint256 quote = _coreSharesFor(requestAssets);
        uint256 sharesBefore = deployed.core.position(deployed.id, LENDER).supplyShares;
        uint256 deadline = block.timestamp + REQUEST_LIFETIME;
        uint256 expectedId = ExitBookBase(address(morphoBook)).lastRequestId() + 1;

        // One share under the quote is refused with the book's own required shares, so the quote is exact.
        vm.expectRevert(abi.encodeWithSelector(ExitBookBase.MaxShareBurnBelowQuote.selector, quote - 1, quote));
        _placeMorpho(requestAssets, requestAssets / 4, quote - 1);

        vm.expectEmit(true, true, true, true, address(morphoBook));
        emit ExitBookBase.ExitRequested(
            expectedId,
            LENDER,
            RECEIVER,
            address(deployed.loanToken),
            requestAssets,
            requestAssets / 4,
            quote,
            _flat(),
            deadline
        );
        uint256 id = _placeMorpho(requestAssets, requestAssets / 4, quote);

        Request memory request = morphoBook.getExitRequest(id);
        assertEq(uint8(request.status), uint8(ExitStatus.Open), "open");
        assertEq(request.owner, LENDER, "owner");
        assertEq(request.receiver, RECEIVER, "receiver");
        assertEq(request.assetsRemaining, requestAssets, "nothing filled yet");
        assertEq(request.deadline, deadline, "deadline");
        assertEq(deployed.core.position(deployed.id, LENDER).supplyShares, sharesBefore, "placement escrows nothing");
    }

    function test_morphoBook_fill_paysReceiverAndReward_burnsLiveShares() public {
        uint256 id = _placeMorpho(requestAssets, requestAssets / 4, 0);
        uint256 sharesBefore = deployed.core.position(deployed.id, LENDER).supplyShares;
        (uint256 receiverAssets, uint256 reward, uint256 cut) = _payout(address(morphoBook), requestAssets);
        uint256 burn = _coreSharesFor(requestAssets);

        vm.expectEmit(true, true, true, true, address(morphoBook));
        emit ExitBookBase.ExitProcessed(
            id, FILLER, FILLER, address(deployed.loanToken), requestAssets, burn, reward, cut
        );
        vm.prank(FILLER);
        morphoBook.fillExitRequest(id, requestAssets, FILLER);

        assertEq(
            deployed.loanToken.balanceOf(RECEIVER), receiverAssets, "receiver paid the fill net of the priority fee"
        );
        assertEq(deployed.loanToken.balanceOf(FILLER), reward, "filler earned the priority fee net of the service cut");
        assertEq(sharesBefore - deployed.core.position(deployed.id, LENDER).supplyShares, burn, "owner's shares burned");
        assertEq(uint8(morphoBook.getExitRequest(id).status), uint8(ExitStatus.Filled), "closed");
    }

    function test_morphoBook_partialFill_keepsOpen_thenRemainderCloses() public {
        uint256 id = _placeMorpho(requestAssets, requestAssets / 4, 0);
        uint256 half = requestAssets / 2;

        vm.prank(FILLER);
        morphoBook.fillExitRequest(id, half, FILLER);
        Request memory open = morphoBook.getExitRequest(id);
        assertEq(uint8(open.status), uint8(ExitStatus.Open), "still open");
        assertEq(open.assetsRemaining, requestAssets - half, "remainder recorded");

        vm.prank(FILLER);
        morphoBook.fillExitRequest(id, requestAssets - half, FILLER);
        assertEq(uint8(morphoBook.getExitRequest(id).status), uint8(ExitStatus.Filled), "closed by the remainder");
        // Each fill rounds its own fee down, so the receiver's total is the sum of the two nets, not one net.
        uint256 paid = (half - _priorityFee(half)) + (requestAssets - half - _priorityFee(requestAssets - half));
        assertEq(deployed.loanToken.balanceOf(RECEIVER), paid, "receiver paid both fills net of their fees");
    }

    function test_morphoBook_cancel_marksCancelled_leavesShares() public {
        uint256 id = _placeMorpho(requestAssets, 0, 0);
        uint256 sharesBefore = deployed.core.position(deployed.id, LENDER).supplyShares;

        vm.expectEmit(true, true, true, true, address(morphoBook));
        emit ExitBookBase.ExitCancelled(id);
        vm.prank(LENDER);
        morphoBook.cancelExitRequest(id);

        Request memory request = morphoBook.getExitRequest(id);
        assertEq(uint8(request.status), uint8(ExitStatus.Cancelled), "cancelled");
        assertEq(request.assetsRemaining, 0, "nothing left to fill");
        assertEq(deployed.core.position(deployed.id, LENDER).supplyShares, sharesBefore, "shares untouched");
    }

    /// @dev Layered controls: the book is live but the market's controller is paused, so the source withdrawal
    ///      is what refuses.
    function testRevert_morphoBook_fill_whenControllerPaused() public {
        uint256 id = _placeMorpho(requestAssets, 0, 0);
        _pauseViaResealManager(deployed, 1 days);
        vm.prank(FILLER);
        vm.expectRevert(PausableUntil.ResumedExpected.selector);
        morphoBook.fillExitRequest(id, requestAssets, FILLER);
    }

    // ---
    // ERC-4626 BOOK
    // ---

    function test_erc4626Book_place_onLidoVault_quoteMatchesErc4626Math() public {
        uint256 quote = Erc4626Math.toShares(deployed.vault, requestAssets, Math.Rounding.Ceil);
        uint256 deadline = block.timestamp + REQUEST_LIFETIME;
        uint256 expectedId = ExitBookBase(address(erc4626Book)).lastRequestId() + 1;

        // One share under the quote is refused with the book's own required shares, so the quote is exact.
        vm.expectRevert(abi.encodeWithSelector(ExitBookBase.MaxShareBurnBelowQuote.selector, quote - 1, quote));
        _placeErc4626(requestAssets, quote - 1);

        vm.expectEmit(true, true, true, true, address(erc4626Book));
        emit ExitBookBase.ExitRequested(
            expectedId, LENDER, RECEIVER, address(deployed.loanToken), requestAssets, 0, quote, _flat(), deadline
        );
        uint256 id = _placeErc4626(requestAssets, quote);

        assertEq(address(erc4626Book.vaultOf(id)), address(deployed.vault), "placed against the Lido vault");
        assertEq(deployed.vault.balanceOf(LENDER), lenderShares, "placement escrows nothing");
    }

    function test_erc4626Book_fill_paysReceiver_burnsLiveShares() public {
        uint256 id = _placeErc4626(requestAssets, 0);
        (uint256 receiverAssets, uint256 reward, uint256 cut) = _payout(address(erc4626Book), requestAssets);
        uint256 burn = Erc4626Math.toShares(deployed.vault, requestAssets, Math.Rounding.Ceil);

        vm.expectEmit(true, true, true, true, address(erc4626Book));
        emit ExitBookBase.ExitProcessed(
            id, FILLER, FILLER, address(deployed.loanToken), requestAssets, burn, reward, cut
        );
        vm.prank(FILLER);
        erc4626Book.fillExitRequest(id, requestAssets, FILLER);

        assertEq(
            deployed.loanToken.balanceOf(RECEIVER), receiverAssets, "receiver paid the fill net of the priority fee"
        );
        assertEq(deployed.loanToken.balanceOf(FILLER), reward, "filler earned the reward");
        assertEq(lenderShares - deployed.vault.balanceOf(LENDER), burn, "vault shares burned at the live price");
    }

    function test_erc4626Book_cancel_marksCancelled() public {
        uint256 id = _placeErc4626(requestAssets, 0);
        vm.prank(LENDER);
        erc4626Book.cancelExitRequest(id);
        assertEq(uint8(erc4626Book.getExitRequest(id).status), uint8(ExitStatus.Cancelled), "cancelled");
        assertEq(deployed.vault.balanceOf(LENDER), lenderShares, "shares untouched");
    }

    // ---
    // BOOK-LEVEL PAUSE
    // ---

    function testRevert_bookPaused_fill() public {
        uint256 id = _placeMorpho(requestAssets, 0, 0);
        vm.prank(bookPauser);
        morphoBook.pause();
        vm.prank(FILLER);
        vm.expectRevert(ExitBookBase.EnforcedPause.selector);
        morphoBook.fillExitRequest(id, requestAssets, FILLER);
    }

    /// @dev The documented recovery: `RESUMER_ROLE` starts empty, the admin appoints a resumer, it resumes, and
    ///      fills flow again.
    function test_bookResume_afterAdminGrantsResumer_fillWorks() public {
        uint256 id = _placeMorpho(requestAssets, 0, 0);
        vm.prank(bookPauser);
        morphoBook.pause();

        address resumer = makeAddr("exitBooks.resumer");
        bytes32 resumerRole = morphoBook.RESUMER_ROLE(); // read before the prank, or this call would consume it
        vm.prank(_admin());
        IAccessControl(address(morphoBook)).grantRole(resumerRole, resumer);
        vm.prank(resumer);
        morphoBook.resume();
        assertFalse(morphoBook.paused(), "resumed");

        vm.prank(FILLER);
        morphoBook.fillExitRequest(id, requestAssets, FILLER);
        assertEq(uint8(morphoBook.getExitRequest(id).status), uint8(ExitStatus.Filled), "filled after resume");
    }

    function testRevert_bookPause_byStranger() public {
        bytes32 role = morphoBook.PAUSER_ROLE();
        vm.prank(STRANGER);
        vm.expectRevert(_unauthorized(STRANGER, role));
        morphoBook.pause();
    }

    // ---
    // HELPERS
    // ---

    function _placeMorpho(uint256 assets, uint256 minFill, uint256 maxShareBurn) internal returns (uint256 id) {
        vm.prank(LENDER);
        id = morphoBook.placeExitRequest(
            deployed.id, assets, RECEIVER, minFill, maxShareBurn, _flat(), block.timestamp + REQUEST_LIFETIME
        );
    }

    function _placeErc4626(uint256 assets, uint256 maxShareBurn) internal returns (uint256 id) {
        vm.prank(LENDER);
        id = erc4626Book.placeExitRequest(
            IERC4626(address(deployed.vault)),
            assets,
            RECEIVER,
            0,
            maxShareBurn,
            _flat(),
            block.timestamp + REQUEST_LIFETIME
        );
    }

    function _flat() internal pure returns (PriorityRamp memory) {
        return PriorityRamp({startRate: PRIORITY_RATE, endRate: PRIORITY_RATE, rampStart: 0, rampEnd: 0});
    }

    /// @dev Core supply shares the Morpho book quotes and burns for `assets`: the up-rounded conversion at the
    ///      stored totals (the suite accrues in `setUp`, so the book's simulated totals are the stored ones).
    function _coreSharesFor(uint256 assets) internal view returns (uint256) {
        MorphoMarket memory mkt = deployed.core.market(deployed.id);
        return assets.toSharesUp(mkt.totalSupplyAssets, mkt.totalSupplyShares);
    }

    function _priorityFee(uint256 fillAssets) internal pure returns (uint256) {
        return Math.mulDiv(fillAssets, PRIORITY_RATE, WAD);
    }

    /// @dev The fee split for a fill, from the flat ramp and the book's LIVE service fee.
    function _payout(address book, uint256 fillAssets)
        internal
        view
        returns (uint256 receiverAssets, uint256 fillerReward, uint256 serviceCut)
    {
        uint256 priorityFee = _priorityFee(fillAssets);
        serviceCut = Math.mulDiv(priorityFee, ExitBookBase(book).serviceFee(), WAD);
        fillerReward = priorityFee - serviceCut;
        receiverAssets = fillAssets - priorityFee;
    }
}

contract ExitBooksWethWstethForkTest is ExitBooksForkBase("weth-wsteth") {}

contract ExitBooksUsdyUsdtForkTest is ExitBooksForkBase("usdy-usdt") {}
