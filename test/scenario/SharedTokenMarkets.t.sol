// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Id, Market as MorphoMarket} from "@lido-lend/src/interfaces/IMorpho.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Erc4626Math} from "../setup/Erc4626Math.sol";
import {LidoLendSetup} from "../setup/LidoLendSetup.sol";
import {Market} from "../setup/Types.sol";
import {MarketActions} from "../setup/MarketActions.sol";
import {MockERC20, MockPriceOracle} from "../setup/Mocks.sol";

/// @notice L2 isolation of two markets on one core that share the loan token and the collateral token. The core
///         holds the tokens of both markets in one balance. Bad debt in market A must not move market B's totals,
///         must not stop B's lenders, and must not let the pooled loan balance fall below the free liquidity of both
///         markets.
contract SharedTokenMarketsTest is LidoLendSetup {
    using MarketActions for Market;

    uint256 internal constant DEPOSIT = 1000 ether;
    // 400 collateral backs at most 960 at the highest seeded price, below the 1000 deposit.
    uint256 internal constant COLLAT = 400 ether;

    address internal lenderB;
    address internal borrowerA;
    address internal borrowerB;

    function setUp() public {
        MockERC20 loan = new MockERC20("Loan", "LOAN", 18);
        MockERC20 collateral = new MockERC20("Collateral", "COLL", 18);
        DeployConfig memory cfg = _defaultConfig(address(loan), address(collateral), address(collateral));
        _deployProtocol(cfg);
        // The same config again: each market gets its own oracle, so only the oracle address separates the ids.
        _addMarket(cfg);
        assertEq(address(_a().loanToken), address(_b().loanToken), "setup: shared loan token");
        assertEq(address(_a().collateralToken), address(_b().collateralToken), "setup: shared collateral token");
        assertNotEq(Id.unwrap(_a().id), Id.unwrap(_b().id), "setup: distinct market ids");

        address lenderA = _actor("lenderA");
        lenderB = _actor("lenderB");
        borrowerA = _actor("borrowerA");
        borrowerB = _actor("borrowerB");
        _fund(_a().loanToken, lenderA, DEPOSIT);
        _a().vaultDeposit(lenderA, DEPOSIT);
        _fund(_b().loanToken, lenderB, DEPOSIT);
        _b().vaultDeposit(lenderB, DEPOSIT);

        _fund(_a().collateralToken, borrowerA, COLLAT);
        _a().supplyCollateral(borrowerA, COLLAT);
        _fund(_b().collateralToken, borrowerB, COLLAT);
        _b().supplyCollateral(borrowerB, COLLAT);
        _a().activateCollateral();

        _a().borrow(borrowerA, _capacity(_a()));
        _b().borrow(borrowerB, _capacity(_b()) / 2);
    }

    /// @dev A's bad debt changes no total of B, which shares both tokens with A.
    function test_badDebtInMarketA_leavesMarketBTotalsUnchanged() public {
        MorphoMarket memory before = _b().core.market(_b().id);

        _drainA(2500);

        MorphoMarket memory afterDrain = _b().core.market(_b().id);
        assertEq(afterDrain.totalSupplyAssets, before.totalSupplyAssets, "B supply assets unchanged");
        assertEq(afterDrain.totalSupplyShares, before.totalSupplyShares, "B supply shares unchanged");
        assertEq(afterDrain.totalBorrowAssets, before.totalBorrowAssets, "B borrow assets unchanged");
        assertEq(afterDrain.totalBorrowShares, before.totalBorrowShares, "B borrow shares unchanged");
    }

    /// @dev After A's bad debt, B's borrower repays and B's lender redeems every share for the value it had before.
    function test_badDebtInMarketA_marketBLenderExitsFullValue() public {
        Market storage b = _b();
        uint256 shares = b.vault.balanceOf(lenderB);
        uint256 valueBefore = Erc4626Math.toAssets(b.vault, shares, Math.Rounding.Floor);

        _drainA(2500);
        uint256 debtShares = b.core.position(b.id, borrowerB).borrowShares;
        _fund(b.loanToken, borrowerB, b.repayAssets(debtShares));
        b.repay(borrowerB, debtShares);
        uint256 assets = b.vaultRedeem(lenderB, shares);

        assertEq(assets, valueBefore, "B lender exits at its full value");
        assertEq(b.vault.balanceOf(lenderB), 0, "B lender holds no shares");
    }

    /// @dev For any crash deep enough to leave bad debt in A, the pooled loan balance still covers the free liquidity
    ///      of both markets.
    function testFuzz_badDebtInMarketA_pooledBalanceCoversFreeLiquidity(uint256 crashBps) public {
        // At most 80% of the price: a full seizure then repays less than the debt, so the liquidation leaves bad debt.
        _drainA(bound(crashBps, 100, 8000));

        uint256 freeLiquidity;
        for (uint256 i; i < protocol.markets.length; ++i) {
            Market storage m = protocol.markets[i];
            MorphoMarket memory mkt = m.core.market(m.id);
            freeLiquidity += mkt.totalSupplyAssets - mkt.totalBorrowAssets;
        }
        assertLe(freeLiquidity, _a().loanToken.balanceOf(address(protocol.core)), "pooled balance covers markets");
    }

    function _a() internal view returns (Market storage) {
        return protocol.markets[0];
    }

    function _b() internal view returns (Market storage) {
        return protocol.markets[1];
    }

    /// @dev The controller's borrow capacity of `COLLAT` active collateral at the market's oracle price.
    function _capacity(Market storage m) internal view returns (uint256) {
        return Math.mulDiv(Math.mulDiv(COLLAT, m.oracle.price(), 1e36), m.params.lltv, 1e18);
    }

    /// @dev Crashes A's own oracle to `crashBps` of the seed price and seizes all of A's collateral. The helper
    ///      asserts that bad debt is realized.
    function _drainA(uint256 crashBps) internal {
        MockPriceOracle(address(_a().oracle)).setPrice(oraclePrice * crashBps / 10_000);
        address keeper = _actor("keeper");
        _fund(_a().loanToken, keeper, DEPOSIT);
        _a().liquidateBadDebt(keeper, borrowerA, COLLAT, 0);
        assertEq(_b().oracle.price(), oraclePrice, "B oracle untouched");
    }
}
