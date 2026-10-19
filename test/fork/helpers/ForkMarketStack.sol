// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Market} from "../../setup/Types.sol";
import {MarketActions} from "../../setup/MarketActions.sol";
import {ForkStack} from "./ForkStack.sol";

/// @notice {ForkStack} bound to the market playing one role, plus the `Market` handle {MarketActions} drives:
///         `deployed` is the raw handle the {ForkStack} helpers take, `market` the one the action helpers take.
///         A suite passes its role to the constructor and calls `_fork()` then `_bindRole()` in `setUp`.
/// @dev `market.config.admin` stays zero on purpose, so the `MarketActions` helpers that self-grant a role as
///      that admin fail loudly on a fork; governance goes through the {ForkStack} facade helpers instead.
abstract contract ForkMarketStack is ForkStack {
    using MarketActions for Market;

    string private role;

    BoundMarket internal deployed;
    Market internal market;

    /// @dev The standard collateral lot: twice the live activation threshold, so it activates with capacity.
    uint256 internal lot;

    // The shared fixture's actors and positions; suites that build their own actors reuse the names.
    address internal LENDER;
    address internal BORROWER;
    uint256 internal lenderShares;
    uint256 internal borrowShares;

    constructor(string memory role_) {
        role = role_;
    }

    /// @notice Bind the run's market for the suite's role into both handles and accrue pending interest. Skips
    ///         the test when the run has no market for the role.
    function _bindRole() internal {
        deployed = _bindMarket(_marketForRole(role));
        _pokeAccrue(deployed); // so the helpers' exact delta assertions hold from the first action
        _copyMarket(market, deployed);
        lot = 2 * uint256(deployed.activation.minActivationAmount);
    }

    /// @notice Copy a binding into the `Market` shape the helpers read, for a suite that binds a second market.
    function _copyMarket(Market storage target, BoundMarket memory source) internal {
        target.core = source.core;
        target.controller = source.controller;
        target.vault = source.vault;
        target.oracle = source.oracle;
        target.guardianSignals = source.guardianSignals;
        target.params = source.params;
        target.id = source.id;
        target.loanToken = source.loanToken;
        target.collateralToken = source.collateralToken;
    }

    /// @notice The shared fixture: a lender funds the vault with twice the borrow plus a non-round tail, a borrower
    ///         posts `lot`, matures it and draws 61% of what it carries. Interest is accrued afterwards so the next
    ///         action's delta assertions are exact.
    function _seedLenderAndBorrower() internal {
        LENDER = _freshActor(deployed, "fixture.lender");
        BORROWER = _freshActor(deployed, "fixture.borrower");

        uint256 borrowAssets = _maxBorrow(deployed, lot, deployed.oracle.price()) * 61 / 100;
        uint256 deposit = 2 * borrowAssets + 4_321;
        _requireSupplyHeadroom(deployed, deposit);
        deal(address(deployed.loanToken), LENDER, deposit);
        lenderShares = market.vaultDeposit(LENDER, deposit);

        deal(address(deployed.collateralToken), BORROWER, lot);
        market.supplyCollateral(BORROWER, lot);
        market.activateCollateral();
        borrowShares = market.borrow(BORROWER, borrowAssets);
        _pokeAccrue(deployed);
    }
}
