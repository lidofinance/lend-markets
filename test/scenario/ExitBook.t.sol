// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {Id, MarketParams} from "@lido-lend/src/interfaces/IMorpho.sol";

import {ExitBookBase} from "../../src/periphery/ExitBookBase.sol";
import {Erc4626ExitBook} from "../../src/periphery/Erc4626ExitBook.sol";
import {MorphoExitBook} from "../../src/periphery/MorphoExitBook.sol";
import {ExitBookLib} from "../../src/libs/ExitBookLib.sol";
import {WAD} from "../../src/libs/Constants.sol";
import {Request, ExitStatus, PriorityRamp, RequestPreview} from "../../src/types/ExitBookTypes.sol";
import {LidoLendDeployer} from "../../script/lib/LidoLendDeployer.sol";

/// @dev Plain ERC-20 with an open mint, so the suite runs on a bare local chain (no mainnet fork).
contract MockERC20 is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Constant-price oracle swapped in for `WstEthRateOracle` (Morpho 1e36 convention; 1e36 == parity).
contract FixedPriceOracle {
    uint256 public immutable PRICE;

    constructor(uint256 price_) {
        PRICE = price_;
    }

    function price() external view returns (uint256) {
        return PRICE;
    }
}

interface IVaultLike {
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function convertToAssets(uint256 shares) external view returns (uint256);
}

interface ICoreLike {
    function supply(MarketParams memory p, uint256 assets, uint256 shares, address onBehalf, bytes memory data)
        external
        returns (uint256, uint256);
    function borrow(MarketParams memory p, uint256 assets, uint256 shares, address onBehalf, address receiver)
        external
        returns (uint256, uint256);
    function repay(MarketParams memory p, uint256 assets, uint256 shares, address onBehalf, bytes memory data)
        external
        returns (uint256, uint256);
    function supplyCollateral(MarketParams memory p, uint256 assets, address onBehalf, bytes memory data) external;
    function setAuthorization(address authorized, bool newIsAuthorized) external;
    function position(Id id, address user)
        external
        view
        returns (uint256 supplyShares, uint128 borrowShares, uint128 collateral);
}

