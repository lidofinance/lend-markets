// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {WstEthRateOracle} from "../../src/oracle/WstEthRateOracle.sol";

import {LidoLendSetup} from "../setup/LidoLendSetup.sol";
import {Market} from "../setup/Types.sol";
import {MarketActions} from "../setup/MarketActions.sol";
import {MockERC20} from "../setup/Mocks.sol";
import {ForkTest} from "./helpers/ForkTest.sol";

interface IWstETHReal {
    function getStETHByWstETH(uint256 wstETHAmount) external view returns (uint256);
    function stEthPerToken() external view returns (uint256);
}

/// @notice L3-style fork scenario for the eth/steth market against the REAL mainnet wstETH (the unit suites
///         cover the same math against mocks). Deploys a fresh protocol on a fork with wstETH collateral
///         priced by the live `WstEthRateOracle`, and borrows against it.
contract EthStethForkTest is LidoLendSetup, ForkTest {
    using MarketActions for Market;

    address internal WSTETH; // from script/config/<NETWORK>.toml
    MockERC20 internal weth;

    function setUp() public {
        _fork();
        WSTETH = _ext("wstEth");
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        _deployProtocol(_defaultConfig(address(weth), WSTETH, WSTETH));
    }

    /// @dev Use the real `WstEthRateOracle` for the wstETH market instead of the seeded mock.
    function _deployOracle(address oracleSource, address admin) internal override returns (address) {
        if (oracleSource == WSTETH) return address(new WstEthRateOracle(WSTETH));
        return super._deployOracle(oracleSource, admin);
    }

    function _m() internal view returns (Market storage) {
        return protocol.markets[0];
    }

    function test_oracle_readsRealWstEthRate_atFullPrecision() public {
        uint256 price = _m().oracle.price();

        // The deployed oracle price IS the live wstETH→stETH rate queried at the 1e36 point — full precision.
        assertEq(price, IWstETHReal(WSTETH).getStETHByWstETH(1e36), "oracle price == live wstETH rate @1e36");

        // That 1e36 query is exactly why the oracle avoids `stEthPerToken() * 1e18`: it preserves the
        // low-order bits the naive scaling truncates. So it is at least as large, by under one ULP (1e18).
        uint256 naive = IWstETHReal(WSTETH).stEthPerToken() * 1e18;
        assertGe(price, naive, "1e36 query never below the truncated naive rate");
        assertLt(price - naive, 1e18, "precision gained over the naive rate is under one ULP");
    }

    /// @dev Borrowing against real matured wstETH collateral yields exactly the loan amount sized by the live
    ///      wstETH rate and the 0.8 LLTV.
    function test_borrowAgainstRealWstEthCollateral() public {
        Market storage m = _m();

        // Lender supplies WETH liquidity.
        address lender = _actor("lender");
        _fund(weth, lender, 1000 ether);
        m.vaultDeposit(lender, 1000 ether);

        // Borrower posts REAL wstETH collateral and matures it.
        address borrower = _actor("borrower");
        deal(WSTETH, borrower, 10 ether);
        m.supplyCollateral(borrower, 10 ether);
        m.activateCollateral();

        // Max borrow is set by the LIVE wstETH rate and the 0.8 LLTV; borrow half of it, well clear of the gate.
        uint256 rate = IWstETHReal(WSTETH).getStETHByWstETH(1e36);
        uint256 maxBorrow = 10 ether * rate / 1e36 * 80 / 100;
        uint256 borrowAmt = maxBorrow / 2;
        m.borrow(borrower, borrowAmt);

        assertEq(weth.balanceOf(borrower), borrowAmt, "borrowed WETH against real wstETH at the live rate");
    }
}
