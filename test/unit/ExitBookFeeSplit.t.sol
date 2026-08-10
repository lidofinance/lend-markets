// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ERC4626Fees} from "@openzeppelin/contracts/mocks/docs/ERC4626Fees.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

import {Erc4626ExitBook} from "../../src/periphery/Erc4626ExitBook.sol";
import {ExitBookBase} from "../../src/periphery/ExitBookBase.sol";
import {ExitBookLib} from "../../src/libs/ExitBookLib.sol";
import {Request, PriorityRamp, ExitStatus} from "../../src/types/ExitBookTypes.sol";

contract MockAsset is ERC20 {
    error TransferBlocked(address recipient);

    address internal _blockedRecipient;

    constructor() ERC20("Asset", "AST") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setBlockedRecipient(address recipient) external {
        _blockedRecipient = recipient;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (_blockedRecipient != address(0) && from != address(0) && to == _blockedRecipient) {
            revert TransferBlocked(to);
        }

        super._update(from, to, value);
    }
}

contract MockVault is ERC4626 {
    constructor(IERC20 asset_) ERC20("Vault", "vAST") ERC4626(asset_) {}
}

/// @dev Models a vault whose `maxWithdraw` includes a live liquidity cap. Deposits increase that cap one-for-one.
contract LiquidityCappedVault is ERC4626 {
    uint256 internal _availableLiquidity;

    constructor(IERC20 asset_) ERC20("Liquidity Capped Vault", "lcAST") ERC4626(asset_) {}

    function setAvailableLiquidity(uint256 availableLiquidity_) external {
        _availableLiquidity = availableLiquidity_;
    }

    function availableLiquidity() external view returns (uint256) {
        return _availableLiquidity;
    }

    function maxWithdraw(address owner) public view override returns (uint256) {
        return Math.min(super.maxWithdraw(owner), _availableLiquidity);
    }

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        super._deposit(caller, receiver, assets, shares);
        _availableLiquidity += assets;
    }

    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        override
    {
        _availableLiquidity -= assets;
        super._withdraw(caller, receiver, owner, assets, shares);
    }
}

/// @dev Burns the requested shares but deliberately transfers no assets.
contract ZeroWithdrawVault is LiquidityCappedVault {
    constructor(IERC20 asset_) LiquidityCappedVault(asset_) {}

    function withdraw(uint256 assets, address, address owner) public override returns (uint256 shares) {
        shares = previewWithdraw(assets);
        if (msg.sender != owner) _spendAllowance(owner, msg.sender, shares);
        _burn(owner, shares);
    }
}

/// @dev Transfers one asset unit more than requested so exact-output enforcement can be tested in both directions.
contract ExcessWithdrawVault is ERC4626 {
    constructor(IERC20 asset_) ERC20("Excess Withdraw Vault", "xwAST") ERC4626(asset_) {}

    function withdraw(uint256 assets, address receiver, address owner) public override returns (uint256 shares) {
        shares = super.withdraw(assets, receiver, owner);
        require(IERC20(asset()).transfer(receiver, 1));
    }
}

/// @dev A 10% exit fee makes `previewWithdraw` materially different from `convertToShares`.
contract ExitFeeVault is ERC4626Fees {
    address internal immutable exitFeeRecipient;

    constructor(IERC20 asset_, address exitFeeRecipient_) ERC20("Exit Fee Vault", "efAST") ERC4626(asset_) {
        exitFeeRecipient = exitFeeRecipient_;
    }

    function _exitFeeBasisPoints() internal pure override returns (uint256) {
        return 1_000;
    }

    function _exitFeeRecipient() internal view override returns (address) {
        return exitFeeRecipient;
    }
}

