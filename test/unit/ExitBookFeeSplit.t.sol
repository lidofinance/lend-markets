// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {Erc4626ExitBook} from "../../src/periphery/Erc4626ExitBook.sol";
import {ExitBookBase} from "../../src/periphery/ExitBookBase.sol";
import {IExitBook} from "../../src/interfaces/IExitBook.sol";
import {ExitBookLib} from "../../src/libs/ExitBookLib.sol";
import {Request, RequestPreview, PriorityRamp, ExitStatus} from "../../src/types/ExitBookTypes.sol";

contract MockAsset is ERC20 {
    constructor() ERC20("Asset", "AST") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockVault is ERC4626 {
    constructor(IERC20 asset_) ERC20("Vault", "vAST") ERC4626(asset_) {}
}

/// @notice A vault whose `redeem` burns the shares but transfers no assets out, so the book measures a
///         zero `assetsOut` delta and must revert `NoAssetsRedeemed`. Backing (balance/allowance/maxRedeem)
///         stays real so a request can be placed and reach the redeem.
contract ZeroRedeemVault is ERC4626 {
    constructor(IERC20 asset_) ERC20("ZeroVault", "zAST") ERC4626(asset_) {}

    function redeem(uint256 shares, address, address owner) public override returns (uint256) {
        _burn(owner, shares); // burn the shares but send nothing — assetsOut delta is 0
        return 0;
    }
}

/// @notice A vault whose per-share price rounds to zero (`convertToAssets(WAD) == 0`) — the sub-1-wei-per-share
///         regime `placeExitRequest` must reject. A snapshot price of 0 would pay the lender `owed = 0` on every
///         fill and route the whole redemption to the filler.
contract ZeroPriceVault is ERC4626 {
    constructor(IERC20 asset_) ERC20("ZeroPriceVault", "zpAST") ERC4626(asset_) {}

    function convertToAssets(uint256) public pure override returns (uint256) {
        return 0;
    }
}

/// @notice A vault with 36-decimal shares and a caller-set linear rate `assets = shares * num / den`, modelling
///         the share-decimal offset where the old fixed-WAD sample underpriced. Shares are minted directly.
contract ScaledVault is ERC4626 {
    uint256 public immutable num;
    uint256 public immutable den;

    constructor(IERC20 asset_, uint256 num_, uint256 den_) ERC20("Scaled", "sc") ERC4626(asset_) {
        num = num_;
        den = den_;
    }

    function decimals() public pure override returns (uint8) {
        return 36;
    }

    function convertToAssets(uint256 shares) public view override returns (uint256) {
        return Math.mulDiv(shares, num, den);
    }

    /// @dev The inverse of the rate above. Without it the book would size a request off OZ's default conversion
    ///      and disagree with every other quote this vault gives.
    function convertToShares(uint256 assets) public view override returns (uint256) {
        return Math.mulDiv(assets, den, num);
    }

    function previewRedeem(uint256 shares) public view override returns (uint256) {
        return Math.mulDiv(shares, num, den, Math.Rounding.Ceil);
    }

    function maxRedeem(address owner) public view virtual override returns (uint256) {
        return balanceOf(owner);
    }

    function redeem(uint256 shares, address receiver, address owner) public virtual override returns (uint256 assets) {
        if (msg.sender != owner) _spendAllowance(owner, msg.sender, shares);
        assets = previewRedeem(shares);
        _burn(owner, shares);
        IERC20(asset()).transfer(receiver, assets);
    }

    function mintShares(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice A scaled vault that re-enters the same request during the first redeem. The first `maxRedeem` exposes
///         only `firstFillShares`; the nested fill sees the rest.
contract ReentrantScaledVault is ScaledVault {
    Erc4626ExitBook internal exitBook;
    uint256 internal requestId;
    uint256 internal firstFillShares;
    bool internal entered;

    constructor(IERC20 asset_) ScaledVault(asset_, 19, 10) {}

    function arm(Erc4626ExitBook exitBook_, uint256 requestId_, uint256 firstFillShares_) external {
        exitBook = exitBook_;
        requestId = requestId_;
        firstFillShares = firstFillShares_;
    }

    function maxRedeem(address owner) public view override returns (uint256) {
        return entered ? balanceOf(owner) : Math.min(firstFillShares, balanceOf(owner));
    }

    function redeem(uint256 shares, address receiver, address owner) public override returns (uint256 assets) {
        assets = super.redeem(shares, receiver, owner);
        if (!entered) {
            entered = true;
            exitBook.fillExitRequest(requestId, 0, 0);
        }
    }
}

/// @notice Exact three-way conservation of `ExitBookBase.fillExitRequest` — the fee split that the deleted
///         `WithdrawalMathLib` once covered, now inlined in the base. For a fill that arrives with `assetsOut`:
///           owed        = min(placement quote apportioned to the fill, assetsOut)
///           fee         = owed * priorityRate / WAD
///           lenderAssets= owed - fee
///           fillerGross = (assetsOut - owed) + fee
///           serviceCut  = fillerGross * serviceFee / WAD
///           fillerFee   = fillerGross - serviceCut
///         The invariant is `lenderAssets + fillerFee + serviceCut == assetsOut` with NO remainder. Every
///         component is recomputed independently from the on-chain placement quote, the previewed `assetsOut`,
///         the ramp rate, and `serviceFee`, then matched against the actual token deltas. Plus the priority
///         ramp (hold → linear → plateau).
contract ExitBookFeeSplitTest is Test {
    uint256 internal constant WAD = 1e18;

    MockAsset internal asset;
    MockVault internal vault;
    Erc4626ExitBook internal book;

    address internal lender = address(0x1E11dE7);
    address internal filler = address(0xF111E7);
    address internal feeRecipient = address(0xFEE);

    function setUp() public {
        vm.warp(1_000_000);
        asset = new MockAsset();
        vault = new MockVault(IERC20(address(asset)));
        book = new Erc4626ExitBook(address(this), 365 days);
        book.grantRole(book.ALLOWLIST_MANAGER_ROLE(), address(this));
        book.grantRole(book.FEE_MANAGER_ROLE(), address(this));
        book.setVaultAllowed(IERC4626(address(vault)), true);
    }

    function _setServiceFee(uint256 fee) internal {
        book.setServiceFee(feeRecipient, fee);
    }

    function _ramp() internal pure returns (PriorityRamp memory) {
        return PriorityRamp({startRate: 0.02e18, endRate: 0.08e18, rampStart: 1 hours, rampEnd: 1 days});
    }

    /// @dev Lender deposits `depositAmt`, places an exit for ALL resulting shares, approves the book.
    function _lenderPlace(uint256 depositAmt, PriorityRamp memory ramp) internal returns (uint256 id, uint256 shares) {
        asset.mint(lender, depositAmt);
        vm.startPrank(lender);
        asset.approve(address(vault), depositAmt);
        shares = vault.deposit(depositAmt, lender);
        vault.approve(address(book), shares);
        id = book.placeExitRequest(
            IERC4626(address(vault)),
            IERC4626(address(vault)).convertToAssets(shares),
            lender,
            ramp,
            block.timestamp + 30 days,
            false
        );
        vm.stopPrank();
    }

    /// @dev Push yield into the vault by donating assets (raises the share price above the placed snapshot).
    function _donate(uint256 amount) internal {
        asset.mint(address(vault), amount);
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

    /// @dev Independent recompute, mirroring `ExitBookBase.fillExitRequest`. For a FULL fill the telescoping
    ///      payout is the whole placement quote, capped at what arrived.
    function _expectedSplit(uint256 quotedAssets, uint256 assetsOut, uint256 rate, uint256 serviceFee)
        internal
        pure
        returns (Split memory s)
    {
        uint256 owed = Math.min(quotedAssets, assetsOut);
        uint256 fee = Math.mulDiv(owed, rate, WAD);
        uint256 fillerGross = (assetsOut - owed) + fee;
        s.serviceCut = Math.mulDiv(fillerGross, serviceFee, WAD);
        s.fillerFee = fillerGross - s.serviceCut;
        s.lenderAssets = owed - fee;
        s.assetsOut = assetsOut;
    }

    /// @dev Fill request `id` fully and assert the exact three-way split + conservation against the recompute.
    ///      `elapsed` is the time since placement (sets the ramp rate); `serviceFee` already set.
    function _fillAndAssert(uint256 id, uint256 shares, uint256 elapsed, uint256 serviceFee) internal {
        vm.warp(block.timestamp + elapsed);
        uint256 quotedAssets = book.getExitRequest(id).quotedAssets;
        Split memory s =
            _expectedSplit(quotedAssets, vault.previewRedeem(shares), _priorityRate(_ramp(), elapsed), serviceFee);

        uint256[3] memory pre = [asset.balanceOf(lender), asset.balanceOf(filler), asset.balanceOf(feeRecipient)];
        vm.prank(filler);
        book.fillExitRequest(id, 0, 0); // filler brings no liquidity; redeem draws on the vault

        uint256 lenderGot = asset.balanceOf(lender) - pre[0];
        uint256 fillerGot = asset.balanceOf(filler) - pre[1];
        uint256 feeGot = asset.balanceOf(feeRecipient) - pre[2];

        assertEq(lenderGot, s.lenderAssets, "lender share exact");
        assertEq(fillerGot, s.fillerFee, "filler share exact");
        assertEq(feeGot, s.serviceCut, "service cut exact");
        // The defining invariant: the three legs reconstruct assetsOut with no remainder.
        assertEq(lenderGot + fillerGot + feeGot, s.assetsOut, "three-way conservation == assetsOut");
    }

    /// @dev Lender deposits and approves the book for `approveShares` of the resulting shares.
    function _depositAndApprove(uint256 depositAmt, uint256 approveShares) internal returns (uint256 shares) {
        asset.mint(lender, depositAmt);
        vm.startPrank(lender);
        asset.approve(address(vault), depositAmt);
        shares = vault.deposit(depositAmt, lender);
        vault.approve(address(book), approveShares);
        vm.stopPrank();
    }

    function _place(uint256 shares, PriorityRamp memory ramp, uint256 deadline) internal returns (uint256) {
        uint256 exitAssets = IERC4626(address(vault)).convertToAssets(shares);
        vm.prank(lender);
        return book.placeExitRequest(IERC4626(address(vault)), exitAssets, lender, ramp, deadline, false);
    }

    function _status(uint256 id) internal view returns (uint8) {
        return uint8(book.getExitRequest(id).status);
    }

    // ── mutations ──

    // ── concrete ──

    /// @dev With vault yield above the snapshot price and a 20% service fee, a mid-ramp fill splits assetsOut
    ///      three ways (lender / filler / service) with no remainder.
    function test_fill_conservation_withYieldAndFee() public {
        _setServiceFee(0.2e18); // 20% of the filler's gross
        (uint256 id, uint256 shares) = _lenderPlace(100 ether, _ramp());
        _donate(10 ether); // 10% yield over the placed price
        _fillAndAssert(id, shares, 12 hours, 0.2e18); // mid-ramp
    }

    /// @dev With no yield and no service fee, a fill pays the lender `owed - priorityFee` and still conserves
    /// assetsOut.
    function test_fill_conservation_noYield_noFee() public {
        _setServiceFee(0);
        (uint256 id, uint256 shares) = _lenderPlace(100 ether, _ramp());
        // no donation -> assetsOut ~= owed, yield ~0; the whole thing flows to the lender minus the priority fee
        _fillAndAssert(id, shares, 12 hours, 0);
    }

    /// @dev At the max service fee and past ramp end (plateau rate), the three-way split still reconstructs assetsOut.
    function test_fill_conservation_maxServiceFee_plateauRate() public {
        _setServiceFee(0.25e18); // MAX_SERVICE_FEE
        (uint256 id, uint256 shares) = _lenderPlace(500 ether, _ramp());
        _donate(73 ether);
        _fillAndAssert(id, shares, 2 days, 0.25e18); // past rampEnd -> plateau (endRate)
    }

    // ── fuzz: exact conservation across the domain ──

    /// @dev Across deposit / yield / serviceFee / elapsed, the lender, filler and service legs always sum to
    ///      assetsOut with no remainder.
    function testFuzz_fill_threeWayConservation(uint256 depositAmt, uint256 yield_, uint256 serviceFee, uint256 elapsed)
        public
    {
        depositAmt = bound(depositAmt, 1 ether, 1_000_000 ether);
        yield_ = bound(yield_, 0, depositAmt); // up to 100% yield
        serviceFee = bound(serviceFee, 0, 0.25e18); // [0, MAX_SERVICE_FEE]
        elapsed = bound(elapsed, 0, 25 days); // spans hold / linear / plateau, within the 30-day deadline

        _setServiceFee(serviceFee);
        (uint256 id, uint256 shares) = _lenderPlace(depositAmt, _ramp());
        if (yield_ != 0) _donate(yield_);
        _fillAndAssert(id, shares, elapsed, serviceFee);
    }

    // ── EXT-02: high-precision quoting (telescoping fills) ──

    /// @dev A zero-priority ramp so the lender leg isolates `owed`.
    function _zeroRamp() internal pure returns (PriorityRamp memory) {
        return PriorityRamp({startRate: 0, endRate: 0, rampStart: 0, rampEnd: 1 days});
    }

    /// @dev The finding's case: `convertToAssets(1e18)` floors to 1, but 1e36 shares are worth 1.9e18. The old
    ///      sample model paid `shares * 1 / 1e18 = 1e18`; the total quote pays the full 1.9e18.
    function test_highPrecisionVault_lenderGetsFullQuote() public {
        ScaledVault sv = new ScaledVault(IERC20(address(asset)), 19, 1e19); // assets = shares * 1.9 / 1e18
        book.setVaultAllowed(IERC4626(address(sv)), true);
        _setServiceFee(0);

        uint256 shares = 1e36; // fits uint128
        sv.mintShares(lender, shares);
        asset.mint(address(sv), 2e18); // fund the redeem
        vm.prank(lender);
        sv.approve(address(book), shares);
        uint256 exitAssets = IERC4626(address(sv)).convertToAssets(shares);
        vm.prank(lender);
        uint256 id = book.placeExitRequest(
            IERC4626(address(sv)), exitAssets, lender, _zeroRamp(), block.timestamp + 30 days, false
        );

        assertEq(
            book.getExitRequest(id).quotedAssets,
            1.9e18,
            "quote is the exact full-request value, not the floored sample"
        );
        assertEq(Math.mulDiv(shares, sv.convertToAssets(1e18), WAD), 1e18, "old sample model would underpay to 1e18");

        uint256 pre = asset.balanceOf(lender);
        vm.prank(filler);
        book.fillExitRequest(id, 0, 0);
        assertEq(asset.balanceOf(lender) - pre, 1.9e18, "lender gets the full 1.9e18");
    }

    /// @dev The ERC-4626 request stores the vault's exact full-share quote across arbitrary representable rates.
    function testFuzz_place_quoteMatchesVaultConversion(uint128 sharesSeed, uint96 numSeed, uint96 denSeed) public {
        uint256 shares = bound(sharesSeed, 1e18, 1e24);
        uint256 num = bound(numSeed, 1, 1e18);
        uint256 den = bound(denSeed, 1, 1e18);
        ScaledVault sv = new ScaledVault(IERC20(address(asset)), num, den);
        book.setVaultAllowed(IERC4626(address(sv)), true);

        sv.mintShares(lender, shares);
        vm.startPrank(lender);
        sv.approve(address(book), shares);
        uint256 id = book.placeExitRequest(
            IERC4626(address(sv)),
            IERC4626(address(sv)).convertToAssets(shares),
            lender,
            _zeroRamp(),
            block.timestamp + 30 days,
            false
        );
        vm.stopPrank();

        // The request is sized in the shares the named assets buy, so the quote must match THOSE shares — the
        // assets -> shares -> assets round trip is allowed to shave, the two sides are not allowed to disagree.
        Request memory request = book.getExitRequest(id);
        assertEq(request.quotedAssets, Math.mulDiv(request.sizeTotal, num, den), "exact ERC-4626 quote");
        assertLe(request.sizeTotal, shares, "never sized above what the lender named");
    }

    /// @dev Partial fills telescope to the full placement quote regardless of how the request is partitioned.
    function test_partialFills_telescopeToQuote() public {
        ScaledVault sv = new ScaledVault(IERC20(address(asset)), 1, 1); // 1:1
        book.setVaultAllowed(IERC4626(address(sv)), true);
        _setServiceFee(0);

        uint256 shares = 10 ether;
        sv.mintShares(lender, shares);
        asset.mint(address(sv), shares); // fund the redeems
        vm.prank(lender);
        sv.approve(address(book), shares);
        uint256 exitAssets = IERC4626(address(sv)).convertToAssets(shares);
        vm.prank(lender);
        uint256 id = book.placeExitRequest(
            IERC4626(address(sv)), exitAssets, lender, _zeroRamp(), block.timestamp + 30 days, false
        );
        uint256 quoted = book.getExitRequest(id).quotedAssets;

        // Fill in an uneven partition (2, 3, 5) by capping the live allowance before each fill.
        uint256[3] memory step = [uint256(2 ether), 3 ether, 5 ether];
        uint256 pre = asset.balanceOf(lender);
        for (uint256 i = 0; i < 3; ++i) {
            vm.prank(lender);
            sv.approve(address(book), step[i]);
            vm.prank(filler);
            book.fillExitRequest(id, 0, 0);
        }

        assertEq(asset.balanceOf(lender) - pre, quoted, "partitioned fills sum to the full quote");
        assertEq(book.getExitRequest(id).sizeRemaining, 0, "fully filled");
    }

    /// @dev Any positive three-part partition telescopes to the exact full-request quote. The non-integral
    ///      share price exercises cumulative rounding rather than a trivial 1:1 split.
    function testFuzz_partialFills_telescopeAcrossPartitions(uint256 firstSeed, uint256 secondSeed) public {
        ScaledVault sv = new ScaledVault(IERC20(address(asset)), 19, 10);
        book.setVaultAllowed(IERC4626(address(sv)), true);
        _setServiceFee(0);

        uint256 shares = 10 ether + 1;
        uint256 first = bound(firstSeed, 1, shares - 2);
        uint256 second = bound(secondSeed, 1, shares - first - 1);
        uint256[3] memory step = [first, second, shares - first - second];

        sv.mintShares(lender, shares);
        asset.mint(address(sv), sv.previewRedeem(shares) + step.length);
        vm.prank(lender);
        sv.approve(address(book), shares);
        uint256 exitAssets = _assetsSizing(IERC4626(address(sv)), shares);
        vm.prank(lender);
        uint256 id = book.placeExitRequest(
            IERC4626(address(sv)), exitAssets, lender, _zeroRamp(), block.timestamp + 30 days, false
        );
        assertEq(book.getExitRequest(id).sizeTotal, shares, "the request is sized to the partitioned shares");

        uint256 quotedAssets = book.getExitRequest(id).quotedAssets;
        uint256 lenderBefore = asset.balanceOf(lender);
        for (uint256 i; i < step.length; ++i) {
            vm.prank(lender);
            sv.approve(address(book), step[i]);
            vm.prank(filler);
            book.fillExitRequest(id, 0, 0);
        }

        assertEq(asset.balanceOf(lender) - lenderBefore, quotedAssets, "all partitions telescope to the quote");
        assertEq(book.getExitRequest(id).sizeRemaining, 0, "partition fully fills the request");
    }

    // ---
    // PAYOUT RECEIVER
    // ---

    /// @dev Placement announces the whole record an indexer needs: the id, the owner and the receiver as topics
    ///      (the three axes anyone filters on), and the size, floor and schedule as data.
    function test_place_announcesTheRecord() public {
        address receiver = address(0xBE33E);
        uint256 depositAmount = 100 ether;
        asset.mint(lender, depositAmount);

        vm.startPrank(lender);
        asset.approve(address(vault), depositAmount);
        uint256 shares = vault.deposit(depositAmount, lender);
        vm.stopPrank();

        uint256 exitAssets = IERC4626(address(vault)).convertToAssets(shares);
        uint256 expectedShares = vault.convertToShares(exitAssets);
        uint256 expectedRate = vault.convertToAssets(book.SHARE_RATE_UNIT());
        uint256 deadline = block.timestamp + 30 days;
        PriorityRamp memory ramp = _ramp();

        vm.expectEmit(true, true, true, true, address(book));
        emit ExitBookBase.ExitRequested(
            book.lastRequestId() + 1,
            lender,
            receiver,
            address(asset),
            expectedShares,
            expectedRate,
            ramp,
            deadline,
            false
        );
        vm.prank(lender);
        book.placeExitRequest(IERC4626(address(vault)), exitAssets, receiver, ramp, deadline, false);
    }

    /// @dev Place a request for `depositAmt` worth of vault shares, paid out to `receiver`. Only the lender's
    ///      own deposit backs it.
    function _lenderPlaceTo(uint256 depositAmt, address receiver) internal returns (uint256 id, uint256 shares) {
        asset.mint(lender, depositAmt);
        vm.startPrank(lender);
        asset.approve(address(vault), depositAmt);
        shares = vault.deposit(depositAmt, lender);
        uint256 exitAssets = IERC4626(address(vault)).convertToAssets(shares);
        id = book.placeExitRequest(
            IERC4626(address(vault)), exitAssets, receiver, _zeroRamp(), block.timestamp + 30 days, false
        );
        vm.stopPrank();
    }

    /// @dev Let the book redeem exactly `shares` of the lender's position, so the next fill is capped there.
    function _allowFill(uint256 shares) internal {
        vm.prank(lender);
        vault.approve(address(book), shares);
    }

    /// @dev The proceeds go to the receiver named at placement, not to the owner whose position is redeemed.
    ///      The owner still supplies the shares, still owns the request, and receives nothing.
    function test_fill_paysTheReceiverNotTheOwner() public {
        _setServiceFee(0);
        address receiver = address(0xBE11E);
        (uint256 id, uint256 shares) = _lenderPlaceTo(100 ether, receiver);
        _allowFill(shares);

        uint256 quoted = book.getExitRequest(id).quotedAssets;
        assertEq(book.getExitRequest(id).receiver, receiver, "the receiver is recorded on the request");

        uint256 lenderBefore = asset.balanceOf(lender);
        uint256 lenderShares = vault.balanceOf(lender);

        vm.prank(filler);
        book.fillExitRequest(id, 0, 0);

        assertEq(asset.balanceOf(receiver), quoted, "the receiver is credited the whole quote");
        assertEq(asset.balanceOf(lender), lenderBefore, "the owner is paid nothing");
        assertEq(lenderShares - vault.balanceOf(lender), shares, "yet the owner's shares are what got redeemed");
        assertEq(book.getExitRequest(id).owner, lender, "and the owner still owns the request");
    }

    /// @dev Every partial fill pays the same receiver; the split is unaffected by the redirect.
    function test_fill_receiverIsPaidOnEveryPartialFill() public {
        _setServiceFee(0);
        address receiver = address(0xBE22E);
        (uint256 id, uint256 shares) = _lenderPlaceTo(100 ether, receiver);

        uint256 quoted = book.getExitRequest(id).quotedAssets;
        uint256 half = shares / 2;

        _allowFill(half);
        vm.prank(filler);
        book.fillExitRequest(id, 0, 0);
        assertEq(asset.balanceOf(receiver), Math.mulDiv(quoted, half, shares), "first partial lands on the receiver");

        _allowFill(shares - half);
        vm.prank(filler);
        book.fillExitRequest(id, 0, 0);
        assertEq(asset.balanceOf(receiver), quoted, "and the tail telescopes to the full quote");
        assertEq(asset.balanceOf(lender), 0, "the owner is never paid");
    }

    /// @dev A request cannot be pointed at the zero address — the proceeds would be burned on every fill.
    function testRevert_place_zeroReceiver() public {
        asset.mint(lender, 10 ether);
        vm.startPrank(lender);
        asset.approve(address(vault), 10 ether);
        vault.deposit(10 ether, lender);
        vm.expectRevert(ExitBookBase.ZeroAddress.selector);
        book.placeExitRequest(
            IERC4626(address(vault)), 10 ether, address(0), _zeroRamp(), block.timestamp + 30 days, false
        );
        vm.stopPrank();
    }

    /// @dev A scanner reads the payout token off the preview: the record does not copy it, so a batch scan over
    ///      a book serving several vaults would otherwise need one extra call per request to learn it.
    function test_previewFill_namesThePayoutToken() public {
        (uint256 id,) = _lenderPlace(100 ether, _zeroRamp());

        MockVault other = new MockVault(IERC20(address(asset)));
        book.setVaultAllowed(IERC4626(address(other)), true);

        assertEq(address(book.previewFill(id).asset), address(vault.asset()), "the preview names the source's token");

        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        assertEq(address(book.getRequestPreviews(ids)[0].asset), address(vault.asset()), "and so does the batch");
    }

    /// @dev The token is resolved from the source, and an id that was never issued has no source. It reports a
    ///      zeroed record instead of reverting, so one unknown id cannot take a whole batch read down with it.
    function test_previewFill_unknownIdReportsNothing() public {
        uint256[] memory ids = new uint256[](2);
        ids[0] = 999;
        ids[1] = 1000;

        RequestPreview memory preview = book.previewFill(999);
        assertEq(address(preview.asset), address(0), "no source, no token");
        assertEq(preview.request.owner, address(0), "and a zeroed record");
        assertEq(preview.filledShares, 0, "nothing fillable");
        assertEq(book.getRequestPreviews(ids).length, 2, "the batch survives every unknown id");
    }

    /// @dev The asset amount a request must be placed with to size exactly `shares` source shares. Placement
    ///      rounds the named assets down to shares, so quoting the shares straight back can land one short.
    function _assetsSizing(IERC4626 v, uint256 shares) internal view returns (uint256 assets) {
        assets = v.convertToAssets(shares);
        while (v.convertToShares(assets) < shares) ++assets;
    }

    /// @dev The current fill's cumulative quote interval is snapshotted before the external redeem. A nested fill
    ///      may advance the request, but cannot move the outer fill's boundaries and capture a rounding unit twice.
    function test_fill_reentrantNestedFill_preservesCumulativeQuote() public {
        ReentrantScaledVault rv = new ReentrantScaledVault(IERC20(address(asset)));
        book.setVaultAllowed(IERC4626(address(rv)), true);
        _setServiceFee(0);

        uint256 shares = 10;
        rv.mintShares(lender, shares);
        asset.mint(address(rv), 20);
        vm.startPrank(lender);
        rv.approve(address(book), shares);
        uint256 id = book.placeExitRequest(
            IERC4626(address(rv)),
            IERC4626(address(rv)).convertToAssets(shares),
            lender,
            _zeroRamp(),
            block.timestamp + 30 days,
            false
        );
        vm.stopPrank();
        rv.arm(book, id, 4);

        uint256 quotedAssets = book.getExitRequest(id).quotedAssets;
        uint256 lenderBefore = asset.balanceOf(lender);
        vm.prank(filler);
        book.fillExitRequest(id, 0, 0);

        assertEq(asset.balanceOf(lender) - lenderBefore, quotedAssets, "nested fills distribute the quote once");
        assertEq(book.getExitRequest(id).sizeRemaining, 0, "nested fill drains the request");
    }

    /// @dev Each partial fill receives the delta of two cumulative quotients. This gives the final fill every
    ///      remainder left by preceding floors, rather than rounding each fill's standalone proportion down.
    function test_partialFills_finalFillGetsRoundingRemainder() public {
        ScaledVault sv = new ScaledVault(IERC20(address(asset)), 19, 10);
        book.setVaultAllowed(IERC4626(address(sv)), true);
        _setServiceFee(0);

        uint256 shares = 10 ether + 1;
        uint256[3] memory step = [uint256(2 ether), 3 ether, 5 ether + 1];
        sv.mintShares(lender, shares);
        asset.mint(address(sv), 20 ether);
        vm.prank(lender);
        sv.approve(address(book), shares);
        uint256 exitAssets = _assetsSizing(IERC4626(address(sv)), shares);
        vm.prank(lender);
        uint256 id = book.placeExitRequest(
            IERC4626(address(sv)), exitAssets, lender, _zeroRamp(), block.timestamp + 30 days, false
        );
        assertEq(book.getExitRequest(id).sizeTotal, shares, "the request is sized to the partitioned shares");
        uint256 quoted = book.getExitRequest(id).quotedAssets;

        uint256 filled;
        uint256 lenderBefore = asset.balanceOf(lender);
        uint256 owedBefore;
        for (uint256 i; i < step.length; ++i) {
            vm.prank(lender);
            sv.approve(address(book), step[i]);
            vm.prank(filler);
            book.fillExitRequest(id, 0, 0);

            filled += step[i];
            uint256 owedAfter = Math.mulDiv(quoted, filled, shares);
            uint256 received = asset.balanceOf(lender) - lenderBefore;
            assertEq(received - owedBefore, owedAfter - owedBefore, "fill receives its cumulative entitlement delta");
            owedBefore = owedAfter;
        }

        uint256 lastStandalone = Math.mulDiv(quoted, step[2], shares);
        uint256 lastCumulative = quoted - Math.mulDiv(quoted, step[0] + step[1], shares);
        assertGt(lastCumulative, lastStandalone, "final fill receives the prior rounding remainder");
        assertEq(asset.balanceOf(lender) - lenderBefore, quoted, "all partitions sum to the full quote");
    }

    /// @dev An 18-decimal ERC-4626 vault quotes to raw-asset precision.
    function test_normalizedVault_quoteMatchesWadSampleWithinOneUnit() public {
        (uint256 id, uint256 shares) = _lenderPlace(100 ether, _zeroRamp());
        uint256 sampled = Math.mulDiv(shares, vault.convertToAssets(WAD), WAD);

        assertApproxEqAbs(book.getExitRequest(id).quotedAssets, sampled, 1, "normalized vault quote remains unchanged");
    }

    /// @dev A request pins the share rate it was placed at, so a loss that moves the rate below it takes the
    ///      request out of play until the price recovers — the lender is never exited into the drop.
    function testRevert_fill_shareRateFellBelowPlacement() public {
        _setServiceFee(0);
        (uint256 id,) = _lenderPlace(100 ether, _ramp());
        uint256 placedRate = book.getExitRequest(id).minShareRate;

        vm.prank(address(vault));
        asset.transfer(address(0xBEEF), 10 ether); // socialise a 10% loss onto the vault's holders
        assertLt(vault.convertToAssets(book.SHARE_RATE_UNIT()), placedRate, "the share rate really fell");

        vm.warp(block.timestamp + 12 hours);
        vm.prank(filler);
        vm.expectRevert(ExitBookBase.ShareRateBelowMinimum.selector);
        book.fillExitRequest(id, 0, 0);
    }

    /// @dev The same request fills once the rate climbs back to where it was placed.
    function test_fill_resumesOnceTheShareRateRecovers() public {
        _setServiceFee(0);
        (uint256 id,) = _lenderPlace(100 ether, _ramp());

        vm.prank(address(vault));
        asset.transfer(address(0xBEEF), 10 ether);
        _donate(10 ether); // the vault is made whole again

        vm.warp(block.timestamp + 12 hours);
        vm.prank(filler);
        book.fillExitRequest(id, 0, 0);
        assertEq(_status(id), uint8(ExitStatus.Filled), "fills once the rate is back");
    }

    /// @dev The price floor holds for any loss, at any age of the request and any service fee: once the share
    ///      rate is below the one pinned at placement, no fill goes through.
    function testFuzz_fill_anyLossBlocksTheFill(
        uint256 depositSeed,
        uint256 lossSeed,
        uint256 elapsedSeed,
        uint256 serviceFeeSeed
    ) public {
        uint256 depositAmt = bound(depositSeed, 1 ether, 1e24);
        uint256 loss = bound(lossSeed, 1, depositAmt - 1);
        uint256 elapsed = bound(elapsedSeed, 0, 25 days);

        _setServiceFee(bound(serviceFeeSeed, 0, 0.25e18));
        (uint256 id,) = _lenderPlace(depositAmt, _ramp());
        vm.prank(address(vault));
        asset.transfer(address(0xBEEF), loss);

        vm.warp(block.timestamp + elapsed);
        assertEq(book.previewFill(id).filledShares, 0, "preview reports nothing fillable");
        vm.prank(filler);
        vm.expectRevert(ExitBookBase.ShareRateBelowMinimum.selector);
        book.fillExitRequest(id, 0, 0);
    }

    /// @dev A quote can exceed `uint128` even though shares fit it, so the common full-request quote is stored
    ///      as uint256.
    function testFuzz_quotedAssetsExceedsUint128(uint256 sharesSeed) public {
        uint256 shares = bound(sharesSeed, 1, 1e18);
        uint256 rate = uint256(type(uint128).max) / shares + 1;
        ScaledVault sv = new ScaledVault(IERC20(address(asset)), rate, 1);
        book.setVaultAllowed(IERC4626(address(sv)), true);

        sv.mintShares(lender, shares);
        vm.prank(lender);
        sv.approve(address(book), shares);
        uint256 exitAssets = IERC4626(address(sv)).convertToAssets(shares);
        vm.prank(lender);
        uint256 id = book.placeExitRequest(
            IERC4626(address(sv)), exitAssets, lender, _zeroRamp(), block.timestamp + 30 days, false
        );

        uint256 quotedAssets = book.getExitRequest(id).quotedAssets;
        assertGt(quotedAssets, type(uint128).max, "quote stored as uint256, above uint128");
        assertEq(quotedAssets, shares * rate, "exact quote");
    }

    /// @dev An asset amount too small to buy a whole share is rejected at placement.
    function testRevert_place_smallAmountBuysNoShares() public {
        ScaledVault sv = new ScaledVault(IERC20(address(asset)), 1, 1000); // price 0.001: convertToAssets(1) == 0
        book.setVaultAllowed(IERC4626(address(sv)), true);
        assertGt(sv.convertToAssets(WAD), 0, "the per-1e18 sample is nonzero (old guard would pass)");

        sv.mintShares(lender, 1);
        vm.startPrank(lender);
        sv.approve(address(book), 1);
        uint256 exitAssets = IERC4626(address(sv)).convertToAssets(1);
        vm.expectRevert(ExitBookBase.ZeroShares.selector);
        book.placeExitRequest(IERC4626(address(sv)), exitAssets, lender, _ramp(), block.timestamp + 30 days, false);
        vm.stopPrank();
    }

    /// @dev Any share amount priced strictly below one asset unit is rejected through the common zero-quote guard.
    function testFuzz_place_zeroAssetQuoteRejected(uint128 sharesSeed) public {
        uint256 shares = bound(sharesSeed, 1, 1e24);
        ScaledVault sv = new ScaledVault(IERC20(address(asset)), 1, shares + 1);
        book.setVaultAllowed(IERC4626(address(sv)), true);

        sv.mintShares(lender, shares);
        vm.startPrank(lender);
        sv.approve(address(book), shares);
        uint256 exitAssets = IERC4626(address(sv)).convertToAssets(shares);
        vm.expectRevert(ExitBookBase.ZeroShares.selector);
        book.placeExitRequest(IERC4626(address(sv)), exitAssets, lender, _zeroRamp(), block.timestamp + 30 days, false);
        vm.stopPrank();
    }

    // ── priority ramp: hold → linear → plateau ──

    /// @dev The implied fee (`owed - lenderAssets`) tracks the ramp rate exactly at three regimes. Service fee
    ///      is 0 so the lender leg isolates `owed - fee`. Separate requests so each fills at its own elapsed.
    function test_priorityRamp_holdLinearPlateau() public {
        _setServiceFee(0);
        PriorityRamp memory ramp = _ramp(); // start 0.02e18, end 0.08e18, [1h, 1d]

        // hold: elapsed < rampStart -> startRate
        _assertRampFee(ramp, 30 minutes, ramp.startRate);
        // linear midpoint: elapsed 12h -> start + (end-start)*(12h-1h)/(1d-1h)
        uint256 mid = ramp.startRate + (ramp.endRate - ramp.startRate) * (12 hours - 1 hours) / (1 days - 1 hours);
        _assertRampFee(ramp, 12 hours, mid);
        // plateau: elapsed >= rampEnd -> endRate
        _assertRampFee(ramp, 2 days, ramp.endRate);
    }

    function _assertRampFee(PriorityRamp memory ramp, uint256 elapsed, uint256 expectedRate) internal {
        (uint256 id, uint256 shares) = _lenderPlace(100 ether, ramp);
        // no donation: assetsOut <= owed snapshot, so owed == assetsOut and fee = owed*rate/WAD
        uint256 startTs = block.timestamp;
        uint256 quotedAssets = book.getExitRequest(id).quotedAssets;
        vm.warp(startTs + elapsed);

        uint256 assetsOut = vault.previewRedeem(shares);
        uint256 owed = Math.min(quotedAssets, assetsOut);
        uint256 expectedFee = Math.mulDiv(owed, expectedRate, WAD);

        uint256 lenderBefore = asset.balanceOf(lender);
        vm.prank(filler);
        book.fillExitRequest(id, 0, 0);
        uint256 lenderGot = asset.balanceOf(lender) - lenderBefore;

        assertEq(lenderGot, owed - expectedFee, "lender leg = owed - fee(rate) at this ramp regime");
    }

    // ── G1: partial fill (Open) then final (Filled) — multi-fill state machine ──

    /// @dev A live allowance cap makes the first fill partial (stays Open with remaining debited); a later fill
    ///      fully drains it to Filled, and the book holds no assets between or after fills.
    function test_fill_partialThenFinal() public {
        _setServiceFee(0);
        (uint256 id, uint256 shares) = _lenderPlace(100 ether, _ramp()); // placed with full backing

        // Cap the fillable slice via the live allowance so the first fill is partial (place needs full
        // allowance; the fill re-reads it through `_availableShares`).
        vm.prank(lender);
        vault.approve(address(book), 40 ether);

        vm.warp(block.timestamp + 12 hours);
        vm.prank(filler);
        book.fillExitRequest(id, 0, 0);
        assertEq(_status(id), uint8(ExitStatus.Open), "still open after a partial fill");
        assertEq(book.getExitRequest(id).sizeRemaining, shares - 40 ether, "remaining debited by the filled slice");

        vm.prank(lender);
        vault.approve(address(book), type(uint256).max); // free the rest
        vm.prank(filler);
        book.fillExitRequest(id, 0, 0);
        assertEq(_status(id), uint8(ExitStatus.Filled), "filled once fully drained");
        assertEq(book.getExitRequest(id).sizeRemaining, 0, "nothing remaining");
        assertEq(asset.balanceOf(address(book)), 0, "book holds nothing between/after fills");
    }

    // ── G2: filler brings liquidity (depositAssets != 0) → filler ends with the minted vault shares ──

    /// @dev When the filler supplies its own deposit liquidity, it ends holding exactly the vault shares that
    ///      deposit mints at the pre-redeem rate.
    function test_fillWithLiquidity_fillerReceivesVaultShares() public {
        _setServiceFee(0);
        (uint256 id, uint256 shares) = _lenderPlace(100 ether, _ramp());

        asset.mint(filler, 50 ether);
        vm.startPrank(filler);
        asset.approve(address(book), 50 ether);
        uint256 expectedFillerShares = vault.previewDeposit(50 ether); // minted at the pre-redeem rate
        book.fillExitRequest(id, 50 ether, 0);
        vm.stopPrank();

        assertEq(_status(id), uint8(ExitStatus.Filled), "filled");
        assertEq(vault.balanceOf(filler), expectedFillerShares, "filler holds exactly the shares its deposit minted");
        assertGt(shares, 0);
    }

    /// @dev A non-zero share amount can still quote to nothing once the share price falls below one asset per
    ///      share, so the zero-quote guard is reachable and stays a caller-facing error.
    function testRevert_place_amountBuysSharesWorthNothing() public {
        _depositAndApprove(100 ether, type(uint256).max);
        vm.prank(address(vault));
        asset.transfer(address(0xBEEF), 10 ether); // 0.9 assets per share

        assertEq(vault.convertToShares(1), 1, "one wei still buys a share");
        assertEq(vault.convertToAssets(1), 0, "but that share is worth nothing back");

        vm.prank(lender);
        vm.expectRevert(IExitBook.ZeroAssetQuote.selector);
        book.placeExitRequest(IERC4626(address(vault)), 1, lender, _ramp(), block.timestamp + 30 days, false);
    }

    /// @dev A request whose price floor is breached reports nothing fillable, so a filler is never sent into a
    ///      revert by the preview.
    function test_previewFill_reportsNothingWhileTheFloorIsBreached() public {
        _setServiceFee(0);
        (uint256 id,) = _lenderPlace(100 ether, _ramp());
        assertGt(book.previewFill(id).filledShares, 0, "fillable before the drop");

        vm.prank(address(vault));
        asset.transfer(address(0xBEEF), 10 ether);

        assertEq(book.previewFill(id).filledShares, 0, "preview agrees with the gate");
        assertEq(book.previewFill(id).assetsOut, 0, "and quotes nothing");

        vm.prank(filler);
        vm.expectRevert(ExitBookBase.ShareRateBelowMinimum.selector);
        book.fillExitRequest(id, 0, 0);
    }

    // ── G3: minAssetsOut slippage floor ──

    /// @dev A minAssetsOut floor above the redeem yield reverts AssetsOutBelowMin; a satisfiable floor fills.
    function test_minAssetsOut_gatesFill() public {
        _setServiceFee(0);
        (uint256 id, uint256 shares) = _lenderPlace(100 ether, _ramp());
        uint256 out = vault.previewRedeem(shares);

        vm.prank(filler);
        vm.expectRevert(ExitBookBase.AssetsOutBelowMin.selector);
        book.fillExitRequest(id, 0, out + 1); // floor above what the redeem yields

        vm.prank(filler);
        book.fillExitRequest(id, 0, out); // satisfiable floor
        assertEq(_status(id), uint8(ExitStatus.Filled), "fills at a satisfiable floor");
    }

    // ── G5: placement validation reverts ──

    /// @dev Placing a ramp whose startRate exceeds its endRate reverts StartFeeAboveEnd.
    function testRevert_place_startFeeAboveEnd() public {
        _depositAndApprove(100 ether, type(uint256).max);
        uint256 exitAssets = IERC4626(address(vault)).convertToAssets(1 ether);
        vm.prank(lender);
        vm.expectRevert(ExitBookBase.StartFeeAboveEnd.selector);
        book.placeExitRequest(
            IERC4626(address(vault)),
            exitAssets,
            lender,
            PriorityRamp({startRate: 0.05e18, endRate: 0.01e18, rampStart: 0, rampEnd: 1 days}),
            block.timestamp + 30 days,
            false
        );
    }

    /// @dev Placing with an endRate above MAX_PRIORITY_FEE reverts PriorityFeeTooHigh.
    function testRevert_place_endFeeTooHigh() public {
        _depositAndApprove(100 ether, type(uint256).max);
        uint256 exitAssets = IERC4626(address(vault)).convertToAssets(1 ether);
        vm.prank(lender);
        vm.expectRevert(ExitBookBase.PriorityFeeTooHigh.selector);
        book.placeExitRequest(
            IERC4626(address(vault)),
            exitAssets,
            lender,
            PriorityRamp({startRate: 0, endRate: 0.2e18, rampStart: 0, rampEnd: 1 days}), // > MAX_PRIORITY_FEE
            block.timestamp + 30 days,
            false
        );
    }

    /// @dev Placing where `now + rampEnd` overruns the deadline reverts RampPastDeadline.
    function testRevert_place_rampPastDeadline() public {
        _depositAndApprove(100 ether, type(uint256).max);
        uint256 exitAssets = IERC4626(address(vault)).convertToAssets(1 ether);
        vm.prank(lender);
        vm.expectRevert(ExitBookBase.RampPastDeadline.selector);
        book.placeExitRequest(
            IERC4626(address(vault)),
            exitAssets,
            lender,
            PriorityRamp({startRate: 0, endRate: 0.05e18, rampStart: 0, rampEnd: 10 days}),
            block.timestamp + 5 days,
            false
        );
    }

    /// @dev Placing a request for zero assets reverts ZeroShares.
    function testRevert_place_zeroShares() public {
        _depositAndApprove(100 ether, type(uint256).max);
        uint256 exitAssets = IERC4626(address(vault)).convertToAssets(0);
        vm.prank(lender);
        vm.expectRevert(ExitBookBase.ZeroShares.selector);
        book.placeExitRequest(IERC4626(address(vault)), exitAssets, lender, _ramp(), block.timestamp + 30 days, false);
    }

    // ── G6: vault allow-list gating ──

    /// @dev Placing against a vault never added to the allow-list reverts VaultNotAllowed.
    function testRevert_place_vaultNotAllowed() public {
        MockVault other = new MockVault(IERC20(address(asset))); // never allowed
        asset.mint(lender, 1 ether);
        vm.startPrank(lender);
        asset.approve(address(other), 1 ether);
        uint256 shares = other.deposit(1 ether, lender);
        other.approve(address(book), shares);
        uint256 exitAssets = IERC4626(address(other)).convertToAssets(shares);
        vm.expectRevert(Erc4626ExitBook.VaultNotAllowed.selector);
        book.placeExitRequest(IERC4626(address(other)), exitAssets, lender, _ramp(), block.timestamp + 30 days, false);
        vm.stopPrank();
    }

    /// @dev Placement takes the lender at their word: an amount past what they hold is accepted, and the fill
    ///      then closes only what the live position backs, leaving the rest outstanding.
    function test_place_acceptsMoreThanTheLenderHolds() public {
        uint256 shares = _depositAndApprove(100 ether, type(uint256).max);
        _setServiceFee(0);

        vm.prank(lender);
        uint256 id = book.placeExitRequest(
            IERC4626(address(vault)), 200 ether, lender, _ramp(), block.timestamp + 30 days, false
        );
        assertGt(book.getExitRequest(id).sizeTotal, shares, "request is larger than the position");

        vm.prank(filler);
        book.fillExitRequest(id, 0, 0);

        assertEq(vault.balanceOf(lender), 0, "the whole position was redeemed");
        assertGt(book.getExitRequest(id).sizeRemaining, 0, "the unbacked remainder stays outstanding");
        assertEq(_status(id), uint8(ExitStatus.Open), "and the request stays open");
    }

    /// @dev A vault whose total quote is 0 (`convertToAssets(shares) == 0`) is rejected: it would pay the lender
    ///      nothing on every fill and route the whole redemption to the filler.
    function testRevert_place_amountBuysNoShares() public {
        ZeroPriceVault zeroPrice = new ZeroPriceVault(IERC20(address(asset)));
        book.setVaultAllowed(IERC4626(address(zeroPrice)), true);

        asset.mint(lender, 1 ether);
        vm.startPrank(lender);
        asset.approve(address(zeroPrice), 1 ether);
        uint256 shares = zeroPrice.deposit(1 ether, lender);
        zeroPrice.approve(address(book), shares);
        uint256 exitAssets = IERC4626(address(zeroPrice)).convertToAssets(shares);
        vm.expectRevert(ExitBookBase.ZeroShares.selector);
        book.placeExitRequest(
            IERC4626(address(zeroPrice)), exitAssets, lender, _ramp(), block.timestamp + 30 days, false
        );
        vm.stopPrank();
    }

    /// @dev Allow-listing the zero-address vault reverts ZeroVault.
    function testRevert_setVaultAllowed_zeroVault() public {
        vm.expectRevert(Erc4626ExitBook.ZeroVault.selector);
        book.setVaultAllowed(IERC4626(address(0)), true);
    }

    /// @dev Disallowing a vault blocks NEW placements but a request already in flight stays fillable (the fill
    ///      resolves the vault via `vaultOf[id]`, never re-checking the allow-list).
    function test_disallowVault_blocksPlaceNotFill() public {
        (uint256 id,) = _lenderPlace(100 ether, _ramp());

        book.setVaultAllowed(IERC4626(address(vault)), false);

        // a fresh placement is now rejected
        uint256 more = _depositAndApprove(10 ether, type(uint256).max);
        uint256 exitAssets = IERC4626(address(vault)).convertToAssets(more);
        vm.prank(lender);
        vm.expectRevert(Erc4626ExitBook.VaultNotAllowed.selector);
        book.placeExitRequest(IERC4626(address(vault)), exitAssets, lender, _ramp(), block.timestamp + 30 days, false);

        // ...but the in-flight request still fills
        vm.prank(filler);
        book.fillExitRequest(id, 0, 0);
        assertEq(_status(id), uint8(ExitStatus.Filled), "in-flight request fills despite the vault being disallowed");
    }

    // ── G7: constructor validation ──

    /// @dev Constructing the book with a zero max request lifetime reverts ZeroMaxLifetime.
    function testRevert_constructor_zeroMaxLifetime() public {
        vm.expectRevert(ExitBookBase.ZeroMaxLifetime.selector);
        new Erc4626ExitBook(address(this), 0);
    }

    function testRevert_constructor_zeroAdmin() public {
        vm.expectRevert(ExitBookBase.ZeroAddress.selector);
        new Erc4626ExitBook(address(0), 365 days);
    }

    // ── G8: setServiceFee validation + happy path ──

    /// @dev Setting a service fee above MAX_SERVICE_FEE reverts FeeTooHigh.
    function testRevert_setServiceFee_feeTooHigh() public {
        uint256 tooHigh = book.MAX_SERVICE_FEE() + 1;
        vm.expectRevert(ExitBookBase.FeeTooHigh.selector);
        book.setServiceFee(feeRecipient, tooHigh);
    }

    function testRevert_setServiceFee_recipientRequired() public {
        // fee != 0 with a zero recipient is rejected; the order matters — fee passes the cap check first.
        vm.expectRevert(ExitBookBase.FeeRecipientRequired.selector);
        book.setServiceFee(address(0), 0.1e18);
    }

    /// @dev A valid fee emits ServiceFeeSet and stores recipient + fee; clearing to a zero fee with a zero
    ///      recipient is allowed and wipes both.
    function test_setServiceFee_happyPath() public {
        vm.expectEmit(true, false, false, true, address(book));
        emit ExitBookBase.ServiceFeeSet(feeRecipient, 0.1e18);
        book.setServiceFee(feeRecipient, 0.1e18);

        assertEq(book.feeRecipient(), feeRecipient, "recipient stored");
        assertEq(book.serviceFee(), 0.1e18, "fee stored");

        // a zero fee with a zero recipient is allowed (clears the fee).
        book.setServiceFee(address(0), 0);
        assertEq(book.feeRecipient(), address(0), "recipient cleared");
        assertEq(book.serviceFee(), 0, "fee cleared");
    }

    // ── G8b: role gating — each capability rejects a non-holder ──

    function testRevert_setVaultAllowed_unauthorized() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, lender, book.ALLOWLIST_MANAGER_ROLE()
            )
        );
        vm.prank(lender);
        book.setVaultAllowed(IERC4626(address(vault)), true);
    }

    function testRevert_setServiceFee_unauthorized() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, lender, book.FEE_MANAGER_ROLE()
            )
        );
        vm.prank(lender);
        book.setServiceFee(feeRecipient, 0.1e18);
    }

    function testRevert_recoverERC20_unauthorized() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, lender, book.RECOVERER_ROLE()
            )
        );
        vm.prank(lender);
        book.recoverERC20(address(asset), lender, 1);
    }

    // ── G9: NoAssetsRedeemed — a fill whose redeem produces zero assets ──

    /// @dev A fill whose redeem yields a zero asset delta despite real backing reverts NoAssetsRedeemed.
    function test_fill_noAssetsRedeemed_reverts() public {
        ZeroRedeemVault zv = new ZeroRedeemVault(IERC20(address(asset)));
        book.setVaultAllowed(IERC4626(address(zv)), true);

        asset.mint(lender, 100 ether);
        vm.startPrank(lender);
        asset.approve(address(zv), 100 ether);
        uint256 shares = zv.deposit(100 ether, lender);
        zv.approve(address(book), shares);
        uint256 id = book.placeExitRequest(
            IERC4626(address(zv)),
            IERC4626(address(zv)).convertToAssets(shares),
            lender,
            _ramp(),
            block.timestamp + 30 days,
            false
        );
        vm.stopPrank();

        // filledShares > 0 (real backing) but the redeem yields a zero asset delta -> NoAssetsRedeemed.
        vm.prank(filler);
        vm.expectRevert(ExitBookBase.NoAssetsRedeemed.selector);
        book.fillExitRequest(id, 0, 0);
    }

    // ── G10: cancelExitRequest at the contract level ──

    /// @dev The owner cancelling emits ExitCancelled, marks the request Cancelled, and zeroes its remaining size.
    function test_cancelExitRequest_marksCancelledAndEmits() public {
        (uint256 id,) = _lenderPlace(100 ether, _ramp());

        vm.expectEmit(true, false, false, false, address(book));
        emit ExitBookBase.ExitCancelled(id);
        vm.prank(lender);
        book.cancelExitRequest(id);

        assertEq(_status(id), uint8(ExitStatus.Cancelled), "request marked cancelled");
        assertEq(book.getExitRequest(id).sizeRemaining, 0, "remaining zeroed on cancel");
    }

    /// @dev A non-owner cancelling another account's request reverts NotOwner.
    function testRevert_cancelExitRequest_notOwner() public {
        (uint256 id,) = _lenderPlace(100 ether, _ramp());

        vm.prank(filler);
        vm.expectRevert(ExitBookLib.NotOwner.selector);
        book.cancelExitRequest(id);
    }

    // ── G12: remaining placement-validation reverts ──

    /// @dev Placing a ramp whose rampStart is after its rampEnd reverts RampStartAfterEnd.
    function testRevert_place_rampStartAfterEnd() public {
        _depositAndApprove(100 ether, type(uint256).max);
        uint256 exitAssets = IERC4626(address(vault)).convertToAssets(1 ether);
        vm.prank(lender);
        vm.expectRevert(ExitBookBase.RampStartAfterEnd.selector);
        book.placeExitRequest(
            IERC4626(address(vault)),
            exitAssets,
            lender,
            PriorityRamp({startRate: 0, endRate: 0.05e18, rampStart: 2 days, rampEnd: 1 days}), // start > end
            block.timestamp + 30 days,
            false
        );
    }

    /// @dev Placing with a deadline at or before the current time reverts DeadlineInPast.
    function testRevert_place_deadlineInPast() public {
        _depositAndApprove(100 ether, type(uint256).max);
        uint256 exitAssets = IERC4626(address(vault)).convertToAssets(1 ether);
        vm.prank(lender);
        vm.expectRevert(ExitBookBase.DeadlineInPast.selector);
        book.placeExitRequest(IERC4626(address(vault)), exitAssets, lender, _ramp(), block.timestamp, false);
    }

    /// @dev Placing with a deadline beyond `now + MAX_REQUEST_LIFETIME` reverts DeadlineTooFar.
    function testRevert_place_deadlineTooFar() public {
        _depositAndApprove(100 ether, type(uint256).max);
        uint256 exitAssets = IERC4626(address(vault)).convertToAssets(1 ether);
        vm.prank(lender);
        vm.expectRevert(ExitBookBase.DeadlineTooFar.selector);
        book.placeExitRequest(
            IERC4626(address(vault)), exitAssets, lender, _ramp(), block.timestamp + 365 days + 1, false
        );
    }

    // ── views ──

    // ── G4: view functions ──

    /// @dev previewFill reports exact fillable shares and assetsOut; owner listing counts, paginates and clamps;
    ///      batch reads return zeroed rows for unknown ids without reverting.
    function test_views_previewAndListing() public {
        _setServiceFee(0);
        (uint256 id1, uint256 shares1) = _lenderPlace(100 ether, _ramp());
        (uint256 id2,) = _lenderPlace(50 ether, _ramp());
        // The book allowance is shared across an owner's requests (and the per-place approve overwrites it);
        // approve the full backing so both requests preview as fully fillable.
        vm.prank(lender);
        vault.approve(address(book), type(uint256).max);

        // previewFill: exact fillable + assetsOut
        RequestPreview memory p = book.previewFill(id1);
        assertEq(p.id, id1, "preview id");
        assertEq(p.filledShares, shares1, "fully fillable (ample liquidity)");
        assertEq(p.assetsOut, vault.previewRedeem(shares1), "preview assetsOut == previewRedeem");

        // owner listing + pagination clamp
        assertEq(book.getOwnerRequestCount(lender), 2, "two requests for the lender");
        uint256[] memory ids = book.getOwnerRequestIds(lender, 0, 10);
        assertEq(ids.length, 2, "clamped to the count");
        assertEq(ids[0], id1);
        assertEq(ids[1], id2);
        assertEq(book.getOwnerRequestIds(lender, 1, 10).length, 1, "offset trims the head");
        assertEq(book.getOwnerRequestIds(lender, 5, 10).length, 0, "offset past end -> empty");
        assertEq(book.getOwnerRequestCount(filler), 0, "filler placed nothing");

        // batch reads, including an unknown id -> zeroed row, no revert
        uint256[] memory query = new uint256[](3);
        (query[0], query[1], query[2]) = (id1, id2, 999);
        Request[] memory rs = book.getRequests(query);
        assertEq(rs.length, 3);
        assertEq(rs[0].owner, lender);
        assertEq(rs[2].owner, address(0), "unknown id -> zeroed Request");

        RequestPreview[] memory ps = book.getRequestPreviews(query);
        assertEq(ps.length, 3);
        assertEq(ps[0].id, id1);
        assertEq(ps[2].filledShares, 0, "unknown id -> zero fillable");
        assertEq(ps[2].assetsOut, 0, "unknown id -> zero assetsOut");
    }

    // ── G11: lastRequestId view ──

    /// @dev lastRequestId starts at zero and advances to the id of each newly placed request.
    function test_lastRequestId_tracksLatest() public {
        assertEq(book.lastRequestId(), 0, "no requests issued yet");
        (uint256 id1,) = _lenderPlace(100 ether, _ramp());
        assertEq(book.lastRequestId(), id1, "tracks the first id");
        (uint256 id2,) = _lenderPlace(50 ether, _ramp());
        assertEq(book.lastRequestId(), id2, "tracks the latest id");
    }
}
