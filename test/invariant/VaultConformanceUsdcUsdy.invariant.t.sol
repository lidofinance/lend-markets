// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {VaultConformanceInvariant} from "./VaultConformance.invariant.t.sol";
import {VaultHandler} from "./handlers/VaultHandler.sol";

/// @notice The vault's stateful properties with a six-decimal loan and eighteen-decimal collateral.
/// @dev Token units match USDC/USDY. Each oracle update increases its current price by 1–100 basis points.
/// forge-config: default.invariant.fail-on-revert = true
/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 250
contract VaultConformanceUsdcUsdyInvariant is VaultConformanceInvariant {
    function _loanDecimals() internal pure override returns (uint8) {
        return 6;
    }

    function _priceAction() internal pure override returns (bytes4) {
        return VaultHandler.growPrice.selector;
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