/// @notice Basic happy-path coverage for the generic exit-book family on a freshly deployed stack over mock
///         ERC-20s (no fork): the ERC-4626 book and the Morpho book, the push payouts (no claim step), the
///         fee/service split, partial fills, cancel, the filler liquidity fill, and allow-list gating.
contract ExitBookTest is Test, LidoLendDeployer {
    address internal constant LENDER = address(0x1000);
    address internal constant FILLER = address(0x2000);
    address internal constant BORROWER = address(0x3000);
    address internal constant FEE_RECIPIENT = address(0x4000);

    uint256 internal constant LLTV = 0.8e18;
    uint256 internal constant ORACLE_PRICE = 1e36; // collateral:loan parity
    uint256 internal constant SERVICE_FEE = 0.01e18; // 1% cut of filler gross (WAD)
    uint256 internal constant PRIORITY_FEE = 0.05e18; // 5% priority-fee rate (WAD)
    uint256 internal constant MAX_LIFETIME = 30 days;

    MockERC20 internal loan;
    MockERC20 internal collateral;
    Erc4626ExitBook internal vaultBook;
    MorphoExitBook internal morphoBook;
    Deployed internal d;

    /// @dev Swap the default wstETH oracle for a constant-price one so no Lido contract is needed. Every other
    ///      contract (core, IRM, controller, vault) deploys through the base `LidoLendDeployer` via `vm.getCode`
    ///      — the fork core and IRM are 0.8.35-compatible, so no cross-version artifact reads are needed.
    function _deployOracle(address, address) internal override returns (address) {
        return address(new FixedPriceOracle(ORACLE_PRICE));
    }

    function setUp() public {
        loan = new MockERC20("Loan", "LOAN");
        collateral = new MockERC20("Collateral", "COLL");

        address[] memory guardians = new address[](1);
        guardians[0] = address(this);

        d = _deployForkStack(
            DeployConfig({
                admin: address(this),
                loanToken: address(loan),
                collateralToken: address(collateral),
                oracleSource: address(collateral), // ignored — _deployOracle is overridden
                lltv: LLTV,
                enableSettlement: true,
                activation: CollateralActivationConfigParams({
                    minActivationDelay: 10 minutes,
                    maxActivationDelay: 2 hours,
                    delayPerStrike: 2 hours,
                    activatingLockAmount: 0,
                    activatingLockDuration: 0,
                    maxDelayInflow: 10_000 ether,
                    minActivationAmount: 10 ether,
                    maxGuardiansQuorumDelay: 0
                }),
                settlementConfig: SettlementConfigParams({
                    sliceFloorBps: 100, sliceFloorAssets: 0, fullCutBelowCollateral: 10 ether, ltvStepBps: 100
                }),
                guardians: guardians,
                quorum: 1,
                vaultName: "Lido Loan Vault",
                vaultSymbol: "lidoLOAN"
            })
        );

        vaultBook = new Erc4626ExitBook(address(this), MAX_LIFETIME);
        vaultBook.setVaultAllowed(IERC4626(d.vault), true);
        vaultBook.setServiceFee(FEE_RECIPIENT, SERVICE_FEE);

        morphoBook = new MorphoExitBook(d.core, address(this), MAX_LIFETIME);
        morphoBook.setMarketAllowed(d.params, true);
        morphoBook.setServiceFee(FEE_RECIPIENT, SERVICE_FEE);
    }

    // ---
    // ERC-4626 BOOK
    // ---

    /* Full single fill at a flat priority fee: flat price → no yield → reward is purely the fee. */
    function test_erc4626_fill_pushesPayouts() public {
        uint256 shares = _depositToVault(LENDER, 10 ether);
        uint256 deadline = block.timestamp + 7 days;

        vm.prank(LENDER);
        IVaultLike(d.vault).approve(address(vaultBook), type(uint256).max);
        vm.prank(LENDER);
        uint256 id = vaultBook.placeExitRequest(IERC4626(d.vault), shares, _flat(PRIORITY_FEE), deadline, false);

        Request memory request = vaultBook.getExitRequest(id);
        assertEq(request.owner, LENDER, "owner stored");
        assertEq(request.sizeRemaining, shares, "size is the requested shares");
        assertEq(uint8(request.status), uint8(ExitStatus.Open), "open");

        // Independently recompute the split: flat fee, flat price → owed = snapshot.
        uint256 owed = shares * request.pricePerShare / WAD;
        uint256 fee = owed * PRIORITY_FEE / WAD;
        uint256 serviceCut = fee * SERVICE_FEE / WAD;
        uint256 expectedLender = owed - fee;
        uint256 expectedFiller = fee - serviceCut;

        uint256 lenderBefore = loan.balanceOf(LENDER);
        uint256 fillerBefore = loan.balanceOf(FILLER);
        uint256 recipientBefore = loan.balanceOf(FEE_RECIPIENT);

        vm.warp(deadline);
        vm.prank(FILLER);
        vaultBook.fillExitRequest(id, 0, 0);

        assertApproxEqAbs(loan.balanceOf(LENDER) - lenderBefore, expectedLender, 1e6, "lender: owed minus fee");
        assertApproxEqAbs(loan.balanceOf(FILLER) - fillerBefore, expectedFiller, 1e6, "filler: fee minus cut");
        assertApproxEqAbs(loan.balanceOf(FEE_RECIPIENT) - recipientBefore, serviceCut, 1e6, "service: cut of gross");
        assertEq(loan.balanceOf(address(vaultBook)), 0, "book never holds a balance");

        request = vaultBook.getExitRequest(id);
        assertEq(uint8(request.status), uint8(ExitStatus.Filled), "filled");
        assertEq(request.sizeRemaining, 0, "fully drained");
    }

    /* Partial fill bounded by idle liquidity, then a final fill once the borrower repays. */
    function test_erc4626_partialThenFinal() public {
        uint256 shares = _depositToVault(LENDER, 10 ether);

        vm.prank(LENDER);
        IVaultLike(d.vault).approve(address(vaultBook), type(uint256).max);
        vm.prank(LENDER);
        uint256 id = vaultBook.placeExitRequest(
            IERC4626(d.vault), shares, _flat(PRIORITY_FEE), block.timestamp + 20 days, false
        );

        _drain(BORROWER, 60 ether, 6 ether); // leaves ~4 loan idle — not enough for the whole request

        uint256 lenderBefore = loan.balanceOf(LENDER);
        vm.prank(FILLER);
        vaultBook.fillExitRequest(id, 0, 0); // partial
        Request memory request = vaultBook.getExitRequest(id);
        assertLt(request.sizeRemaining, shares, "partially drained");
        assertGt(request.sizeRemaining, 0, "not fully drained");
        assertEq(uint8(request.status), uint8(ExitStatus.Open), "still open");
        assertGt(loan.balanceOf(LENDER), lenderBefore, "lender credited on the partial fill");

        _repayAll(BORROWER); // idle grows enough to finish
        vm.prank(FILLER);
        vaultBook.fillExitRequest(id, 0, 0); // final
        assertEq(uint8(vaultBook.getExitRequest(id).status), uint8(ExitStatus.Filled), "filled after final");
        assertEq(loan.balanceOf(address(vaultBook)), 0, "book never holds a balance");
    }

    /* Cancel marks the request and blocks any further fill. */
    function test_erc4626_cancel_blocksFill() public {
        uint256 shares = _depositToVault(LENDER, 8 ether);
        vm.prank(LENDER);
        IVaultLike(d.vault).approve(address(vaultBook), type(uint256).max);
        vm.prank(LENDER);
        uint256 id = vaultBook.placeExitRequest(IERC4626(d.vault), shares, _flat(0), block.timestamp + 1 days, false);

        vm.prank(LENDER);
        vaultBook.cancelExitRequest(id);
        assertEq(uint8(vaultBook.getExitRequest(id).status), uint8(ExitStatus.Cancelled), "cancelled");

        vm.prank(FILLER);
        vm.expectRevert(ExitBookLib.RequestClosed.selector);
        vaultBook.fillExitRequest(id, 0, 0);
    }

    /* Filler brings its own liquidity to close an otherwise-unfillable request in one call. */
    function test_erc4626_fillWithLiquidity_fillerFunds() public {
        uint256 shares = _depositToVault(LENDER, 10 ether);
        _drain(BORROWER, 90 ether, 9 ether); // leaves ~1 loan idle — not enough for the request

        uint256 deadline = block.timestamp + 7 days;
        vm.prank(LENDER);
        IVaultLike(d.vault).approve(address(vaultBook), type(uint256).max);
        vm.prank(LENDER);
        uint256 id = vaultBook.placeExitRequest(IERC4626(d.vault), shares, _flat(PRIORITY_FEE), deadline, false);

        vm.warp(deadline);
        loan.mint(FILLER, 10 ether);
        vm.startPrank(FILLER);
        loan.approve(address(vaultBook), 10 ether);
        vaultBook.fillExitRequest(id, 10 ether, 0); // deposits into the vault, then fills
        vm.stopPrank();

        assertEq(uint8(vaultBook.getExitRequest(id).status), uint8(ExitStatus.Filled), "filled by filler liquidity");
        assertGt(loan.balanceOf(LENDER), 0, "lender credited the owed");
        assertGt(loan.balanceOf(FILLER), 0, "filler credited the reward");
        assertGt(IVaultLike(d.vault).balanceOf(FILLER), 0, "filler holds vault shares from the deposit");
    }

    /* previewFill reports a live, non-zero fillable amount for an open, liquid request. */
    function test_erc4626_previewFill_reportsFillable() public {
        uint256 shares = _depositToVault(LENDER, 10 ether);
        vm.prank(LENDER);
        IVaultLike(d.vault).approve(address(vaultBook), type(uint256).max);
        vm.prank(LENDER);
        uint256 id = vaultBook.placeExitRequest(IERC4626(d.vault), shares, _flat(0), block.timestamp + 1 days, false);

        RequestPreview memory preview = vaultBook.previewFill(id);
        assertEq(preview.id, id, "preview carries the id");
        assertEq(preview.filledShares, shares, "all shares fillable with ample idle");
        assertGt(preview.assetsOut, 0, "assets out positive");
    }

    /* getOwnerRequestIds lists every id a lender opened, and nothing for others. */
    function test_erc4626_getOwnerRequestIds_listsLenderIds() public {
        uint256 shares = _depositToVault(LENDER, 20 ether);
        vm.prank(LENDER);
        IVaultLike(d.vault).approve(address(vaultBook), type(uint256).max);

        vm.prank(LENDER);
        uint256 id1 =
            vaultBook.placeExitRequest(IERC4626(d.vault), shares / 2, _flat(0), block.timestamp + 1 days, false);
        vm.prank(LENDER);
        uint256 id2 =
            vaultBook.placeExitRequest(IERC4626(d.vault), shares / 2, _flat(0), block.timestamp + 1 days, false);

        assertEq(vaultBook.getOwnerRequestCount(LENDER), 2, "two lender requests");
        uint256[] memory ids = vaultBook.getOwnerRequestIds(LENDER, 0, 10);
        assertEq(ids.length, 2, "both lender ids in the page");
        assertEq(ids[0], id1, "first id");
        assertEq(ids[1], id2, "second id");
        assertEq(vaultBook.getOwnerRequestIds(LENDER, 1, 10).length, 1, "page from offset 1");
        assertEq(vaultBook.getOwnerRequestIds(LENDER, 5, 10).length, 0, "offset past end -> empty");
        assertEq(vaultBook.getOwnerRequestCount(FILLER), 0, "none for a non-lender");
    }

    /* getRequestPreviews pairs each id with its request and live previewFill, and zeroes an unknown id. */
    function test_erc4626_getRequestPreviews_pairsIdAndPreview() public {
        uint256 shares = _depositToVault(LENDER, 20 ether);
        vm.prank(LENDER);
        IVaultLike(d.vault).approve(address(vaultBook), type(uint256).max);
        vm.prank(LENDER);
        uint256 id1 =
            vaultBook.placeExitRequest(IERC4626(d.vault), shares / 2, _flat(0), block.timestamp + 1 days, false);
        vm.prank(LENDER);
        uint256 id2 =
            vaultBook.placeExitRequest(IERC4626(d.vault), shares / 2, _flat(0), block.timestamp + 1 days, false);

        // caller passes its own id set — the lender's ids plus a non-existent one
        uint256[] memory ids = new uint256[](3);
        ids[0] = id1;
        ids[1] = id2;
        ids[2] = 999;

        RequestPreview[] memory previews = vaultBook.getRequestPreviews(ids);
        assertEq(previews.length, 3, "one preview per id");
        assertEq(previews[0].id, id1, "first id");
        assertEq(previews[1].id, id2, "second id");
        assertEq(previews[0].request.owner, LENDER, "request payload present");

        // the batch entry mirrors the single previewFill(id1) exactly
        RequestPreview memory single = vaultBook.previewFill(id1);
        assertEq(previews[0].filledShares, single.filledShares, "filledShares mirrors previewFill");
        assertEq(previews[0].assetsOut, single.assetsOut, "assetsOut mirrors previewFill");
        assertGt(previews[0].filledShares, 0, "open request is fillable");

        // an unknown id short-circuits to a zero row (closed/missing requests skip the source call)
        assertEq(previews[2].id, 999, "unknown id echoed");
        assertEq(previews[2].filledShares, 0, "unknown id not fillable");
        assertEq(previews[2].assetsOut, 0, "unknown id no assets");
    }

    /* getRequests is a cheap batch read of the raw requests by id (no source calls). */
    function test_erc4626_getRequests_batchReadsById() public {
        uint256 shares = _depositToVault(LENDER, 20 ether);
        vm.prank(LENDER);
        IVaultLike(d.vault).approve(address(vaultBook), type(uint256).max);
        vm.prank(LENDER);
        uint256 id1 =
            vaultBook.placeExitRequest(IERC4626(d.vault), shares / 2, _flat(0), block.timestamp + 1 days, false);
        vm.prank(LENDER);
        uint256 id2 =
            vaultBook.placeExitRequest(IERC4626(d.vault), shares / 2, _flat(0), block.timestamp + 1 days, false);

        uint256[] memory ids = new uint256[](3);
        ids[0] = id1;
        ids[1] = id2;
        ids[2] = 999; // unknown id -> a zeroed Request, no revert

        Request[] memory reqs = vaultBook.getRequests(ids);
        assertEq(reqs.length, 3, "one request per id");
        assertEq(reqs[0].owner, LENDER, "first owned by lender");
        assertEq(reqs[1].owner, LENDER, "second owned by lender");
        assertEq(reqs[2].owner, address(0), "unknown id -> empty request");
    }

    /* rampStart holds the fee at startRate before the climb, then it interpolates to endRate as usual. */
    function test_erc4626_priorityRamp_holdsThenClimbs() public {
        uint256 startRate = 0.01e18; // 1%
        uint256 endRate = 0.05e18; // 5%
        uint256 rampStart = 3 days;
        uint256 rampDuration = 10 days;
        uint256 createdAt = block.timestamp;

        uint256 shares = _depositToVault(LENDER, 40 ether);
        vm.prank(LENDER);
        IVaultLike(d.vault).approve(address(vaultBook), type(uint256).max);

        uint256 slice = shares / 4;
        uint256[3] memory ids;
        for (uint256 i; i < 3; ++i) {
            vm.prank(LENDER);
            ids[i] = vaultBook.placeExitRequest(
                IERC4626(d.vault),
                slice,
                _rampHold(startRate, endRate, rampStart, rampDuration),
                createdAt + 20 days,
                false
            );
        }

        uint256[3] memory fillAt;
        fillAt[0] = createdAt + rampStart - 1; // inside the hold -> startRate
        fillAt[1] = createdAt + rampStart + rampDuration / 2; // mid-climb -> 3%
        fillAt[2] = createdAt + rampStart + rampDuration + 5 days; // plateau -> endRate
        uint256[3] memory wantRate;
        wantRate[0] = startRate;
        wantRate[1] = startRate + (endRate - startRate) / 2;
        wantRate[2] = endRate;

        for (uint256 i; i < 3; ++i) {
            Request memory request = vaultBook.getExitRequest(ids[i]);
            uint256 owed = uint256(request.sizeRemaining) * request.pricePerShare / WAD;
            uint256 fee = owed * wantRate[i] / WAD; // flat price -> no yield -> reward is the fee only
            uint256 serviceCut = fee * SERVICE_FEE / WAD;

            uint256 lenderBefore = loan.balanceOf(LENDER);
            uint256 fillerBefore = loan.balanceOf(FILLER);

            vm.warp(fillAt[i]);
            vm.prank(FILLER);
            vaultBook.fillExitRequest(ids[i], 0, 0);

            assertApproxEqAbs(
                loan.balanceOf(LENDER) - lenderBefore, owed - fee, 1e6, "lender: owed minus held/ramped fee"
            );
            assertApproxEqAbs(
                loan.balanceOf(FILLER) - fillerBefore, fee - serviceCut, 1e6, "filler: held/ramped fee minus cut"
            );
        }
    }

    /* Priority fee follows the Dutch ramp: startRate at creation, linear to endRate, then flat to the deadline. */
    function test_erc4626_priorityRamp_interpolatesThenPlateaus() public {
        uint256 startRate = 0.01e18; // 1%
        uint256 endRate = 0.05e18; // 5%
        uint256 rampDuration = 10 days;
        uint256 createdAt = block.timestamp;

        uint256 shares = _depositToVault(LENDER, 40 ether);
        vm.prank(LENDER);
        IVaultLike(d.vault).approve(address(vaultBook), type(uint256).max);

        uint256 slice = shares / 4;
        uint256[3] memory ids;
        for (uint256 i; i < 3; ++i) {
            vm.prank(LENDER);
            ids[i] = vaultBook.placeExitRequest(
                IERC4626(d.vault), slice, _ramp(startRate, endRate, rampDuration), createdAt + 20 days, false
            );
        }

        uint256[3] memory fillAt;
        fillAt[0] = createdAt; // elapsed 0 -> startRate
        fillAt[1] = createdAt + rampDuration / 2; // mid-ramp -> 3%
        fillAt[2] = createdAt + rampDuration + 5 days; // plateau -> endRate
        uint256[3] memory wantRate;
        wantRate[0] = startRate;
        wantRate[1] = startRate + (endRate - startRate) / 2;
        wantRate[2] = endRate;

        for (uint256 i; i < 3; ++i) {
            Request memory request = vaultBook.getExitRequest(ids[i]);
            uint256 owed = uint256(request.sizeRemaining) * request.pricePerShare / WAD;
            uint256 fee = owed * wantRate[i] / WAD; // flat price -> no yield -> reward is the fee only
            uint256 serviceCut = fee * SERVICE_FEE / WAD;

            uint256 lenderBefore = loan.balanceOf(LENDER);
            uint256 fillerBefore = loan.balanceOf(FILLER);

            vm.warp(fillAt[i]);
            vm.prank(FILLER);
            vaultBook.fillExitRequest(ids[i], 0, 0);

            assertApproxEqAbs(loan.balanceOf(LENDER) - lenderBefore, owed - fee, 1e6, "lender: owed minus ramped fee");
            assertApproxEqAbs(
                loan.balanceOf(FILLER) - fillerBefore, fee - serviceCut, 1e6, "filler: ramped fee minus cut"
            );
        }
    }

    /* minAssetsOut is a slippage floor on the redeem proceeds: too-high reverts, at/below passes. */
    function test_erc4626_minAssetsOut_gatesFill() public {
        uint256 amount = 10 ether;
        uint256 shares = _depositToVault(LENDER, amount);
        vm.prank(LENDER);
        IVaultLike(d.vault).approve(address(vaultBook), type(uint256).max);
        vm.prank(LENDER);
        uint256 id = vaultBook.placeExitRequest(IERC4626(d.vault), shares, _flat(0), block.timestamp + 1 days, false);

        // the fill redeems ~`amount` of loan (flat price, no yield)
        vm.prank(FILLER);
        vm.expectRevert(ExitBookBase.AssetsOutBelowMin.selector);
        vaultBook.fillExitRequest(id, 0, amount * 2); // floor above the proceeds

        vm.prank(FILLER);
        vaultBook.fillExitRequest(id, 0, amount / 2); // floor below -> goes through
        assertEq(uint8(vaultBook.getExitRequest(id).status), uint8(ExitStatus.Filled), "filled once floor cleared");
    }

    function testRevert_place_startFeeAboveEnd() public {
        uint256 shares = _depositToVault(LENDER, 5 ether);
        vm.prank(LENDER);
        IVaultLike(d.vault).approve(address(vaultBook), type(uint256).max);
        vm.prank(LENDER);
        vm.expectRevert(ExitBookBase.StartFeeAboveEnd.selector);
        vaultBook.placeExitRequest(
            IERC4626(d.vault), shares, _ramp(0.05e18, 0.01e18, 1 days), block.timestamp + 7 days, false
        );
    }

    function testRevert_place_endFeeTooHigh() public {
        uint256 shares = _depositToVault(LENDER, 5 ether);
        vm.prank(LENDER);
        IVaultLike(d.vault).approve(address(vaultBook), type(uint256).max);
        vm.prank(LENDER);
        vm.expectRevert(ExitBookBase.PriorityFeeTooHigh.selector);
        vaultBook.placeExitRequest(IERC4626(d.vault), shares, _flat(0.2e18), block.timestamp + 7 days, false);
    }

    function testRevert_place_rampPastDeadline() public {
        uint256 shares = _depositToVault(LENDER, 5 ether);
        vm.prank(LENDER);
        IVaultLike(d.vault).approve(address(vaultBook), type(uint256).max);
        vm.prank(LENDER);
        // ramp end (10 days) overshoots the window to the deadline (5 days)
        vm.expectRevert(ExitBookBase.RampPastDeadline.selector);
        vaultBook.placeExitRequest(
            IERC4626(d.vault), shares, _ramp(0, 0.05e18, 10 days), block.timestamp + 5 days, false
        );
    }

    function testRevert_erc4626_place_vaultNotAllowed() public {
        vm.prank(LENDER);
        vm.expectRevert(Erc4626ExitBook.VaultNotAllowed.selector);
        vaultBook.placeExitRequest(IERC4626(address(0xdead)), 1 ether, _flat(0), block.timestamp + 1 days, false);
    }

    /* Disallowing a vault blocks new requests but leaves already-placed ones fillable. */
    function test_erc4626_disallowVault_blocksPlaceNotFill() public {
        uint256 shares = _depositToVault(LENDER, 10 ether);
        uint256 deadline = block.timestamp + 7 days;
        vm.prank(LENDER);
        IVaultLike(d.vault).approve(address(vaultBook), type(uint256).max);
        vm.prank(LENDER);
        uint256 id = vaultBook.placeExitRequest(IERC4626(d.vault), shares, _flat(0), deadline, false);

        vaultBook.setVaultAllowed(IERC4626(d.vault), false); // governance forbids the vault

        // no new requests against it
        vm.prank(LENDER);
        vm.expectRevert(Erc4626ExitBook.VaultNotAllowed.selector);
        vaultBook.placeExitRequest(IERC4626(d.vault), shares, _flat(0), deadline, false);

        // but the already-placed request still fills
        vm.prank(FILLER);
        vaultBook.fillExitRequest(id, 0, 0);
        assertEq(
            uint8(vaultBook.getExitRequest(id).status), uint8(ExitStatus.Filled), "existing request still fillable"
        );
    }

    // ---
    // MORPHO BOOK
    // ---

    /* Full fill from a Morpho supply position (core authorization, no escrow). */
    function test_morpho_fill_pushesPayouts() public {
        uint256 supplyShares = _supplyDirect(LENDER, 10 ether);
        uint256 deadline = block.timestamp + 7 days;

        vm.prank(LENDER);
        ICoreLike(d.core).setAuthorization(address(morphoBook), true);
        vm.prank(LENDER);
        uint256 id = morphoBook.placeExitRequest(d.marketId, supplyShares, _flat(PRIORITY_FEE), deadline, false);

        Request memory request = morphoBook.getExitRequest(id);
        uint256 owed = supplyShares * request.pricePerShare / WAD;
        uint256 fee = owed * PRIORITY_FEE / WAD;
        uint256 serviceCut = fee * SERVICE_FEE / WAD;

        (uint256 supplyBefore,,) = ICoreLike(d.core).position(d.marketId, LENDER);

        vm.warp(deadline);
        vm.prank(FILLER);
        morphoBook.fillExitRequest(id, 0, 0);

        (uint256 supplyAfter,,) = ICoreLike(d.core).position(d.marketId, LENDER);
        assertLt(supplyAfter, supplyBefore, "lender core position reduced by the fill");
        assertApproxEqAbs(loan.balanceOf(LENDER), owed - fee, 1e6, "lender: owed minus fee");
        assertApproxEqAbs(loan.balanceOf(FILLER), fee - serviceCut, 1e6, "filler: fee minus cut");
        assertApproxEqAbs(loan.balanceOf(FEE_RECIPIENT), serviceCut, 1e6, "service: cut of gross");
        assertEq(loan.balanceOf(address(morphoBook)), 0, "book never holds a balance");
    }

    function testRevert_morpho_place_marketNotAllowed() public {
        MorphoExitBook fresh = new MorphoExitBook(d.core, address(this), MAX_LIFETIME);
        vm.prank(LENDER);
        ICoreLike(d.core).setAuthorization(address(fresh), true);
        vm.prank(LENDER);
        vm.expectRevert(MorphoExitBook.MarketNotAllowed.selector);
        fresh.placeExitRequest(d.marketId, 1 ether, _flat(0), block.timestamp + 1 days, false);
    }

    /* Disallowing a market blocks new requests but leaves already-placed ones fillable. */
    function test_morpho_disallowMarket_blocksPlaceNotFill() public {
        uint256 supplyShares = _supplyDirect(LENDER, 10 ether);
        uint256 deadline = block.timestamp + 7 days;
        vm.prank(LENDER);
        ICoreLike(d.core).setAuthorization(address(morphoBook), true);
        vm.prank(LENDER);
        uint256 id = morphoBook.placeExitRequest(d.marketId, supplyShares, _flat(0), deadline, false);

        morphoBook.setMarketAllowed(d.params, false); // governance forbids the market

        vm.prank(LENDER);
        vm.expectRevert(MorphoExitBook.MarketNotAllowed.selector);
        morphoBook.placeExitRequest(d.marketId, supplyShares, _flat(0), deadline, false);

        vm.prank(FILLER);
        morphoBook.fillExitRequest(id, 0, 0);
        assertEq(
            uint8(morphoBook.getExitRequest(id).status), uint8(ExitStatus.Filled), "existing request still fillable"
        );
    }

    /* The market-existence check runs even on disallow, not just allow. */
    function testRevert_morpho_setMarketAllowed_marketNotCreated() public {
        MarketParams memory ghost = MarketParams({
            loanToken: address(loan),
            collateralToken: address(collateral),
            oracle: address(0xDEAD),
            irm: address(0xBEEF),
            lltv: 0.5e18
        });
        vm.expectRevert(MorphoExitBook.MarketNotCreated.selector);
        morphoBook.setMarketAllowed(ghost, false); // disallowing a non-existent market still reverts
    }

    function testRevert_morpho_place_notAuthorized() public {
        _supplyDirect(LENDER, 10 ether);
        vm.prank(LENDER);
        vm.expectRevert(MorphoExitBook.NotAuthorizedOnMorpho.selector);
        morphoBook.placeExitRequest(d.marketId, 1 ether, _flat(0), block.timestamp + 1 days, false);
    }

    /* Placing for more supply shares than the lender holds reverts at placement (like ERC-4626). */
    function testRevert_morpho_place_insufficientBacking() public {
        uint256 supplyShares = _supplyDirect(LENDER, 10 ether);
        vm.prank(LENDER);
        ICoreLike(d.core).setAuthorization(address(morphoBook), true);
        vm.prank(LENDER);
        vm.expectRevert(MorphoExitBook.InsufficientBacking.selector);
        morphoBook.placeExitRequest(d.marketId, supplyShares + 1, _flat(0), block.timestamp + 1 days, false);
    }

    /* previewFill drops to zero once the owner revokes authorization, and the fill then reverts cleanly. */
    function test_morpho_previewFill_reflectsDeauthorize() public {
        uint256 supplyShares = _supplyDirect(LENDER, 10 ether);
        vm.prank(LENDER);
        ICoreLike(d.core).setAuthorization(address(morphoBook), true);
        vm.prank(LENDER);
        uint256 id = morphoBook.placeExitRequest(d.marketId, supplyShares, _flat(0), block.timestamp + 1 days, false);

        assertGt(morphoBook.previewFill(id).filledShares, 0, "fillable while authorized");

        vm.prank(LENDER);
        ICoreLike(d.core).setAuthorization(address(morphoBook), false);

        assertEq(morphoBook.previewFill(id).filledShares, 0, "previewFill zero after authorization revoked");

        vm.prank(FILLER);
        vm.expectRevert(ExitBookBase.NoFillableShares.selector);
        morphoBook.fillExitRequest(id, 0, 0);
    }

    // ---
    // HELPERS
    // ---

    /// @dev A flat priority fee: `rate` from creation, no ramp.
    function _flat(uint256 rate) internal pure returns (PriorityRamp memory) {
        return PriorityRamp({startRate: rate, endRate: rate, rampStart: 0, rampEnd: 0});
    }

    /// @dev A Dutch ramp: `start` at creation climbing to `end` over `dur` seconds, then flat to the deadline.
    function _ramp(uint256 start, uint256 end, uint256 dur) internal pure returns (PriorityRamp memory) {
        return PriorityRamp({startRate: start, endRate: end, rampStart: 0, rampEnd: dur});
    }

    /// @dev A Dutch ramp with a hold: `start` held for `hold` seconds, then climbing to `end` over `dur`.
    function _rampHold(uint256 start, uint256 end, uint256 hold, uint256 dur)
        internal
        pure
        returns (PriorityRamp memory)
    {
        return PriorityRamp({startRate: start, endRate: end, rampStart: hold, rampEnd: hold + dur});
    }

    function _depositToVault(address lender, uint256 amount) internal returns (uint256 shares) {
        loan.mint(lender, amount);
        vm.startPrank(lender);
        loan.approve(d.vault, type(uint256).max);
        shares = IVaultLike(d.vault).deposit(amount, lender);
        vm.stopPrank();
    }

    function _supplyDirect(address lender, uint256 amount) internal returns (uint256 supplyShares) {
        loan.mint(lender, amount);
        vm.startPrank(lender);
        loan.approve(d.core, type(uint256).max);
        ICoreLike(d.core).supply(d.params, amount, 0, lender, "");
        vm.stopPrank();
        (supplyShares,,) = ICoreLike(d.core).position(d.marketId, lender);
    }

    /// @dev Borrower posts collateral, waits out activation, and borrows to drain idle loan liquidity.
    function _drain(address borrower, uint256 collateralAmount, uint256 borrowAmount) internal {
        collateral.mint(borrower, collateralAmount);
        vm.startPrank(borrower);
        collateral.approve(d.core, type(uint256).max);
        ICoreLike(d.core).supplyCollateral(d.params, collateralAmount, borrower, "");
        vm.stopPrank();

        vm.warp(block.timestamp + 2 hours + 1);
        vm.prank(borrower);
        ICoreLike(d.core).borrow(d.params, borrowAmount, 0, borrower, borrower);
    }

    function _repayAll(address borrower) internal {
        (, uint128 borrowShares,) = ICoreLike(d.core).position(d.marketId, borrower);
        loan.mint(borrower, 1_000 ether);
        vm.startPrank(borrower);
        loan.approve(d.core, type(uint256).max);
        ICoreLike(d.core).repay(d.params, 0, borrowShares, borrower, "");
        vm.stopPrank();
    }
}
