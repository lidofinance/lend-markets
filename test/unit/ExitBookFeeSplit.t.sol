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

/// @notice Exact three-way conservation of `ExitBookBase.fillExitRequest` — the fee split that the deleted
///         `WithdrawalMathLib` once covered, now inlined in the base. For a fill that arrives with `assetsOut`:
///           owed        = min(filledShares * pricePerShare / WAD, assetsOut)
///           fee         = owed * priorityRate / WAD
///           lenderAssets= owed - fee
///           fillerGross = (assetsOut - owed) + fee
///           serviceCut  = fillerGross * serviceFee / WAD
///           fillerFee   = fillerGross - serviceCut
///         The invariant is `lenderAssets + fillerFee + serviceCut == assetsOut` with NO remainder. Every
///         component is recomputed independently from the on-chain `pricePerShare`, the previewed `assetsOut`,
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
        id = book.placeExitRequest(IERC4626(address(vault)), shares, ramp, block.timestamp + 30 days, false);
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

    /// @dev Independent recompute, mirroring `ExitBookBase.fillExitRequest`.
    function _expectedSplit(uint256 shares, uint256 pricePerShare, uint256 assetsOut, uint256 rate, uint256 serviceFee)
        internal
        pure
        returns (Split memory s)
    {
        uint256 owed = Math.min(Math.mulDiv(shares, pricePerShare, WAD), assetsOut);
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
        Split memory s = _expectedSplit(
            shares,
            book.getExitRequest(id).pricePerShare,
            vault.previewRedeem(shares),
            _priorityRate(_ramp(), elapsed),
            serviceFee
        );

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
        vm.prank(lender);
        return book.placeExitRequest(IERC4626(address(vault)), shares, ramp, deadline, false);
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
        uint256 pricePerShare = book.getExitRequest(id).pricePerShare;
        vm.warp(startTs + elapsed);

        uint256 assetsOut = vault.previewRedeem(shares);
        uint256 owed = Math.min(Math.mulDiv(shares, pricePerShare, WAD), assetsOut);
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
        vm.prank(lender);
        vm.expectRevert(ExitBookBase.StartFeeAboveEnd.selector);
        book.placeExitRequest(
            IERC4626(address(vault)),
            1 ether,
            PriorityRamp({startRate: 0.05e18, endRate: 0.01e18, rampStart: 0, rampEnd: 1 days}),
            block.timestamp + 30 days,
            false
        );
    }

    /// @dev Placing with an endRate above MAX_PRIORITY_FEE reverts PriorityFeeTooHigh.
    function testRevert_place_endFeeTooHigh() public {
        _depositAndApprove(100 ether, type(uint256).max);
        vm.prank(lender);
        vm.expectRevert(ExitBookBase.PriorityFeeTooHigh.selector);
        book.placeExitRequest(
            IERC4626(address(vault)),
            1 ether,
            PriorityRamp({startRate: 0, endRate: 0.2e18, rampStart: 0, rampEnd: 1 days}), // > MAX_PRIORITY_FEE
            block.timestamp + 30 days,
            false
        );
    }

    /// @dev Placing where `now + rampEnd` overruns the deadline reverts RampPastDeadline.
    function testRevert_place_rampPastDeadline() public {
        _depositAndApprove(100 ether, type(uint256).max);
        vm.prank(lender);
        vm.expectRevert(ExitBookBase.RampPastDeadline.selector);
        book.placeExitRequest(
            IERC4626(address(vault)),
            1 ether,
            PriorityRamp({startRate: 0, endRate: 0.05e18, rampStart: 0, rampEnd: 10 days}),
            block.timestamp + 5 days, // now + rampEnd(10d) > deadline(5d)
            false
        );
    }

    /// @dev Placing a request for zero shares reverts ZeroShares.
    function testRevert_place_zeroShares() public {
        _depositAndApprove(100 ether, type(uint256).max);
        vm.prank(lender);
        vm.expectRevert(ExitBookBase.ZeroShares.selector);
        book.placeExitRequest(IERC4626(address(vault)), 0, _ramp(), block.timestamp + 30 days, false);
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
        vm.expectRevert(Erc4626ExitBook.VaultNotAllowed.selector);
        book.placeExitRequest(IERC4626(address(other)), shares, _ramp(), block.timestamp + 30 days, false);
        vm.stopPrank();
    }

    /// @dev Placing more shares than the owner's backing covers reverts InsufficientBacking.
    function testRevert_place_insufficientBacking() public {
        uint256 shares = _depositAndApprove(100 ether, type(uint256).max);
        vm.prank(lender);
        vm.expectRevert(Erc4626ExitBook.InsufficientBacking.selector);
        book.placeExitRequest(IERC4626(address(vault)), shares + 1, _ramp(), block.timestamp + 30 days, false);
    }

    /// @dev A vault whose snapshot price is 0 is rejected up front — the check precedes the backing check, so no
    ///      shares or allowance are needed to trip it.
    function testRevert_place_zeroPricePerShare() public {
        ZeroPriceVault zeroPrice = new ZeroPriceVault(IERC20(address(asset)));
        book.setVaultAllowed(IERC4626(address(zeroPrice)), true);
        vm.expectRevert(Erc4626ExitBook.ZeroPricePerShare.selector);
        book.placeExitRequest(IERC4626(address(zeroPrice)), 1 ether, _ramp(), block.timestamp + 30 days, false);
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
        vm.prank(lender);
        vm.expectRevert(Erc4626ExitBook.VaultNotAllowed.selector);
        book.placeExitRequest(IERC4626(address(vault)), more, _ramp(), block.timestamp + 30 days, false);

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
        uint256 id = book.placeExitRequest(IERC4626(address(zv)), shares, _ramp(), block.timestamp + 30 days, false);
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
        vm.prank(lender);
        vm.expectRevert(ExitBookBase.RampStartAfterEnd.selector);
        book.placeExitRequest(
            IERC4626(address(vault)),
            1 ether,
            PriorityRamp({startRate: 0, endRate: 0.05e18, rampStart: 2 days, rampEnd: 1 days}), // start > end
            block.timestamp + 30 days,
            false
        );
    }

    /// @dev Placing with a deadline at or before the current time reverts DeadlineInPast.
    function testRevert_place_deadlineInPast() public {
        _depositAndApprove(100 ether, type(uint256).max);
        vm.prank(lender);
        vm.expectRevert(ExitBookBase.DeadlineInPast.selector);
        book.placeExitRequest(
            IERC4626(address(vault)),
            1 ether,
            _ramp(),
            block.timestamp, // deadline <= now
            false
        );
    }

    /// @dev Placing with a deadline beyond `now + MAX_REQUEST_LIFETIME` reverts DeadlineTooFar.
    function testRevert_place_deadlineTooFar() public {
        _depositAndApprove(100 ether, type(uint256).max);
        vm.prank(lender);
        vm.expectRevert(ExitBookBase.DeadlineTooFar.selector);
        book.placeExitRequest(
            IERC4626(address(vault)),
            1 ether,
            _ramp(),
            block.timestamp + 365 days + 1, // > now + MAX_REQUEST_LIFETIME
            false
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
