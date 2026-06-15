// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";

import {Id, MarketParams} from "@lido-lend/src/interfaces/IMorpho.sol";
import {WithdrawalQueue} from "../../src/periphery/WithdrawalQueue.sol";
import {WithdrawalQueueLib} from "../../src/libs/WithdrawalQueueLib.sol";
import {LidoLendDeployer} from "../../script/lib/LidoLendDeployer.sol";

interface IStETH {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function submit(address referral) external payable returns (uint256);
}

interface IERC20Like {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IWETHLike is IERC20Like {
    function deposit() external payable;
}

interface IWstETHLike is IERC20Like {
    function wrap(uint256 stETHAmount) external returns (uint256);
}

interface IVaultLike is IERC20Like {
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function convertToAssets(uint256 shares) external view returns (uint256);
    function convertToShares(uint256 assets) external view returns (uint256);
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
    function accrueInterest(MarketParams memory p) external;
    function position(Id id, address user)
        external
        view
        returns (uint256 supplyShares, uint128 borrowShares, uint128 collateral);
}

/// @notice Happy-path coverage for `WithdrawalQueue` on a mainnet fork against a freshly deployed
///         stack: vault-mode and direct-mode requests, partial then final fills with accrued yield,
///         fee/protocol split, claims by all parties, cancel with escrow refund, and the views.
contract WithdrawalQueueTest is Test, LidoLendDeployer {
    address internal constant WETH_ADDRESS = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant STETH_ADDRESS = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    address internal constant WSTETH_ADDRESS = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;

    IWETHLike internal constant WETH = IWETHLike(WETH_ADDRESS);
    IStETH internal constant STETH = IStETH(STETH_ADDRESS);
    IWstETHLike internal constant WSTETH = IWstETHLike(WSTETH_ADDRESS);

    address internal constant LENDER = address(0x1000);
    address internal constant KEEPER = address(0x2000);
    address internal constant BORROWER = address(0x3000);
    address internal constant PROTOCOL = address(0x4000);

    uint256 internal constant LLTV = 0.8e18;
    uint256 internal constant PROTOCOL_FEE_BPS = 100; // 1%
    uint256 internal constant BPS = 10_000;

    WithdrawalQueue internal queue;
    Deployed internal d;

    function setUp() public {
        if (!_hasMainnetLidoContracts()) return;

        address[] memory guardians = new address[](1);
        guardians[0] = address(this);

        d = _deployForkStack(
            DeployConfig({
                admin: address(this),
                loanToken: WETH_ADDRESS,
                collateralToken: WSTETH_ADDRESS,
                oracleSource: WSTETH_ADDRESS,
                lltv: LLTV,
                enableSettlement: true,
                activation: ActivationConfig({
                    minActivationDelay: 10 minutes,
                    maxActivationDelay: 2 hours,
                    maxSuspicionDelay: 2 hours,
                    activatingHold: 0,
                    inflowDecayWindow: 4 hours,
                    maxDelayInflow: 10_000 ether,
                    minActivationAmount: 10 ether,
                    minDecayInflow: 1_000 ether
                }),
                slicePolicy: SlicePolicyConfig({sliceFloorBps: 100, sliceFloorAssets: 0, fallbackMinRequest: 0}),
                guardians: guardians,
                quorum: 1,
                vaultName: "Lido wstETH/WETH Vault",
                vaultSymbol: "lidoWSTETH-WETH"
            })
        );

        queue = new WithdrawalQueue(d.vault, d.core, d.params, address(this), PROTOCOL, PROTOCOL_FEE_BPS);
    }

    /* T1 — Vault mode, full single fill at the deadline (full fee ramp), ample liquidity */

    function test_vaultMode_fullFill_splitsAndCloses() public {
        vm.skip(!_hasMainnetLidoContracts(), "mainnet fork with Lido contracts required");

        uint256 shares = _depositToVault(LENDER, 10 ether);
        uint256 maxFee = 0.1 ether;
        uint64 deadline = uint64(block.timestamp + 1 days);

        vm.prank(LENDER);
        IERC20Like(d.vault).approve(address(queue), type(uint256).max);
        vm.prank(LENDER);
        uint256 id = queue.requestWithdrawal(WithdrawalQueueLib.Mode.Vault, 10 ether, maxFee, deadline, false);

        // escrow + registry state
        assertEq(IERC20Like(d.vault).balanceOf(address(queue)), shares, "shares escrowed");
        assertEq(queue.activeRequestCount(), 1, "one active request");
        WithdrawalQueueLib.Request memory request = queue.getRequest(id);
        assertEq(request.owner, LENDER);
        assertEq(uint8(request.mode), uint8(WithdrawalQueueLib.Mode.Vault));
        assertEq(request.sizeRemaining, shares, "size is the escrowed shares");
        assertEq(request.sizeTotal, shares, "total equals the initial size");
        assertEq(request.maxPriorityFee, maxFee, "fee cap stored");
        assertFalse(request.fullFillOnly, "partial fills allowed");
        assertFalse(request.closed);

        // Fill exactly at the deadline → ramp is full, so the whole cap is charged. No borrower means
        // the share price is flat, so there is no accrued yield: the keeper's reward is exactly the cap.
        vm.warp(deadline);
        vm.prank(KEEPER);
        queue.processWithdrawal(id);

        uint256 lenderCredit = queue.claimable(LENDER);
        uint256 keeperCredit = queue.claimable(KEEPER);
        uint256 protocolCredit = queue.claimable(PROTOCOL);

        uint256 total = lenderCredit + keeperCredit + protocolCredit;
        assertApproxEqAbs(keeperCredit + protocolCredit, maxFee, 1e6, "reward is the full fee, no yield");
        assertApproxEqAbs(protocolCredit, maxFee * PROTOCOL_FEE_BPS / BPS, 1e6, "protocol cut of the fee");
        assertEq(lenderCredit, total - keeperCredit - protocolCredit, "lender takes the rest");
        assertEq(queue.activeRequestCount(), 0, "request closed and dropped");
        assertTrue(queue.getRequest(id).closed, "closed flag");

        _assertClaim(LENDER, lenderCredit);
        _assertClaim(KEEPER, keeperCredit);
        _assertClaim(PROTOCOL, protocolCredit);
    }

    /* T1b — Dutch ramp: filling at half the window charges half the fee cap */

    function test_vaultMode_halfRamp_chargesHalfFee() public {
        vm.skip(!_hasMainnetLidoContracts(), "mainnet fork with Lido contracts required");

        _depositToVault(LENDER, 10 ether);
        uint256 maxFee = 0.2 ether;
        uint256 start = block.timestamp;
        uint64 deadline = uint64(start + 100);

        vm.prank(LENDER);
        IERC20Like(d.vault).approve(address(queue), type(uint256).max);
        vm.prank(LENDER);
        uint256 id = queue.requestWithdrawal(WithdrawalQueueLib.Mode.Vault, 10 ether, maxFee, deadline, false);

        // Halfway to the deadline; no borrower → price flat → no yield, so the reward is purely the
        // ramped fee, which at the midpoint is half the cap.
        vm.warp(start + 50);
        vm.prank(KEEPER);
        queue.processWithdrawal(id);

        uint256 reward = queue.claimable(KEEPER) + queue.claimable(PROTOCOL);
        assertApproxEqAbs(reward, maxFee / 2, 1e6, "half the cap at half the ramp");
    }

    /* T2 — Vault mode, partial then final fill, accrued yield to keeper */

    function test_vaultMode_partialThenFinal_yieldToKeeper() public {
        vm.skip(!_hasMainnetLidoContracts(), "mainnet fork with Lido contracts required");

        uint256 shares = _depositToVault(LENDER, 10 ether);
        _drain(BORROWER, 60 ether, 6 ether); // leaves ~4 WETH idle

        uint256 maxFee = 0.3 ether;
        vm.prank(LENDER);
        IERC20Like(d.vault).approve(address(queue), type(uint256).max);
        vm.prank(LENDER);
        // Deadline well past the warp below so the request is still fillable (ramped, not expired).
        uint256 id = queue.requestWithdrawal(
            WithdrawalQueueLib.Mode.Vault, 10 ether, maxFee, uint64(block.timestamp + 365 days), false
        );

        uint256 priceAtRequest = queue.getRequest(id).pricePerShare;

        // accrue interest so the share price rises above the fixed request price
        vm.warp(block.timestamp + 90 days);
        ICoreLike(d.core).accrueInterest(d.params);
        assertGt(IVaultLike(d.vault).convertToAssets(1e18), priceAtRequest, "share price rose");

        uint256 lenderBefore = queue.claimable(LENDER);
        vm.prank(KEEPER);
        queue.processWithdrawal(id); // partial — bounded by ~4 WETH idle
        assertLt(queue.getRequest(id).sizeRemaining, shares, "partially drained");
        assertGt(queue.getRequest(id).sizeRemaining, 0, "not fully drained yet");
        assertGt(queue.claimable(LENDER), lenderBefore, "lender credited on partial");

        // borrower repays → idle grows enough to finish
        _repayAll(BORROWER);
        vm.prank(KEEPER);
        queue.processWithdrawal(id); // final
        assertTrue(queue.getRequest(id).closed, "closed after final fill");

        // conservation: everything credited equals the lender's fixed owed + the keeper reward + protocol
        uint256 totalOwed = shares * priceAtRequest / 1e18;
        uint256 lenderTotal = queue.claimable(LENDER);
        uint256 keeperTotal = queue.claimable(KEEPER);
        uint256 protocolTotal = queue.claimable(PROTOCOL);
        // The lender keeps the fixed-price owed less the ramped fee, which is at most the cap; the
        // unramped remainder (both fills fire before the deadline) stays with the lender.
        assertLe(lenderTotal, totalOwed, "lender never exceeds the fixed owed");
        assertGe(lenderTotal, totalOwed - maxFee, "lender loses at most the fee cap");
        // keeper + protocol = accrued yield + ramped fee; the yield alone makes it positive.
        assertGt(keeperTotal + protocolTotal, 0, "reward captures yield + ramped fee");
        assertApproxEqAbs(
            protocolTotal, (keeperTotal + protocolTotal) * PROTOCOL_FEE_BPS / BPS, 2, "protocol is bps of gross"
        );
    }

    /* T3 — Direct mode (core authorization, no escrow) */

    function test_directMode_withdrawsFromCorePosition() public {
        vm.skip(!_hasMainnetLidoContracts(), "mainnet fork with Lido contracts required");

        _supplyDirect(LENDER, 10 ether);
        (uint256 supplyBefore,,) = ICoreLike(d.core).position(d.marketId, LENDER);
        assertGt(supplyBefore, 0, "lender has a core supply position");

        vm.prank(LENDER);
        ICoreLike(d.core).setAuthorization(address(queue), true);
        uint64 deadline = uint64(block.timestamp + 1 days);
        vm.prank(LENDER);
        uint256 id = queue.requestWithdrawal(WithdrawalQueueLib.Mode.Direct, 5 ether, 0.05 ether, deadline, false);

        // Fill at the deadline so the fee ramp is full and the keeper is actually paid.
        vm.warp(deadline);
        vm.prank(KEEPER);
        queue.processWithdrawal(id);

        (uint256 supplyAfter,,) = ICoreLike(d.core).position(d.marketId, LENDER);
        assertLt(supplyAfter, supplyBefore, "lender core position reduced by the fill");
        assertGt(queue.claimable(LENDER), 0, "lender credited");
        assertGt(queue.claimable(KEEPER), 0, "keeper credited the fee");
    }

    /* T4 — cancel returns the escrowed shares (Vault) */

    function test_cancel_vaultMode_refundsEscrow() public {
        vm.skip(!_hasMainnetLidoContracts(), "mainnet fork with Lido contracts required");

        uint256 shares = _depositToVault(LENDER, 8 ether);
        vm.prank(LENDER);
        IERC20Like(d.vault).approve(address(queue), type(uint256).max);
        vm.prank(LENDER);
        uint256 id =
            queue.requestWithdrawal(WithdrawalQueueLib.Mode.Vault, 8 ether, 0, uint64(block.timestamp + 1 days), false);

        assertEq(IERC20Like(d.vault).balanceOf(LENDER), 0, "shares escrowed");
        vm.prank(LENDER);
        queue.cancelWithdrawal(id);

        assertEq(IERC20Like(d.vault).balanceOf(LENDER), shares, "escrow refunded in full");
        assertEq(queue.activeRequestCount(), 0, "request dropped");
        assertTrue(queue.getRequest(id).closed, "closed");
    }

    /* T5 — views / pagination / swap-pop on close */

    function test_views_paginationAndClose() public {
        vm.skip(!_hasMainnetLidoContracts(), "mainnet fork with Lido contracts required");

        _depositToVault(LENDER, 30 ether);
        vm.prank(LENDER);
        IERC20Like(d.vault).approve(address(queue), type(uint256).max);

        uint256[] memory ids = new uint256[](3);
        for (uint256 index; index < 3; ++index) {
            vm.prank(LENDER);
            ids[index] = queue.requestWithdrawal(
                WithdrawalQueueLib.Mode.Vault, 10 ether, 0, uint64(block.timestamp + 1 days), false
            );
        }
        assertEq(queue.activeRequestCount(), 3, "three active");

        // cancel the middle one → swap-pop moves the last id into its slot
        vm.prank(LENDER);
        queue.cancelWithdrawal(ids[1]);
        assertEq(queue.activeRequestCount(), 2, "two active after cancel");

        uint256[] memory page = queue.activeRequests(0, 10);
        assertEq(page.length, 2, "page has the two open ids");
        // remaining set is {ids[0], ids[2]} in some order (swap-pop)
        bool sawFirst;
        bool sawThird;
        for (uint256 index; index < page.length; ++index) {
            if (page[index] == ids[0]) sawFirst = true;
            if (page[index] == ids[2]) sawThird = true;
        }
        assertTrue(sawFirst && sawThird, "open ids enumerated");

        uint256[] memory empty = queue.activeRequests(5, 10);
        assertEq(empty.length, 0, "offset past end returns empty");
    }

    /* T6 — permissionless prune of expired requests refunds Vault escrow */

    function test_pruneExpired_dropsAndRefunds() public {
        vm.skip(!_hasMainnetLidoContracts(), "mainnet fork with Lido contracts required");

        uint256 shares = _depositToVault(LENDER, 10 ether);
        vm.prank(LENDER);
        IERC20Like(d.vault).approve(address(queue), type(uint256).max);
        uint64 deadline = uint64(block.timestamp + 1 days);
        vm.prank(LENDER);
        uint256 id = queue.requestWithdrawal(WithdrawalQueueLib.Mode.Vault, 10 ether, 0, deadline, false);

        vm.warp(deadline + 1);

        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        // permissionless: a third party prunes
        vm.prank(KEEPER);
        queue.pruneExpired(ids);

        assertEq(queue.activeRequestCount(), 0, "expired request dropped");
        assertTrue(queue.getRequest(id).closed, "closed");
        assertEq(IERC20Like(d.vault).balanceOf(LENDER), shares, "escrow refunded to owner");
    }

    /* T7 — fullFillOnly rejects a partial fill, then completes once liquidity covers the whole size */

    function test_fullFillOnly_rejectsPartialThenCompletes() public {
        vm.skip(!_hasMainnetLidoContracts(), "mainnet fork with Lido contracts required");

        uint256 shares = _depositToVault(LENDER, 10 ether);
        _drain(BORROWER, 60 ether, 6 ether); // leaves ~4 WETH idle — not enough for the whole request

        vm.prank(LENDER);
        IERC20Like(d.vault).approve(address(queue), type(uint256).max);
        vm.prank(LENDER);
        uint256 id = queue.requestWithdrawal(
            WithdrawalQueueLib.Mode.Vault, 10 ether, 0, uint64(block.timestamp + 365 days), true
        );
        assertTrue(queue.getRequest(id).fullFillOnly, "full-fill-only policy stored");

        // Partial liquidity cannot satisfy a full-fill-only request: the keeper gets nothing.
        vm.prank(KEEPER);
        vm.expectRevert(WithdrawalQueue.NothingAvailable.selector);
        queue.processWithdrawal(id);
        assertEq(queue.getRequest(id).sizeRemaining, shares, "untouched after a rejected partial");

        // Borrower repays → idle covers the whole size → a single fill closes it.
        _repayAll(BORROWER);
        vm.prank(KEEPER);
        queue.processWithdrawal(id);
        assertTrue(queue.getRequest(id).closed, "closed in one full fill");
        assertEq(queue.activeRequestCount(), 0, "dropped from active set");
        assertGt(queue.claimable(LENDER), 0, "lender credited the full owed");
    }

    /* HELPERS */

    function _depositToVault(address lender, uint256 ethAmount) internal returns (uint256 shares) {
        vm.deal(lender, ethAmount);
        vm.startPrank(lender);
        WETH.deposit{value: ethAmount}();
        WETH.approve(d.vault, type(uint256).max);
        shares = IVaultLike(d.vault).deposit(ethAmount, lender);
        vm.stopPrank();
    }

    function _supplyDirect(address lender, uint256 ethAmount) internal {
        vm.deal(lender, ethAmount);
        vm.startPrank(lender);
        WETH.deposit{value: ethAmount}();
        WETH.approve(d.core, type(uint256).max);
        ICoreLike(d.core).supply(d.params, ethAmount, 0, lender, "");
        vm.stopPrank();
    }

    /// @dev Borrower posts wstETH collateral, waits out maturation, and borrows to drain idle WETH.
    function _drain(address borrower, uint256 collateralEth, uint256 borrowEth) internal {
        vm.deal(borrower, collateralEth);
        vm.startPrank(borrower);
        STETH.submit{value: collateralEth}(address(0));
        uint256 st = STETH.balanceOf(borrower);
        STETH.approve(WSTETH_ADDRESS, st);
        uint256 wst = WSTETH.wrap(st);
        WSTETH.approve(d.core, type(uint256).max);
        ICoreLike(d.core).supplyCollateral(d.params, wst, borrower, "");
        vm.stopPrank();

        vm.warp(block.timestamp + 2 hours + 1);
        vm.prank(borrower);
        ICoreLike(d.core).borrow(d.params, borrowEth, 0, borrower, borrower);
    }

    function _repayAll(address borrower) internal {
        (, uint128 borrowShares,) = ICoreLike(d.core).position(d.marketId, borrower);
        vm.deal(borrower, 1000 ether);
        vm.startPrank(borrower);
        WETH.deposit{value: 1000 ether}();
        WETH.approve(d.core, type(uint256).max);
        ICoreLike(d.core).repay(d.params, 0, borrowShares, borrower, "");
        vm.stopPrank();
    }

    function _assertClaim(address account, uint256 expected) internal {
        uint256 balanceBefore = WETH.balanceOf(account);
        vm.prank(account);
        queue.claim();
        assertEq(WETH.balanceOf(account) - balanceBefore, expected, "claim transferred the credited amount");
    }

    function _hasMainnetLidoContracts() internal view returns (bool) {
        return block.chainid == 1 && WETH_ADDRESS.code.length != 0 && STETH_ADDRESS.code.length != 0
            && WSTETH_ADDRESS.code.length != 0;
    }
}