/// @notice Unit coverage for exact, asset-denominated ERC-4626 exits and their payout split.
contract ExitBookFeeSplitTest is Test {
    uint256 internal constant WAD = 1e18;

    MockAsset internal asset;
    MockVault internal vault;
    Erc4626ExitBook internal book;

    address internal lender = address(0x1E11dE7);
    address internal receiver = address(0xBE11E);
    address internal filler = address(0xF111E7);
    address internal rewardRecipient = address(0xB0B);
    address internal feeRecipient = address(0xFEE);
    address internal exitFeeRecipient = address(0xE17FEE);

    function setUp() public {
        vm.warp(1_000_000);
        asset = new MockAsset();
        vault = new MockVault(IERC20(address(asset)));
        book = new Erc4626ExitBook(address(this), 365 days);
        book.grantRole(book.ALLOWLIST_MANAGER_ROLE(), address(this));
        book.grantRole(book.FEE_MANAGER_ROLE(), address(this));
        book.grantRole(book.PAUSER_ROLE(), address(this));
        book.grantRole(book.RESUMER_ROLE(), address(this));
        book.setVaultAllowed(IERC4626(address(vault)), true);
    }

    function _setServiceFee(uint256 fee) internal {
        book.setServiceFee(feeRecipient, fee);
    }

    function _ramp() internal pure returns (PriorityRamp memory) {
        return PriorityRamp({startRate: 0.02e18, endRate: 0.08e18, rampStart: 1 hours, rampEnd: 1 days});
    }

    function _lenderPlace(uint256 depositAmt, PriorityRamp memory ramp) internal returns (uint256 id, uint256 shares) {
        asset.mint(lender, depositAmt);
        vm.startPrank(lender);
        asset.approve(address(vault), depositAmt);
        shares = vault.deposit(depositAmt, lender);
        vault.approve(address(book), shares);
        id = book.placeExitRequest(IERC4626(address(vault)), depositAmt, lender, 0, 0, ramp, block.timestamp + 30 days);
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
        uint256 receiverAssets;
        uint256 fillerReward;
        uint256 serviceCut;
    }

    function _expectedSplit(uint256 filledAssets, uint256 priorityRate, uint256 serviceFee)
        internal
        pure
        returns (Split memory split)
    {
        uint256 priorityFee = Math.mulDiv(filledAssets, priorityRate, WAD);
        split.serviceCut = Math.mulDiv(priorityFee, serviceFee, WAD);
        split.fillerReward = priorityFee - split.serviceCut;
        split.receiverAssets = filledAssets - priorityFee;
    }

    /// @dev Fill request `id` for exactly `assets` and assert the exact three-way split + conservation.
    ///      `elapsed` is the time since placement (sets the ramp rate); `serviceFee` is already set.
    function _fillAndAssert(uint256 id, uint256 assets, uint256 elapsed, uint256 serviceFee) internal {
        vm.warp(block.timestamp + elapsed);
        Split memory expected = _expectedSplit(assets, _priorityRate(_ramp(), elapsed), serviceFee);

        uint256[3] memory pre = [asset.balanceOf(lender), asset.balanceOf(filler), asset.balanceOf(feeRecipient)];
        vm.prank(filler);
        book.fillExitRequest(id, assets, filler);

        uint256 lenderGot = asset.balanceOf(lender) - pre[0];
        uint256 fillerGot = asset.balanceOf(filler) - pre[1];
        uint256 feeGot = asset.balanceOf(feeRecipient) - pre[2];
        assertEq(lenderGot, expected.receiverAssets, "lender share exact");
        assertEq(fillerGot, expected.fillerReward, "filler share exact");
        assertEq(feeGot, expected.serviceCut, "service cut exact");
        assertEq(lenderGot + fillerGot + feeGot, assets, "three-way conservation == assets");
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

    function _place(uint256 assets, PriorityRamp memory ramp, uint256 deadline) internal returns (uint256) {
        vm.prank(lender);
        return book.placeExitRequest(IERC4626(address(vault)), assets, lender, 0, 0, ramp, deadline);
    }

    function _status(uint256 id) internal view returns (uint8) {
        return uint8(book.getExitRequest(id).status);
    }

    function _deposit(IERC4626 source, uint256 assets) internal returns (uint256 shares) {
        asset.mint(lender, assets);
        vm.startPrank(lender);
        asset.approve(address(source), assets);
        shares = source.deposit(assets, lender);
        vm.stopPrank();
    }

    function _approve(IERC4626 source, uint256 shares) internal {
        vm.prank(lender);
        source.approve(address(book), shares);
    }

    function _place(IERC4626 source, uint256 assets, address receiver, uint256 minFillAssets, PriorityRamp memory ramp)
        internal
        returns (uint256 id)
    {
        return _placeAt(source, assets, receiver, minFillAssets, ramp, block.timestamp + 30 days);
    }

    function _placeAt(
        IERC4626 source,
        uint256 assets,
        address receiver,
        uint256 minFillAssets,
        PriorityRamp memory ramp,
        uint256 deadline
    ) internal returns (uint256 id) {
        vm.prank(lender);
        id = book.placeExitRequest(source, assets, receiver, minFillAssets, 0, ramp, deadline);
    }

    function _depositAndPlace(
        IERC4626 source,
        uint256 depositAssets,
        uint256 requestAssets,
        address receiver,
        uint256 minFillAssets,
        PriorityRamp memory ramp
    ) internal returns (uint256 id, uint256 shares) {
        book.setVaultAllowed(source, true);
        shares = _deposit(source, depositAssets);
        _approve(source, type(uint256).max);
        id = _place(source, requestAssets, receiver, minFillAssets, ramp);
    }

    function _depositAndPlace(
        uint256 depositAssets,
        uint256 requestAssets,
        address receiver,
        uint256 minFillAssets,
        PriorityRamp memory ramp
    ) internal returns (uint256 id, uint256 shares) {
        return _depositAndPlace(IERC4626(address(vault)), depositAssets, requestAssets, receiver, minFillAssets, ramp);
    }

    // ── mutations ──

    // ── concrete ──

    function test_fill_withYieldRetainsLenderYieldAndRoutesReward() public {
        uint256 serviceFee = 0.2e18;
        PriorityRamp memory ramp = _ramp();
        (uint256 id,) = _depositAndPlace(100 ether, 100 ether, receiver, 0, ramp);
        _donate(10 ether);
        _setServiceFee(serviceFee);
        uint256 elapsed = 12 hours;
        Split memory expected = _expectedSplit(100 ether, _priorityRate(ramp, elapsed), serviceFee);
        uint256 liveShares = vault.previewWithdraw(100 ether);

        vm.warp(block.timestamp + elapsed);
        uint256 receiverBefore = asset.balanceOf(receiver);
        uint256 fillerBefore = asset.balanceOf(filler);
        uint256 rewardBefore = asset.balanceOf(rewardRecipient);
        uint256 serviceBefore = asset.balanceOf(feeRecipient);
        uint256 lenderSharesBefore = vault.balanceOf(lender);
        vm.expectEmit(true, true, true, true, address(book));
        emit ExitBookBase.ExitProcessed(
            id,
            filler,
            rewardRecipient,
            address(asset),
            100 ether,
            liveShares,
            expected.fillerReward,
            expected.serviceCut
        );
        vm.prank(filler);
        book.fillExitRequest(id, 100 ether, rewardRecipient);

        uint256 receiverGot = asset.balanceOf(receiver) - receiverBefore;
        uint256 rewardGot = asset.balanceOf(rewardRecipient) - rewardBefore;
        uint256 serviceGot = asset.balanceOf(feeRecipient) - serviceBefore;
        assertEq(receiverGot, expected.receiverAssets);
        assertEq(asset.balanceOf(filler), fillerBefore, "caller receives no liquid reward");
        assertEq(rewardGot, expected.fillerReward);
        assertEq(serviceGot, expected.serviceCut);
        assertEq(receiverGot + rewardGot + serviceGot, 100 ether);
        assertEq(lenderSharesBefore - vault.balanceOf(lender), liveShares, "only exact fill assets are withdrawn");
        assertGe(vault.previewRedeem(vault.balanceOf(lender)), 10 ether - 1, "accrued yield remains with owner");
        assertEq(asset.balanceOf(address(book)), 0);
    }

    /// @dev With no yield and no service fee, a fill pays the lender `fillAssets - priorityFee` and still
    ///      conserves assetsOut.
    function test_fill_conservation_noYield_noFee() public {
        _setServiceFee(0);
        (uint256 id,) = _lenderPlace(100 ether, _ramp());
        _fillAndAssert(id, 100 ether, 12 hours, 0);
    }

    /// @dev At the max service fee and past ramp end (plateau rate), the three-way split still reconstructs assetsOut.
    function test_fill_conservation_maxServiceFee_plateauRate() public {
        _setServiceFee(0.25e18);
        (uint256 id,) = _lenderPlace(500 ether, _ramp());
        _donate(73 ether);
        _fillAndAssert(id, 500 ether, 2 days, 0.25e18);
    }

    // ── fuzz: exact conservation across the domain ──

    /// @dev Across deposit / yield / serviceFee / elapsed, the lender, filler and service legs always sum to
    ///      assetsOut with no remainder.
    function testFuzz_fill_threeWayConservation(uint256 depositAmt, uint256 yield_, uint256 serviceFee, uint256 elapsed)
        public
    {
        depositAmt = bound(depositAmt, 1 ether, 1_000_000 ether);
        yield_ = bound(yield_, 0, depositAmt);
        serviceFee = bound(serviceFee, 0, book.MAX_SERVICE_FEE());
        elapsed = bound(elapsed, 0, 25 days);

        _setServiceFee(serviceFee);
        (uint256 id,) = _lenderPlace(depositAmt, _ramp());
        if (yield_ != 0) _donate(yield_);
        _fillAndAssert(id, depositAmt, elapsed, serviceFee);
    }

    function _zeroRamp() internal pure returns (PriorityRamp memory) {
        return PriorityRamp({startRate: 0, endRate: 0, rampStart: 0, rampEnd: 1 days});
    }

    // ── asset-native requests ──

    function test_place_storesAssetRequestAndEmits() public {
        uint256 assets = 100 ether;
        uint256 minFillAssets = 10 ether;
        uint128 maxShareBurn = 125 ether;
        PriorityRamp memory ramp = _ramp();
        _deposit(IERC4626(address(vault)), 150 ether);
        _approve(IERC4626(address(vault)), type(uint256).max);

        vm.expectEmit(true, true, true, true, address(book));
        emit ExitBookBase.ExitRequested(
            1, lender, receiver, address(asset), assets, minFillAssets, maxShareBurn, ramp, block.timestamp + 30 days
        );
        vm.prank(lender);
        uint256 id = book.placeExitRequest(
            IERC4626(address(vault)), assets, receiver, minFillAssets, maxShareBurn, ramp, block.timestamp + 30 days
        );

        Request memory request = book.getExitRequest(id);
        assertEq(request.owner, lender);
        assertEq(request.receiver, receiver);
        assertEq(address(request.asset), address(asset));
        assertEq(request.assetsTotal, assets);
        assertEq(request.assetsRemaining, assets);
        assertEq(request.minFillAssets, minFillAssets);
        assertEq(request.maxShareBurn, maxShareBurn);
        assertEq(address(book.vaultOf(id)), address(vault));
    }

    function testRevert_place_maxShareBurnBelowQuote() public {
        uint256 assets = 100 ether;
        uint256 shares = _deposit(IERC4626(address(vault)), assets);
        _approve(IERC4626(address(vault)), shares);
        uint256 requiredShares = vault.previewWithdraw(assets);

        vm.prank(lender);
        vm.expectRevert(
            abi.encodeWithSelector(ExitBookBase.MaxShareBurnBelowQuote.selector, requiredShares - 1, requiredShares)
        );
        book.placeExitRequest(
            IERC4626(address(vault)), assets, lender, 0, requiredShares - 1, _zeroRamp(), block.timestamp + 30 days
        );
    }

    function test_maxShareBurn_splitFillsCanExceedNominalBudgetWithinCeilBound() public {
        ExitFeeVault source = new ExitFeeVault(IERC20(address(asset)), exitFeeRecipient);
        book.setVaultAllowed(IERC4626(address(source)), true);
        uint256 fillCount = 10;
        uint256 assets = 10;
        uint256 shares = _deposit(IERC4626(address(source)), 20);
        _approve(IERC4626(address(source)), shares);
        uint256 maxShareBurn = source.previewWithdraw(assets);
        assertEq(maxShareBurn, 11, "one-shot quote includes one fee unit");
        uint256 perFillLimit = Math.mulDiv(maxShareBurn, 1, assets, Math.Rounding.Ceil);
        assertEq(perFillLimit, 2, "each small fill gets two share units");

        vm.prank(lender);
        uint256 id = book.placeExitRequest(
            IERC4626(address(source)), assets, lender, 1, maxShareBurn, _zeroRamp(), block.timestamp + 30 days
        );

        uint256 sharesBefore = source.balanceOf(lender);
        for (uint256 i = 0; i < fillCount; ++i) {
            // The per-call exit fee rounds up, so every fill reaches its ceiling-rounded share limit.
            assertEq(source.previewWithdraw(1), perFillLimit, "live burn reaches the per-fill limit");
            uint256 sharesBeforeFill = source.balanceOf(lender);
            vm.prank(filler);
            book.fillExitRequest(id, 1, filler);
            assertEq(sharesBeforeFill - source.balanceOf(lender), 2, "each small fill burns two shares");
            assertEq(book.getExitRequest(id).assetsRemaining, assets - i - 1, "exact remainder");
        }

        uint256 sharesBurned = sharesBefore - source.balanceOf(lender);
        assertGt(sharesBurned, maxShareBurn, "split fills exceed the nominal budget");
        assertEq(sharesBurned, maxShareBurn + fillCount - 1, "burn reaches the exact n-fill ceiling bound");
        assertEq(source.balanceOf(lender), 0, "all source shares burned");
        assertEq(asset.balanceOf(exitFeeRecipient), fillCount, "one rounded fee unit paid per fill");
        assertEq(_status(id), uint8(ExitStatus.Filled));
    }

    function testFuzz_maxShareBurn_splitPartitionReachesCumulativeCeilBound(
        uint8 assetsSeed,
        uint8 fillCountSeed,
        uint256 partitionSeed
    ) public {
        ExitFeeVault source = new ExitFeeVault(IERC20(address(asset)), exitFeeRecipient);
        book.setVaultAllowed(IERC4626(address(source)), true);
        uint256 assets = bound(uint256(assetsSeed), 2, 10);
        uint256 fillCount = bound(uint256(fillCountSeed), 2, assets);
        uint256 shares = _deposit(IERC4626(address(source)), assets + fillCount);
        _approve(IERC4626(address(source)), shares);
        uint256 maxShareBurn = source.previewWithdraw(assets);
        assertEq(maxShareBurn, assets + 1, "one-shot quote has one rounded fee unit");

        vm.prank(lender);
        uint256 id = book.placeExitRequest(
            IERC4626(address(source)), assets, lender, 1, maxShareBurn, _zeroRamp(), block.timestamp + 30 days
        );

        uint256 sharesBefore = source.balanceOf(lender);
        uint256 remaining = assets;
        for (uint256 i = 0; i < fillCount; ++i) {
            uint256 remainingFills = fillCount - i;
            uint256 fillAssets = remaining;
            if (remainingFills > 1) {
                uint256 maxPart = remaining - (remainingFills - 1);
                fillAssets = 1 + uint256(keccak256(abi.encode(partitionSeed, i))) % maxPart;
            }

            uint256 expectedBurn = fillAssets + 1;
            uint256 ceilLimit = Math.mulDiv(maxShareBurn, fillAssets, assets, Math.Rounding.Ceil);
            assertEq(source.previewWithdraw(fillAssets), expectedBurn, "live source burn");
            assertEq(ceilLimit, expectedBurn, "modeled per-fill ceil limit");

            uint256 sharesBeforeFill = source.balanceOf(lender);
            vm.prank(filler);
            book.fillExitRequest(id, fillAssets, filler);
            assertEq(sharesBeforeFill - source.balanceOf(lender), expectedBurn, "actual per-fill burn");

            remaining -= fillAssets;
            assertEq(book.getExitRequest(id).assetsRemaining, remaining, "exact partition remainder");
        }

        uint256 sharesBurned = sharesBefore - source.balanceOf(lender);
        assertEq(remaining, 0, "partition covers the request");
        assertEq(sharesBurned, maxShareBurn + fillCount - 1, "exact cumulative ceiling bound");
        assertEq(asset.balanceOf(exitFeeRecipient), fillCount, "one rounded fee unit per fill");
        assertEq(_status(id), uint8(ExitStatus.Filled));
    }

    function test_maxShareBurn_fullFillAtExactLimitPasses() public {
        ExitFeeVault source = new ExitFeeVault(IERC20(address(asset)), exitFeeRecipient);
        book.setVaultAllowed(IERC4626(address(source)), true);
        uint256 assets = 10;
        uint256 shares = _deposit(IERC4626(address(source)), 11);
        _approve(IERC4626(address(source)), shares);
        uint256 maxShareBurn = source.previewWithdraw(assets);
        assertEq(maxShareBurn, 11, "full quote includes one exit-fee unit");

        vm.prank(lender);
        uint256 id = book.placeExitRequest(
            IERC4626(address(source)), assets, lender, assets, maxShareBurn, _zeroRamp(), block.timestamp + 30 days
        );

        uint256 liveBurn = source.previewWithdraw(assets);
        assertEq(liveBurn, maxShareBurn, "actual burn is exactly the enabled boundary");
        uint256 sharesBefore = source.balanceOf(lender);
        uint256 assetsBefore = asset.balanceOf(lender);

        vm.prank(filler);
        book.fillExitRequest(id, assets, filler);

        assertEq(sharesBefore - source.balanceOf(lender), maxShareBurn, "equality at the full-fill limit passes");
        assertEq(asset.balanceOf(lender) - assetsBefore, assets, "receiver gets the exact withdrawal");
        assertEq(source.allowance(lender, address(book)), 0, "exact approved backing is consumed");
        assertEq(asset.balanceOf(exitFeeRecipient), 1, "exit fee is paid");
        assertEq(book.getExitRequest(id).assetsRemaining, 0, "request is closed");
        assertEq(_status(id), uint8(ExitStatus.Filled));
    }

    function testRevert_maxShareBurn_partialBurnAboveCeilLimitRollsBack() public {
        ExitFeeVault source = new ExitFeeVault(IERC20(address(asset)), exitFeeRecipient);
        book.setVaultAllowed(IERC4626(address(source)), true);
        uint256 shares = _deposit(IERC4626(address(source)), 4);
        _approve(IERC4626(address(source)), shares);
        uint256 maxShareBurn = source.previewWithdraw(2);

        vm.prank(lender);
        uint256 id = book.placeExitRequest(
            IERC4626(address(source)), 2, lender, 0, maxShareBurn, _zeroRamp(), block.timestamp + 30 days
        );

        vm.prank(address(source));
        assertTrue(asset.transfer(address(0xBEEF), 1), "source loss applied");
        uint256 ceilLimit = Math.mulDiv(maxShareBurn, 1, 2, Math.Rounding.Ceil);
        uint256 liveBurn = source.previewWithdraw(1);
        assertEq(ceilLimit, 2, "partial ceil limit");
        assertEq(liveBurn, ceilLimit + 1, "live burn is one unit above the boundary");

        bytes32 requestBefore = keccak256(abi.encode(book.getExitRequest(id)));
        uint256 lenderSharesBefore = source.balanceOf(lender);
        uint256 allowanceBefore = source.allowance(lender, address(book));
        uint256 sourceAssetsBefore = asset.balanceOf(address(source));

        vm.prank(filler);
        vm.expectRevert(abi.encodeWithSelector(ExitBookBase.ShareBurnExceedsMaximum.selector, liveBurn, ceilLimit));
        book.fillExitRequest(id, 1, filler);

        assertEq(keccak256(abi.encode(book.getExitRequest(id))), requestBefore, "request rolls back");
        assertEq(source.balanceOf(lender), lenderSharesBefore, "share burn rolls back");
        assertEq(source.allowance(lender, address(book)), allowanceBefore, "allowance rolls back");
        assertEq(asset.balanceOf(address(source)), sourceAssetsBefore, "source withdrawal rolls back");
        assertEq(asset.balanceOf(address(book)), 0, "book holds no assets");
        assertEq(asset.balanceOf(exitFeeRecipient), 0, "exit fee rolls back");
    }

    function test_fill_partialSlicesWithdrawExactAssetsAndRetainYield() public {
        uint256 shares = _deposit(IERC4626(address(vault)), 3);
        _donate(3);
        _approve(IERC4626(address(vault)), shares);
        uint256 id = _place(IERC4626(address(vault)), 3, lender, 0, _zeroRamp());
        uint256 sharesBefore = vault.balanceOf(lender);
        uint256 firstBurn = vault.previewWithdraw(1);
        vm.prank(filler);
        book.fillExitRequest(id, 1, filler);
        assertEq(sharesBefore - vault.balanceOf(lender), firstBurn, "first slice burns its live exact-asset quote");

        uint256 secondBurn = vault.previewWithdraw(1);
        vm.prank(filler);
        book.fillExitRequest(id, 1, filler);

        assertEq(book.getExitRequest(id).assetsRemaining, 1);
        assertEq(sharesBefore - vault.balanceOf(lender), firstBurn + secondBurn);
        assertGt(vault.previewRedeem(vault.balanceOf(lender)), 1, "unwithdrawn yield remains in the owner position");
    }

    function test_fill_conservation_withLoss() public {
        (uint256 id,) = _depositAndPlace(200 ether, 100 ether, lender, 0, _zeroRamp());
        uint256 sharesAtPlacement = vault.previewWithdraw(100 ether);

        vm.prank(address(vault));
        assertTrue(asset.transfer(address(0xBEEF), 50 ether));
        uint256 liveShares = vault.previewWithdraw(100 ether);
        assertGt(liveShares, sharesAtPlacement);

        uint256 sharesBefore = vault.balanceOf(lender);
        uint256 assetsBefore = asset.balanceOf(lender);
        vm.prank(filler);
        book.fillExitRequest(id, 100 ether, filler);

        assertEq(sharesBefore - vault.balanceOf(lender), liveShares);
        assertEq(asset.balanceOf(lender) - assetsBefore, 100 ether);
        assertEq(_status(id), uint8(ExitStatus.Filled));
    }

    function testRevert_maxShareBurn_lossRollsBackWithdrawalAndRequest() public {
        uint256 shares = _deposit(IERC4626(address(vault)), 200 ether);
        _approve(IERC4626(address(vault)), shares);
        uint128 maxShareBurn = uint128(vault.previewWithdraw(100 ether));
        vm.prank(lender);
        uint256 id = book.placeExitRequest(
            IERC4626(address(vault)), 100 ether, lender, 0, maxShareBurn, _zeroRamp(), block.timestamp + 30 days
        );

        vm.prank(address(vault));
        assertTrue(asset.transfer(address(0xBEEF), 50 ether));
        uint256 liveShares = vault.previewWithdraw(100 ether);
        assertGt(liveShares, maxShareBurn);

        uint256 allowanceBefore = vault.allowance(lender, address(book));
        uint256 sourceAssetsBefore = asset.balanceOf(address(vault));
        uint256 lenderAssetsBefore = asset.balanceOf(lender);
        vm.prank(filler);
        vm.expectRevert(
            abi.encodeWithSelector(ExitBookBase.ShareBurnExceedsMaximum.selector, liveShares, uint256(maxShareBurn))
        );
        book.fillExitRequest(id, 100 ether, filler);

        assertEq(book.getExitRequest(id).assetsRemaining, 100 ether, "request debit rolled back");
        assertEq(vault.balanceOf(lender), shares, "share burn rolled back");
        assertEq(vault.allowance(lender, address(book)), allowanceBefore, "allowance spend rolled back");
        assertEq(asset.balanceOf(address(vault)), sourceAssetsBefore, "source withdrawal rolled back");
        assertEq(asset.balanceOf(lender), lenderAssetsBefore, "receiver payout rolled back");
        assertEq(asset.balanceOf(address(book)), 0, "book balance rolled back");
    }

    function test_fill_afterYieldBurnsLiveSharesAndStillPaysExactAssets() public {
        (uint256 id,) = _depositAndPlace(200 ether, 100 ether, lender, 0, _zeroRamp());
        uint256 sharesAtPlacement = vault.previewWithdraw(100 ether);
        _donate(100 ether);
        uint256 liveShares = vault.previewWithdraw(100 ether);
        assertLt(liveShares, sharesAtPlacement);

        uint256 sharesBefore = vault.balanceOf(lender);
        uint256 assetsBefore = asset.balanceOf(lender);
        vm.prank(filler);
        book.fillExitRequest(id, 100 ether, filler);

        assertEq(sharesBefore - vault.balanceOf(lender), liveShares);
        assertEq(asset.balanceOf(lender) - assetsBefore, 100 ether);
        assertEq(_status(id), uint8(ExitStatus.Filled));
    }

    function test_fill_ownerBackingCapsOnlyTheAmountChosenOffchain() public {
        (uint256 id, uint256 shares) = _lenderPlace(100 ether, _zeroRamp());
        vm.prank(address(vault));
        assertTrue(asset.transfer(address(0xBEEF), 10 ether));

        uint256 backedAssets = vault.maxWithdraw(lender);
        vm.prank(filler);
        vm.expectRevert(
            abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxWithdraw.selector, lender, 100 ether, backedAssets)
        );
        book.fillExitRequest(id, 100 ether, filler);
        assertEq(book.getExitRequest(id).assetsRemaining, 100 ether);

        uint256 sharesToBurn = vault.previewWithdraw(backedAssets);
        vm.prank(filler);
        book.fillExitRequest(id, backedAssets, filler);

        Request memory request = book.getExitRequest(id);
        assertEq(request.assetsRemaining, 100 ether - backedAssets);
        assertEq(uint8(request.status), uint8(ExitStatus.Open));
        assertEq(vault.balanceOf(lender), shares - sharesToBurn);

        uint256 tail = request.assetsRemaining;
        asset.mint(lender, tail * 2);
        vm.startPrank(lender);
        asset.approve(address(vault), tail * 2);
        vault.deposit(tail * 2, lender);
        vault.approve(address(book), type(uint256).max);
        vm.stopPrank();

        vm.prank(filler);
        book.fillExitRequest(id, tail, filler);
        assertEq(_status(id), uint8(ExitStatus.Filled));
    }

    function test_fill_liveAllowanceDoesNotChooseAmountForTheFiller() public {
        (uint256 id,) = _lenderPlace(100 ether, _zeroRamp());
        _approve(IERC4626(address(vault)), 40 ether);

        vm.prank(filler);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(book), 40 ether, 41 ether)
        );
        book.fillExitRequest(id, 41 ether, filler);
        assertEq(book.getExitRequest(id).assetsRemaining, 100 ether);

        vm.prank(filler);
        book.fillExitRequest(id, 40 ether, filler);
        assertEq(book.getExitRequest(id).assetsRemaining, 60 ether);

        _approve(IERC4626(address(vault)), type(uint256).max);
        vm.prank(filler);
        book.fillExitRequest(id, 60 ether, filler);
        assertEq(_status(id), uint8(ExitStatus.Filled));
    }

    function testRevert_fill_frontRunReducedRemainderRejectsWithoutTouchingExecutor() public {
        (uint256 id,) = _lenderPlace(100 ether, _zeroRamp());
        vm.prank(address(0xB));
        book.fillExitRequest(id, 70 ether, address(0xB));

        asset.mint(filler, 90 ether);
        uint256 fillerAssetsBefore = asset.balanceOf(filler);
        uint256 sourceAssetsBefore = asset.balanceOf(address(vault));
        vm.prank(filler);
        vm.expectRevert(abi.encodeWithSelector(ExitBookBase.FillExceedsRemaining.selector, 100 ether, 30 ether));
        book.fillExitRequest(id, 100 ether, filler);

        assertEq(asset.balanceOf(filler), fillerAssetsBefore);
        assertEq(asset.balanceOf(address(vault)), sourceAssetsBefore);
        assertEq(vault.balanceOf(filler), 0);
        assertEq(book.getExitRequest(id).assetsRemaining, 30 ether);
    }

    function testRevert_fill_zeroExactAmount() public {
        (uint256 id,) = _lenderPlace(100 ether, _zeroRamp());

        vm.prank(filler);
        vm.expectRevert(ExitBookBase.ZeroAssets.selector);
        book.fillExitRequest(id, 0, filler);
    }

    function testRevert_fill_zeroRewardRecipient() public {
        (uint256 id,) = _lenderPlace(100 ether, _zeroRamp());

        vm.prank(filler);
        vm.expectRevert(ExitBookBase.ZeroAddress.selector);
        book.fillExitRequest(id, 100 ether, address(0));

        assertEq(book.getExitRequest(id).assetsRemaining, 100 ether);
        assertEq(vault.balanceOf(lender), 100 ether);
    }

    // ── externally prepared liquidity ──

    function test_fill_doesNotUseExecutorAssetsWhenSourceIsLiquid() public {
        (uint256 id,) = _lenderPlace(100 ether, _zeroRamp());
        asset.mint(filler, 50 ether);

        uint256 fillerAssetsBefore = asset.balanceOf(filler);
        uint256 expectedSharesBurned = vault.previewWithdraw(100 ether);
        vm.expectEmit(true, true, true, true, address(book));
        emit ExitBookBase.ExitProcessed(1, filler, filler, address(asset), 100 ether, expectedSharesBurned, 0, 0);
        vm.prank(filler);
        book.fillExitRequest(id, 100 ether, filler);

        assertEq(asset.balanceOf(filler), fillerAssetsBefore);
        assertEq(vault.balanceOf(filler), 0);
    }

    function test_externalDepositPreparesLiquidityThenFill() public {
        LiquidityCappedVault source = new LiquidityCappedVault(IERC20(address(asset)));
        (uint256 id,) = _depositAndPlace(IERC4626(address(source)), 100 ether, 100 ether, lender, 0, _zeroRamp());
        source.setAvailableLiquidity(40 ether);
        asset.mint(filler, 60 ether);

        vm.startPrank(filler);
        asset.approve(address(source), 60 ether);
        source.deposit(60 ether, filler);
        book.fillExitRequest(id, 100 ether, filler);
        vm.stopPrank();

        assertEq(asset.balanceOf(filler), 0);
        assertEq(source.balanceOf(filler), 60 ether);
        assertEq(_status(id), uint8(ExitStatus.Filled));
    }

    function testRevert_fill_insufficientSourceLiquidityDoesNotUseExecutorAssets() public {
        LiquidityCappedVault source = new LiquidityCappedVault(IERC20(address(asset)));
        (uint256 id,) = _depositAndPlace(IERC4626(address(source)), 100 ether, 100 ether, lender, 0, _zeroRamp());
        source.setAvailableLiquidity(39 ether);
        asset.mint(filler, 60 ether);
        uint256 sourceAssetsBefore = asset.balanceOf(address(source));

        vm.prank(filler);
        vm.expectRevert(
            abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxWithdraw.selector, lender, 100 ether, 39 ether)
        );
        book.fillExitRequest(id, 100 ether, filler);

        assertEq(asset.balanceOf(filler), 60 ether);
        assertEq(asset.balanceOf(address(source)), sourceAssetsBefore);
        assertEq(source.balanceOf(filler), 0);
        assertEq(book.getExitRequest(id).assetsRemaining, 100 ether);
    }

    function test_exitFeeVault_usesPreviewWithdrawForBackingAndPaysExactAssets() public {
        ExitFeeVault source = new ExitFeeVault(IERC20(address(asset)), exitFeeRecipient);
        book.setVaultAllowed(IERC4626(address(source)), true);
        uint256 shares = _deposit(IERC4626(address(source)), 110 ether);
        assertEq(source.convertToShares(100 ether), 100 ether);
        assertEq(source.previewWithdraw(100 ether), 110 ether);

        _approve(IERC4626(address(source)), 100 ether);
        vm.expectRevert(Erc4626ExitBook.InsufficientBacking.selector);
        _place(IERC4626(address(source)), 100 ether, lender, 0, _zeroRamp());

        _approve(IERC4626(address(source)), shares);
        uint256 id = _place(IERC4626(address(source)), 100 ether, lender, 0, _zeroRamp());
        uint256 lenderBefore = asset.balanceOf(lender);
        vm.prank(filler);
        book.fillExitRequest(id, 100 ether, filler);

        assertEq(asset.balanceOf(lender) - lenderBefore, 100 ether);
        assertEq(asset.balanceOf(exitFeeRecipient), 10 ether);
        assertEq(source.balanceOf(lender), 0);
    }

    function test_exitFeeVault_fillerChoosesAmountThatFitsLiveAllowance() public {
        ExitFeeVault source = new ExitFeeVault(IERC20(address(asset)), exitFeeRecipient);
        (uint256 id, uint256 shares) =
            _depositAndPlace(IERC4626(address(source)), 110 ether, 100 ether, lender, 0, _zeroRamp());
        uint256 liveAllowance = 55 ether;
        uint256 fillAssets = 50 ether;
        _approve(IERC4626(address(source)), liveAllowance);
        assertEq(source.previewWithdraw(fillAssets), liveAllowance, "the exact fill fits the live allowance");

        uint256 lenderBefore = asset.balanceOf(lender);
        vm.prank(filler);
        book.fillExitRequest(id, fillAssets, filler);

        assertEq(asset.balanceOf(lender) - lenderBefore, fillAssets);
        assertEq(book.getExitRequest(id).assetsRemaining, 50 ether);
        assertEq(source.balanceOf(lender), shares - liveAllowance);
        assertEq(_status(id), uint8(ExitStatus.Open));
    }

    function test_fill_ignoresPreExistingBookDonationWhenMeasuringExactOutput() public {
        (uint256 id,) = _lenderPlace(100 ether, _zeroRamp());
        uint256 donation = 7 ether;
        asset.mint(address(book), donation);

        uint256 lenderBefore = asset.balanceOf(lender);
        vm.prank(filler);
        book.fillExitRequest(id, 100 ether, filler);

        assertEq(asset.balanceOf(lender) - lenderBefore, 100 ether);
        assertEq(asset.balanceOf(address(book)), donation, "pre-existing assets are neither output nor payout");
    }

    function testRevert_fill_excessAssetsOutRollsBackWithdrawalAndDebit() public {
        ExcessWithdrawVault source = new ExcessWithdrawVault(IERC20(address(asset)));
        (uint256 id, uint256 lenderShares) =
            _depositAndPlace(IERC4626(address(source)), 101 ether, 100 ether, lender, 0, _zeroRamp());

        vm.prank(filler);
        vm.expectRevert(abi.encodeWithSelector(ExitBookBase.AssetsOutMismatch.selector, 100 ether, 100 ether + 1));
        book.fillExitRequest(id, 100 ether, filler);

        assertEq(book.getExitRequest(id).assetsRemaining, 100 ether);
        assertEq(source.balanceOf(lender), lenderShares);
        assertEq(asset.balanceOf(address(source)), 101 ether);
    }

    function testRevert_fill_serviceCutTransferFailureRollsBackEntireFill() public {
        LiquidityCappedVault source = new LiquidityCappedVault(IERC20(address(asset)));
        PriorityRamp memory ramp = _ramp();
        (uint256 id, uint256 lenderShares) =
            _depositAndPlace(IERC4626(address(source)), 100 ether, 100 ether, receiver, 0, ramp);
        _setServiceFee(book.MAX_SERVICE_FEE());
        vm.warp(block.timestamp + ramp.rampEnd);

        Request memory requestBefore = book.getExitRequest(id);
        uint256 lenderAllowanceBefore = source.allowance(lender, address(book));
        uint256 sourceAssetsBefore = asset.balanceOf(address(source));
        uint256 sourceLiquidityBefore = source.availableLiquidity();
        uint256 receiverAssetsBefore = asset.balanceOf(receiver);
        uint256 fillerAssetsBefore = asset.balanceOf(filler);
        uint256 serviceAssetsBefore = asset.balanceOf(feeRecipient);
        uint256 bookAssetsBefore = asset.balanceOf(address(book));

        asset.setBlockedRecipient(feeRecipient);
        vm.prank(filler);
        vm.expectRevert(abi.encodeWithSelector(MockAsset.TransferBlocked.selector, feeRecipient));
        book.fillExitRequest(id, 100 ether, filler);

        assertEq(keccak256(abi.encode(book.getExitRequest(id))), keccak256(abi.encode(requestBefore)));
        assertEq(source.balanceOf(lender), lenderShares);
        assertEq(source.allowance(lender, address(book)), lenderAllowanceBefore);
        assertEq(source.balanceOf(filler), 0);
        assertEq(asset.balanceOf(address(source)), sourceAssetsBefore);
        assertEq(source.availableLiquidity(), sourceLiquidityBefore);
        assertEq(asset.balanceOf(receiver), receiverAssetsBefore);
        assertEq(asset.balanceOf(filler), fillerAssetsBefore);
        assertEq(asset.balanceOf(feeRecipient), serviceAssetsBefore);
        assertEq(asset.balanceOf(address(book)), bookAssetsBefore);
    }

    function test_priorityRamp_holdLinearPlateau() public {
        PriorityRamp memory ramp = _ramp();
        _assertRampFee(ramp, 30 minutes, ramp.startRate);
        _assertRampFee(ramp, 12 hours, _priorityRate(ramp, 12 hours));
        _assertRampFee(ramp, 2 days, ramp.endRate);

        PriorityRamp memory jump =
            PriorityRamp({startRate: 0.01e18, endRate: 0.05e18, rampStart: 1 hours, rampEnd: 1 hours});
        _assertRampFee(jump, 1 hours - 1, jump.startRate);
        _assertRampFee(jump, 1 hours, jump.endRate);
    }

    function _assertRampFee(PriorityRamp memory ramp, uint256 elapsed, uint256 expectedRate) internal {
        (uint256 id,) = _depositAndPlace(100 ether, 100 ether, lender, 0, ramp);
        uint256 lenderBefore = asset.balanceOf(lender);
        uint256 fillerBefore = asset.balanceOf(filler);

        vm.warp(block.timestamp + elapsed);
        vm.prank(filler);
        book.fillExitRequest(id, 100 ether, filler);

        uint256 expectedFee = Math.mulDiv(100 ether, expectedRate, WAD);
        assertEq(asset.balanceOf(lender) - lenderBefore, 100 ether - expectedFee);
        assertEq(asset.balanceOf(filler) - fillerBefore, expectedFee);
    }

    function test_externalDeposit_executorGetsVaultSharesAndRecipientGetsReward() public {
        LiquidityCappedVault source = new LiquidityCappedVault(IERC20(address(asset)));
        PriorityRamp memory ramp = _ramp();
        (uint256 id,) = _depositAndPlace(IERC4626(address(source)), 100 ether, 100 ether, lender, 0, ramp);
        source.setAvailableLiquidity(40 ether);
        asset.mint(filler, 80 ether);
        uint256 expectedShares = source.previewDeposit(60 ether);
        vm.warp(block.timestamp + ramp.rampEnd);

        vm.startPrank(filler);
        asset.approve(address(source), 60 ether);
        source.deposit(60 ether, filler);

        uint256 expectedSharesBurned = source.previewWithdraw(100 ether);
        vm.expectEmit(true, true, true, true, address(book));
        emit ExitBookBase.ExitProcessed(
            id, filler, rewardRecipient, address(asset), 100 ether, expectedSharesBurned, 8 ether, 0
        );
        book.fillExitRequest(id, 100 ether, rewardRecipient);
        vm.stopPrank();

        assertEq(asset.balanceOf(filler), 20 ether, "executor chooses how much liquidity to provide");
        assertEq(asset.balanceOf(rewardRecipient), 8 ether, "liquid reward routed independently");
        assertEq(source.balanceOf(filler), expectedShares);
        assertEq(source.balanceOf(rewardRecipient), 0, "source position stays with the liquidity provider");
        assertEq(source.availableLiquidity(), 0);
        assertEq(_status(id), uint8(ExitStatus.Filled));
    }

    // ── minimum fill and exact output ──

    function test_minFill_usesDirectAssetBoundaryAndAllowsOnlyTheWholeFinalTail() public {
        (uint256 id,) = _depositAndPlace(100 ether, 100 ether, lender, 60 ether, _zeroRamp());
        assertEq(book.getExitRequest(id).minFillAssets, 60 ether);

        vm.prank(filler);
        vm.expectRevert(abi.encodeWithSelector(ExitBookBase.FillBelowMinimum.selector, 60 ether - 1, 60 ether));
        book.fillExitRequest(id, 60 ether - 1, filler);

        vm.prank(filler);
        book.fillExitRequest(id, 60 ether, filler);
        assertEq(book.getExitRequest(id).assetsRemaining, 40 ether);

        vm.prank(filler);
        vm.expectRevert(abi.encodeWithSelector(ExitBookBase.FillBelowMinimum.selector, 40 ether - 1, 60 ether));
        book.fillExitRequest(id, 40 ether - 1, filler);

        vm.prank(filler);
        book.fillExitRequest(id, 40 ether, filler);
        assertEq(_status(id), uint8(ExitStatus.Filled));
    }

    function test_place_capsMinimumAtAssetTarget() public {
        (uint256 id,) = _depositAndPlace(100 ether, 100 ether, lender, 200 ether, _zeroRamp());
        assertEq(book.getExitRequest(id).minFillAssets, 100 ether);
    }

    /// @dev Placing a ramp whose startRate exceeds its endRate reverts StartFeeAboveEnd.
    function testRevert_place_startFeeAboveEnd() public {
        _depositAndApprove(100 ether, type(uint256).max);
        vm.expectRevert(ExitBookBase.StartFeeAboveEnd.selector);
        _place(
            1 ether,
            PriorityRamp({startRate: 0.02e18, endRate: 0.01e18, rampStart: 0, rampEnd: 1 days}),
            block.timestamp + 30 days
        );
    }

    /// @dev Placing with an endRate above MAX_PRIORITY_FEE reverts PriorityFeeTooHigh.
    function testRevert_place_endFeeTooHigh() public {
        _depositAndApprove(100 ether, type(uint256).max);
        vm.expectRevert(ExitBookBase.PriorityFeeTooHigh.selector);
        _place(
            1 ether,
            PriorityRamp({startRate: 0, endRate: 0.11e18, rampStart: 0, rampEnd: 1 days}),
            block.timestamp + 30 days
        );
    }

    /// @dev Placing where `now + rampEnd` overruns the deadline reverts RampPastDeadline.
    function testRevert_place_rampPastDeadline() public {
        _depositAndApprove(100 ether, type(uint256).max);
        vm.expectRevert(ExitBookBase.RampPastDeadline.selector);
        _place(
            1 ether,
            PriorityRamp({startRate: 0, endRate: 0.01e18, rampStart: 0, rampEnd: 2 days}),
            block.timestamp + 1 days
        );
    }

    function testRevert_place_zeroAssets() public {
        _depositAndApprove(100 ether, type(uint256).max);

        vm.expectRevert(ExitBookBase.ZeroAssets.selector);
        _place(0, _zeroRamp(), block.timestamp + 30 days);
    }

    function testRevert_place_zeroReceiver() public {
        _depositAndApprove(100 ether, type(uint256).max);
        vm.expectRevert(ExitBookBase.ZeroAddress.selector);
        _place(IERC4626(address(vault)), 1 ether, address(0), 0, _zeroRamp());
    }

    function testRevert_place_insufficientBacking() public {
        _deposit(IERC4626(address(vault)), 100 ether);

        _approve(IERC4626(address(vault)), 100 ether - 1);
        vm.expectRevert(Erc4626ExitBook.InsufficientBacking.selector);
        _place(IERC4626(address(vault)), 100 ether, lender, 0, _zeroRamp());

        _approve(IERC4626(address(vault)), type(uint256).max);
        vm.expectRevert(Erc4626ExitBook.InsufficientBacking.selector);
        _place(IERC4626(address(vault)), 100 ether + 1, lender, 0, _zeroRamp());
    }

    function testRevert_setVaultAllowed_zeroVault() public {
        vm.expectRevert(Erc4626ExitBook.ZeroVault.selector);
        book.setVaultAllowed(IERC4626(address(0)), true);
    }

    /// @dev Disallowing a vault blocks NEW placements but a request already in flight stays fillable.
    function test_disallowVault_blocksPlaceNotFill() public {
        (uint256 id,) = _lenderPlace(100 ether, _zeroRamp());
        book.setVaultAllowed(IERC4626(address(vault)), false);

        vm.prank(lender);
        vm.expectRevert(Erc4626ExitBook.VaultNotAllowed.selector);
        book.placeExitRequest(IERC4626(address(vault)), 1 ether, lender, 0, 0, _zeroRamp(), block.timestamp + 30 days);

        vm.prank(filler);
        book.fillExitRequest(id, 100 ether, filler);
        assertEq(_status(id), uint8(ExitStatus.Filled));
    }

    function test_setVaultAllowedEmitsAndStores() public {
        MockVault source = new MockVault(IERC20(address(asset)));

        vm.expectEmit(true, false, false, true, address(book));
        emit Erc4626ExitBook.VaultAllowedSet(address(source), true);
        book.setVaultAllowed(IERC4626(address(source)), true);

        assertTrue(book.isVaultAllowed(IERC4626(address(source))));
    }

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

    function testRevert_pause_unauthorized() public {
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, lender, book.PAUSER_ROLE())
        );
        vm.prank(lender);
        book.pause();
    }

    function testRevert_resume_unauthorized() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, lender, book.RESUMER_ROLE()
            )
        );
        vm.prank(lender);
        book.resume();
    }

    // ── lifecycle, pause, config, and views ──

    function test_pauseAndResumeAreIdempotentAndGatePlacementAndFill() public {
        (uint256 id,) = _lenderPlace(100 ether, _zeroRamp());

        vm.expectEmit(false, false, false, true, address(book));
        emit ExitBookBase.Paused(address(this));
        book.pause();
        vm.expectEmit(false, false, false, true, address(book));
        emit ExitBookBase.Paused(address(this));
        book.pause();
        assertTrue(book.paused());

        book.setServiceFee(feeRecipient, 0.1e18);
        assertEq(book.getExitRequest(id).assetsRemaining, 100 ether);

        vm.expectRevert(ExitBookBase.EnforcedPause.selector);
        _place(IERC4626(address(vault)), 1 ether, lender, 0, _zeroRamp());
        vm.prank(filler);
        vm.expectRevert(ExitBookBase.EnforcedPause.selector);
        book.fillExitRequest(id, 100 ether, filler);

        vm.expectEmit(false, false, false, true, address(book));
        emit ExitBookBase.Unpaused(address(this));
        book.resume();
        vm.expectEmit(false, false, false, true, address(book));
        emit ExitBookBase.Unpaused(address(this));
        book.resume();
        assertFalse(book.paused());
        vm.prank(filler);
        book.fillExitRequest(id, 100 ether, filler);
        assertEq(_status(id), uint8(ExitStatus.Filled));
    }

    function test_fill_noAssetsWithdrawn_reverts() public {
        ZeroWithdrawVault source = new ZeroWithdrawVault(IERC20(address(asset)));
        (uint256 id, uint256 lenderShares) =
            _depositAndPlace(IERC4626(address(source)), 100 ether, 100 ether, lender, 0, _zeroRamp());
        uint256 sourceAssetsBefore = asset.balanceOf(address(source));

        vm.prank(filler);
        vm.expectRevert(abi.encodeWithSelector(ExitBookBase.AssetsOutMismatch.selector, 100 ether, 0));
        book.fillExitRequest(id, 100 ether, filler);

        assertEq(book.getExitRequest(id).assetsRemaining, 100 ether);
        assertEq(source.balanceOf(lender), lenderShares);
        assertEq(source.balanceOf(filler), 0);
        assertEq(asset.balanceOf(filler), 0);
        assertEq(asset.balanceOf(address(source)), sourceAssetsBefore);
    }

    /// @dev The owner may cancel while paused; cancellation emits ExitCancelled, marks the request Cancelled,
    ///      zeroes its remaining assets, and prevents future fills.
    function test_cancelExitRequest_marksCancelledAndEmits() public {
        (uint256 id,) = _lenderPlace(100 ether, _zeroRamp());
        book.pause();

        vm.expectEmit(true, false, false, false, address(book));
        emit ExitBookBase.ExitCancelled(id);
        vm.prank(lender);
        book.cancelExitRequest(id);

        Request memory request = book.getExitRequest(id);
        assertEq(uint8(request.status), uint8(ExitStatus.Cancelled));
        assertEq(request.assetsRemaining, 0);

        book.resume();
        vm.prank(filler);
        vm.expectRevert(ExitBookLib.RequestClosed.selector);
        book.fillExitRequest(id, 100 ether, filler);
    }

    /// @dev A non-owner cancelling another account's request reverts NotOwner.
    function testRevert_cancelExitRequest_notOwner() public {
        (uint256 id,) = _lenderPlace(100 ether, _zeroRamp());

        vm.prank(filler);
        vm.expectRevert(ExitBookLib.NotOwner.selector);
        book.cancelExitRequest(id);
    }

    function test_cancelAfterExpiryClosesTheRequest() public {
        (uint256 id,) = _lenderPlace(100 ether, _zeroRamp());
        vm.warp(block.timestamp + 30 days + 1);

        vm.prank(lender);
        book.cancelExitRequest(id);

        Request memory request = book.getExitRequest(id);
        assertEq(uint8(request.status), uint8(ExitStatus.Cancelled));
        assertEq(request.assetsRemaining, 0);
    }

    /// @dev Placing a ramp whose rampStart is after its rampEnd reverts RampStartAfterEnd.
    function testRevert_place_rampStartAfterEnd() public {
        _depositAndApprove(100 ether, type(uint256).max);
        vm.expectRevert(ExitBookBase.RampStartAfterEnd.selector);
        _place(
            1 ether,
            PriorityRamp({startRate: 0, endRate: 0.01e18, rampStart: 2 days, rampEnd: 1 days}),
            block.timestamp + 30 days
        );
    }

    /// @dev Placing with a deadline at or before the current time reverts DeadlineInPast.
    function testRevert_place_deadlineInPast() public {
        _depositAndApprove(100 ether, type(uint256).max);
        vm.expectRevert(ExitBookBase.DeadlineInPast.selector);
        _place(1 ether, _zeroRamp(), block.timestamp);
    }

    /// @dev Placing with a deadline beyond `now + MAX_REQUEST_LIFETIME` reverts DeadlineTooFar.
    function testRevert_place_deadlineTooFar() public {
        _depositAndApprove(100 ether, type(uint256).max);
        uint256 maxLifetime = book.MAX_REQUEST_LIFETIME();
        vm.expectRevert(ExitBookBase.DeadlineTooFar.selector);
        _place(1 ether, _zeroRamp(), block.timestamp + maxLifetime + 1);
    }

    function test_viewsReturnStoredRequestsAndOwnerIndexesWithoutSourcePreviews() public {
        (uint256 id1,) = _depositAndPlace(150 ether, 100 ether, lender, 0, _zeroRamp());
        uint256 id2 = _place(IERC4626(address(vault)), 50 ether, receiver, 0, _zeroRamp());

        uint256[] memory ids = new uint256[](3);
        ids[0] = id1;
        ids[1] = id2;
        ids[2] = 999;

        Request[] memory requests = book.getRequests(ids);
        assertEq(requests[0].assetsRemaining, 100 ether);
        assertEq(requests[1].receiver, receiver);
        assertEq(requests[2].owner, address(0));
        assertEq(uint8(requests[2].status), uint8(ExitStatus.NotCreated));
        assertEq(book.getOwnerRequestCount(lender), 2);
        assertEq(book.getOwnerRequestIds(lender, 0, 10).length, 2);
        assertEq(book.getOwnerRequestIds(lender, 1, 10)[0], id2);
        assertEq(book.getOwnerRequestIds(lender, 2, 10).length, 0);
    }

    /// @dev lastRequestId starts at zero and advances to the id of each newly placed request.
    function test_lastRequestId_tracksLatest() public {
        assertEq(book.lastRequestId(), 0, "no requests issued yet");
        (uint256 id1,) = _lenderPlace(100 ether, _ramp());
        assertEq(book.lastRequestId(), id1, "tracks the first id");
        (uint256 id2,) = _lenderPlace(50 ether, _ramp());
        assertEq(book.lastRequestId(), id2, "tracks the latest id");
    }
}
