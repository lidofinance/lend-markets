// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {LidoLendSetup} from "../setup/LidoLendSetup.sol";
import {Market} from "../setup/Types.sol";
import {MarketActions} from "../setup/MarketActions.sol";
import {MockERC20} from "../setup/Mocks.sol";

/// @notice Regression for the `fallbackExit` liquidity-dust revert: on a populated market (5 vault lenders, 5
///         direct core lenders) at high utilization, the last lender out used to be stranded by the settle gate.
contract FallbackExitDustReproTest is LidoLendSetup {
    using MarketActions for Market;

    address[5] internal vaultLenders;
    uint256[5] internal vaultShares;

    function setUp() public {
        MockERC20 loan = new MockERC20("Loan", "LOAN", 18);
        MockERC20 collateral = new MockERC20("Collateral", "COLL", 18);
        _deployProtocol(_defaultConfig(address(loan), address(collateral), address(collateral)));
    }

    /// @dev On a populated, high-utilization market whose share ratio has drifted with interest, every vault lender
    ///      exits its full position — including the last — and the vault drains to zero with no dust stranding.
    function test_regression_lastLenderCanExitOnPopulatedMarket() public {
        Market storage m = protocol.markets[0];

        // 5 lenders into the vault, 5 directly into the core (10 loan each -> 100 supplied).
        for (uint256 i; i < 5; ++i) {
            address u = _actor(string(abi.encodePacked("vault", vm.toString(i))));
            vaultLenders[i] = u;
            _fund(m.loanToken, u, 10 ether);
            vaultShares[i] = m.vaultDeposit(u, 10 ether);
        }
        for (uint256 i; i < 5; ++i) {
            address u = _actor(string(abi.encodePacked("core", vm.toString(i))));
            _fund(m.loanToken, u, 10 ether);
            vm.startPrank(u);
            m.loanToken.approve(address(m.core), 10 ether);
            m.core.supply(m.params, 10 ether, 0, u, "");
            vm.stopPrank();
        }

        // 95% utilization, then interest accrues (drifts the ratio so the floor-share redeem leaves dust).
        address borrower = _actor("borrower");
        _fund(m.collateralToken, borrower, 100_000 ether);
        m.supplyCollateral(borrower, 100_000 ether);
        m.activateCollateral();
        vm.prank(borrower);
        m.core.borrow(m.params, 95 ether, 0, borrower, borrower);
        vm.warp(block.timestamp + 365 days);

        // Every vault lender exits their full position, including the last (who is essentially the whole remaining
        // vault and was previously stranded).
        for (uint256 i; i < 5; ++i) {
            vm.prank(vaultLenders[i]);
            (uint256 sharesBurned,,,) = m.vault.fallbackExit(vaultShares[i], vaultLenders[i], vaultLenders[i], 0);
            assertEq(sharesBurned, vaultShares[i], "lender exits fully (no dust stranding)");
        }
        assertEq(m.vault.totalSupply(), 0, "vault fully drained, no shares stranded");
    }
}
