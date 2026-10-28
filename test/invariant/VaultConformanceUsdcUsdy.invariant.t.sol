// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {VaultConformanceInvariant} from "./VaultConformance.invariant.t.sol";
import {VaultHandler} from "./handlers/VaultHandler.sol";

/// @notice The vault's stateful properties with a six-decimal loan and eighteen-decimal collateral.
/// @dev Token units match USDC/USDY. The price grows by 1–100 basis points per update or crashes to 25–90% of the
///      seed. Audit T1-C6: the crash runs liquidation, bad debt and the bad-debt gate at six-decimal loan units.
/// forge-config: default.invariant.fail-on-revert = true
/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 250
contract VaultConformanceUsdcUsdyInvariant is VaultConformanceInvariant {
    function _loanDecimals() internal pure override returns (uint8) {
        return 6;
    }

    function _priceActions() internal pure override returns (bytes4[] memory actions) {
        actions = new bytes4[](2);
        actions[0] = VaultHandler.crashPrice.selector;
        actions[1] = VaultHandler.growPrice.selector;
    }

    function test_settle_finalDebtRoundingTransfersNoLoanTokens() public {
        handler.repay(1, 1);
        uint256 idleBefore = _mk().totalSupplyAssets - _mk().totalBorrowAssets;
        uint256 loanBefore = _m().loanToken.balanceOf(address(_m().core));
        handler.settle(0, 1, 25 ether);
        assertEq(handler.settles(), 1, "a successful final cut was exercised");
        assertEq(_mk().totalBorrowShares, 0, "all borrower shares closed");
        assertEq(_mk().totalBorrowAssets, 0, "borrow assets saturated at zero");
        assertEq(_mk().totalSupplyAssets, idleBefore - 1, "accounting idle absorbs one raw debt-rounding unit");
        assertEq(_m().loanToken.balanceOf(address(_m().core)), loanBefore, "settle transfers no loan tokens");
        invariant_settleLiquidityMatchesDebtRounding();
        invariant_exitPayoutWithinRoundingBounds();
    }
}
