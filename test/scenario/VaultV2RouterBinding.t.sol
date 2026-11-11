// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Address} from "@openzeppelin/contracts/utils/Address.sol";

import {IVaultV2} from "@vault-v2/src/interfaces/IVaultV2.sol";
import {IMorphoMarketV1AdapterV2} from "@vault-v2/src/adapters/interfaces/IMorphoMarketV1AdapterV2.sol";

import {Id} from "@lido-lend/src/interfaces/IMorpho.sol";
import {IrmRouter} from "@lido-lend-irm/src/irm-router/IrmRouter.sol";
import {Id as IrmId} from "@lido-lend-irm/lib/lido-lend/src/interfaces/IMorpho.sol";

import {PausableUntil} from "../../src/utils/PausableUntil.sol";

import {LidoLendSetup} from "../setup/LidoLendSetup.sol";
import {Market} from "../setup/Types.sol";
import {MarketActions} from "../setup/MarketActions.sol";
import {MockERC20} from "../setup/Mocks.sol";

/// @notice A Vault V2 and the upstream `MorphoMarketV1AdapterV2` whose IRM argument is the protocol IrmRouter. To
///         price a market that has debt and did not accrue in this block, the adapter calls `rateAtTarget` on that
///         address. The router has no such function, so the call reverts with empty data.
///         `script/DeployVaultV2.s.sol` passes the same argument, but these tests do not run the script. They deploy
///         the pair with their own copy of its two constructor calls.
/// @dev The pair is allocated and the market borrowed in `setUp`, which is a transaction of its own. Vault V2 caches
///      its total assets in transient storage for the rest of a transaction, so each test body starts uncached.
contract VaultV2RouterBindingTest is LidoLendSetup {
    using MarketActions for Market;

    uint256 internal constant WAD = 1e18;
    uint256 internal constant USER_DEPOSIT = 50 ether;
    uint256 internal constant ALLOCATED = 40 ether; // the rest stays idle in the Vault V2
    uint256 internal constant BORROWED = 30 ether;

    IVaultV2 internal vault2;

    address internal curator;
    address internal allocator;
    address internal user;

    function setUp() public {
        MockERC20 loan = new MockERC20("Loan", "LOAN", 18);
        MockERC20 collateral = new MockERC20("Collateral", "COLL", 18);
        _deployProtocol(_defaultConfig(address(loan), address(collateral), address(collateral)));
        Market storage m = _m();
        curator = _actor("curator");
        allocator = _actor("allocator");
        user = _actor("user");

        // Collateral worth twice the debt at the seeded price.
        address borrower = _actor("borrower");
        uint256 collateralAmount = 2 * BORROWED * 1e36 / oraclePrice;
        _fund(m.collateralToken, borrower, collateralAmount);
        m.supplyCollateral(borrower, collateralAmount);
        m.activateCollateral();

        address adapter;
        (vault2, adapter) = _deployPair(m.irm);
        _fund(m.loanToken, user, USER_DEPOSIT + 1 ether);
        vm.startPrank(user);
        m.loanToken.approve(address(vault2), type(uint256).max);
        vault2.deposit(USER_DEPOSIT, user);
        vm.stopPrank();
        vm.prank(allocator);
        vault2.allocate(adapter, abi.encode(m.params), ALLOCATED);

        m.borrow(borrower, BORROWED);
    }

    function _m() internal view returns (Market storage) {
        return protocol.markets[0];
    }

    /// @dev Known issue: one second after the last accrual of a borrowed market, the Vault V2 cannot report, take or
    ///      pay out assets.
    ///      Root cause: `DeployVaultV2` passes the IrmRouter as the `adaptiveCurveIrm` of the upstream
    ///      `MorphoMarketV1AdapterV2`. Its `expectedSupplyAssets` calls `rateAtTarget` on that address whenever the
    ///      market has debt and time has passed since the last core accrual. The router has no such function, so
    ///      `realAssets` reverts, and so does every Vault V2 path through `accrueInterestView`.
    ///      Same cause: `deposit`, `mint`, `withdraw`, `redeem`, `totalAssets`, the previews, `allocate`, and the fee
    ///      and rate setters that accrue first. One such market in the adapter blocks the whole vault. It happens in
    ///      any block after a borrow or accrual, with no attacker.
    ///      A fix changes this outcome; update this test with it.
    function testRevert_oneSecondStale_vaultEntryPoints() public {
        _warpOneSecondPastAccrual();
        _assertRouterHasNoRateAtTarget();

        _expectRateAtTargetRevert();
        vault2.totalAssets();

        vm.prank(user);
        _expectRateAtTargetRevert();
        vault2.deposit(1 ether, user);

        vm.prank(user);
        _expectRateAtTargetRevert();
        vault2.withdraw(1 ether, user, user);
    }

    /// @dev Control: a core accrual in the same block makes the market current, so the adapter skips the IRM and the
    ///      same calls go through.
    /// @dev Same issue as `testRevert_oneSecondStale_vaultEntryPoints`.
    function test_accrueFirst_vaultEntryPointsWork() public {
        Market storage m = _m();
        _warpOneSecondPastAccrual();
        m.accrueInterest();

        assertEq(vault2.maxRate(), 0, "setup: the vault credits no interest");
        assertEq(vault2.totalAssets(), USER_DEPOSIT, "total assets are the deposit");

        uint256 idleBefore = m.loanToken.balanceOf(address(vault2));
        vm.startPrank(user);
        vault2.deposit(1 ether, user);
        vault2.withdraw(2 ether, user, user);
        vm.stopPrank();
        assertEq(m.loanToken.balanceOf(address(vault2)), idleBefore - 1 ether, "idle moved by deposit and withdraw");
    }

    /// @dev A controller pause rejects every core accrual, so nobody can make the market current. The Vault V2's
    ///      idle assets stay frozen from the first second of the pause to its last second. After the pause, an
    ///      accrual frees them. A fix changes this outcome; update this test with the fix.
    function testRevert_pausedMarket_idleWithdrawFrozen() public {
        Market storage m = _m();
        uint256 idle = m.loanToken.balanceOf(address(vault2));
        assertEq(idle, USER_DEPOSIT - ALLOCATED, "setup: idle covers the withdraw");
        m.pause(7 days);
        uint256 pauseEnd = block.timestamp + 7 days;
        _warpOneSecondPastAccrual();
        _assertRouterHasNoRateAtTarget();
        _assertAccrualAndWithdrawRevert();

        vm.warp(pauseEnd - 1);
        _assertAccrualAndWithdrawRevert();

        vm.warp(pauseEnd);
        m.accrueInterest();
        vm.prank(user);
        vault2.withdraw(1 ether, user, user);
        assertEq(m.loanToken.balanceOf(address(vault2)), idle - 1 ether, "withdraw paid from idle after the pause");
    }

    /// @dev Binding the adapter to the routed adaptive-curve IRM, as upstream expects, does not help. Every Lido market
    ///      names the router as its IRM, so the adapter refuses the allocation.
    function testRevert_adapterBoundToCurve_allocateIrmMismatch() public {
        Market storage m = _m();
        address curve = address(IrmRouter(m.irm).marketIrm(IrmId.wrap(Id.unwrap(m.id))));
        assertNotEq(curve, address(0), "setup: market routed to a curve");
        assertEq(m.params.irm, m.irm, "setup: market IRM is the router");

        (IVaultV2 curveVault, address curveAdapter) = _deployPair(curve);
        vm.startPrank(user);
        m.loanToken.approve(address(curveVault), 1 ether);
        curveVault.deposit(1 ether, user);
        vm.stopPrank();

        vm.prank(allocator);
        vm.expectRevert(IMorphoMarketV1AdapterV2.IrmMismatch.selector);
        curveVault.allocate(curveAdapter, abi.encode(m.params), 1 ether);
    }

    // ── Helpers ──

    /// @dev Moves one second past the `setUp` block, where the borrowed market last accrued. Checks that no Vault V2
    ///      total is cached in this transaction, so the next vault call prices the market through the adapter.
    function _warpOneSecondPastAccrual() internal {
        Market storage m = _m();
        assertEq(m.core.market(m.id).lastUpdate, block.timestamp, "setup: market accrued in this block");
        assertGt(m.core.market(m.id).totalBorrowAssets, 0, "setup: market carries debt");
        assertEq(vault2.firstTotalAssets(), 0, "setup: no Vault V2 total cached in this transaction");
        vm.warp(block.timestamp + 1);
    }

    function _assertAccrualAndWithdrawRevert() internal {
        Market storage m = _m();
        vm.expectRevert(PausableUntil.ResumedExpected.selector);
        m.core.accrueInterest(m.params);

        vm.prank(user);
        _expectRateAtTargetRevert();
        vault2.withdraw(1 ether, user, user);
    }

    /// @dev Pins the cause of the dataless reverts: a direct `rateAtTarget` call on the router fails with no data.
    function _assertRouterHasNoRateAtTarget() internal view {
        Market storage m = _m();
        (bool ok, bytes memory returned) = m.irm.staticcall(abi.encodeWithSignature("rateAtTarget(bytes32)", m.id));
        assertFalse(ok, "router answers rateAtTarget");
        assertEq(returned.length, 0, "router revert carries data");
    }

    /// @dev Expects the next vault call to call `rateAtTarget` on the router and to revert with no data.
    function _expectRateAtTargetRevert() internal {
        Market storage m = _m();
        vm.expectCall(m.irm, abi.encodeWithSignature("rateAtTarget(bytes32)", m.id));
        vm.expectRevert(bytes(""));
    }

    /// @dev Deploys the pair from the artifacts and constructor arguments of `script/DeployVaultV2.s.sol`, with this
    ///      contract as owner. Then it opens the pair to one allocator and to uncapped allocation into this market.
    function _deployPair(address irm) internal returns (IVaultV2 vault, address adapter) {
        Market storage m = _m();
        vault = IVaultV2(deployCode("VaultV2.sol:VaultV2", abi.encode(address(this), address(m.loanToken))));
        adapter = deployCode(
            "MorphoMarketV1AdapterV2.sol:MorphoMarketV1AdapterV2", abi.encode(address(vault), address(m.core), irm)
        );

        vault.setCurator(curator);
        _executeTimelocked(vault, abi.encodeCall(vault.setIsAllocator, (allocator, true)));
        _executeTimelocked(vault, abi.encodeCall(vault.addAdapter, (adapter)));
        _enableCap(vault, abi.encode("this", adapter));
        _enableCap(vault, abi.encode("collateralToken", m.params.collateralToken));
        _enableCap(vault, abi.encode("this/marketParams", adapter, m.params));
    }

    function _enableCap(IVaultV2 vault, bytes memory idData) internal {
        _executeTimelocked(vault, abi.encodeCall(vault.increaseAbsoluteCap, (idData, type(uint128).max)));
        _executeTimelocked(vault, abi.encodeCall(vault.increaseRelativeCap, (idData, WAD)));
    }

    /// @dev Submits a curator action and executes it at once: a new vault has zero timelocks.
    function _executeTimelocked(IVaultV2 vault, bytes memory data) internal {
        vm.prank(curator);
        vault.submit(data);
        Address.functionCall(address(vault), data);
    }
}
