// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Market} from "../setup/Types.sol";
import {MarketActions} from "../setup/MarketActions.sol";
import {ForkStack} from "./helpers/ForkStack.sol";

interface IWstETHReal {
    function getStETHByWstETH(uint256 wstETHAmount) external view returns (uint256);
    function stEthPerToken() external view returns (uint256);
}

/// @notice Mainnet-fork scenario for the `weth-wsteth` market against the REAL mainnet wstETH, run on the
///         ALREADY-DEPLOYED stack (bound via {ForkStack}, never re-deployed). Unlike the freshly-deployed
///         variant it once was, both the oracle under test and the market it prices are the production
///         instances: the deployed `WstEthRateOracle` proxy and the real WETH/wstETH tokens.
///
///         The two scenarios still read like the deployed variant did — deposit → supply collateral →
///         activate → borrow — because the {MarketActions} helper library drives a `Market` (test/setup),
///         which `setUp` populates entirely from the binding. State-robustness: fresh, market-clean actors;
///         deposit gated by live vault headroom; collateral sized off the live dust threshold; per-actor
///         (delta) assertions, never absolute market totals.
contract EthStethForkTest is ForkStack {
    using MarketActions for Market;

    BoundMarket internal m;

    /// @dev The `Market` the {MarketActions} helpers operate on. Populated from the live binding in `setUp`;
    ///      only the fields the used helpers + tests touch are set (see the field-by-field notes there).
    Market internal market;

    /// @dev The market's real collateral token == mainnet wstETH, and the same wstETH the deployed oracle
    ///      prices — so `IWstETHReal(WSTETH)` queries hit the exact source `market.oracle.price()` reads.
    address internal WSTETH;

    uint256 internal constant LENDER_DEPOSIT = 20 ether;

    function setUp() public {
        _fork();
        m = _bindMarket("fork-weth-wsteth");
        _pokeAccrue(m); // fold pending interest in up front so vaultDeposit's exact totalAssets delta holds

        WSTETH = address(m.collateralToken);

        // Populate the `Market` the helpers drive, entirely from the live binding:
        market.core = m.core; // real Morpho-fork core (supplyCollateral / borrow / accrue)
        market.controller = m.controller; // real Lido controller
        market.vault = m.vault; // real ERC-4626 vault (deposit path)
        market.oracle = m.oracle; // DEPLOYED WstEthRateOracle proxy — the oracle under test
        market.guardianSignals = m.guardianSignals; // real guardian registry
        market.params = m.params; // read back from the core; hashes to `id`
        market.id = m.id;
        market.loanToken = m.loanToken; // real WETH (params.loanToken)
        market.collateralToken = m.collateralToken; // real wstETH (params.collateralToken)
        // CRITICAL: `activateCollateral` warps by `config.activation.maxActivationDelay`. Take the whole
        // activation config from the live controller — a zeroed delay would mature nothing and break every
        // post-activation borrow.
        market.config.activation = m.activation;
        // Left zeroed on purpose — no helper used here reads them: the proxy-admin / impl handles ForkStack
        // does not expose (controllerProxy, controllerImpl, guardianSignalsProxy, vaultProxy, oracleProxy),
        // `irm`, and every `config` field other than `config.activation`.
    }

    /// @dev The deployed oracle proxy reads the real wstETH rate at full precision.
    function test_oracle_readsRealWstEthRate_atFullPrecision() public view {
        uint256 price = market.oracle.price();

        // The deployed oracle price IS the live wstETH→stETH rate queried at the 1e36 point — full precision.
        assertEq(price, IWstETHReal(WSTETH).getStETHByWstETH(1e36), "oracle price == live wstETH rate @1e36");

        // That 1e36 query is exactly why the oracle avoids `stEthPerToken() * 1e18`: it preserves the
        // low-order bits the naive scaling truncates. So it is at least as large, by under one ULP (1e18).
        uint256 naive = IWstETHReal(WSTETH).stEthPerToken() * 1e18;
        assertGe(price, naive, "1e36 query never below the truncated naive rate");
        assertLt(price - naive, 1e18, "precision gained over the naive rate is under one ULP");
    }

    /// @dev Borrowing against real matured wstETH collateral yields exactly the loan amount sized by the live
    ///      wstETH rate and the market's live LLTV.
    function test_borrowAgainstRealWstEthCollateral() public {
        // Lender supplies real WETH liquidity, gated by the live vault headroom. `deal` mints WETH directly;
        // vaultDeposit approves and deposits, asserting the exact share/totalAssets deltas.
        _requireDepositHeadroom(m, LENDER_DEPOSIT);
        address lender = _freshActor(m, "ethStethFork.lender");
        deal(address(market.loanToken), lender, LENDER_DEPOSIT);
        market.vaultDeposit(lender, LENDER_DEPOSIT);

        // Borrower posts REAL wstETH collateral and matures it. Size the lot off the live dust threshold
        // (`minActivationAmount`) so it clears activation at any deployed configuration.
        address borrower = _freshActor(m, "ethStethFork.borrower");
        uint256 collateral = 2 * uint256(m.activation.minActivationAmount);
        deal(WSTETH, borrower, collateral);
        market.supplyCollateral(borrower, collateral);
        market.activateCollateral();

        // Max borrow is set by the LIVE wstETH rate and the market's live LLTV; borrow half, well clear of the
        // gate. The rate is unchanged by the activation warp (it reads stETH accounting, not the clock).
        uint256 rate = IWstETHReal(WSTETH).getStETHByWstETH(1e36);
        uint256 maxBorrow = collateral * rate / 1e36 * market.params.lltv / 1e18;
        uint256 borrowAmt = maxBorrow / 2;

        // Liquidity precondition (delta, not absolute): the lender's own deposit must cover the borrow, so the
        // scenario holds whatever pre-existing supply the deployed market already carries.
        require(LENDER_DEPOSIT >= borrowAmt, "EthStethFork: lender deposit below borrow amount");

        market.borrow(borrower, borrowAmt);

        assertEq(market.loanToken.balanceOf(borrower), borrowAmt, "borrowed WETH against real wstETH at the live rate");
    }
}
