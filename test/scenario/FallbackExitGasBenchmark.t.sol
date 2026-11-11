// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {console2} from "forge-std/Test.sol";

import {Call} from "@bundler3/src/interfaces/IBundler3.sol";

import {SettlementConfig} from "../../src/types/SettlementTypes.sol";
import {LidoLendDeployer} from "../../script/lib/LidoLendDeployer.sol";
import {BundlerSetup} from "../setup/BundlerSetup.sol";
import {MarketActions} from "../setup/MarketActions.sol";
import {MockPriceOracle} from "../setup/Mocks.sol";
import {Market} from "../setup/Types.sol";

/// @notice Guards the gas envelope of the fallback exit's costliest settlement path: a book where
///         every cut is partial, touches a previously untouched borrower, and re-sorts a queue that
///         keeps all 500 entries. One test asserts the book really produces that path. The other
///         executes the default-bounded exit under the per-transaction gas budget and requires it
///         to fit, with a starved call proving the budget binds.
/// @dev    Setup leaves storage warm, which understates what a real transaction pays; run with
///         --isolate for real-transaction costs. The fit assertion holds in both modes.
contract FallbackExitGasBenchmark is BundlerSetup {
    using MarketActions for Market;

    /// @dev EIP-7825: the most gas a transaction may spend, whatever the block gas limit.
    uint256 internal constant TX_GAS_CAP = 16_777_216;

    address internal lender;

    function setUp() public {
        _deployBundledMarket();
        lender = _actor("lender");
    }

    /// @dev A WETH/wstETH market where the first 100 cuts are each partial, touch a previously
    ///      untouched borrower, and re-sort through a heap that keeps all 500 entries: 500 borrowers
    ///      in a 0.49-point LTV band under a 95% liquidation threshold, so one LTV step drops every
    ///      cut root below all untouched borrowers instead of closing it. The pool is drawn to one
    ///      WETH of idle liquidity so the exit runs the full three-leg bundle.
    function _seedPartialRekeyBook() internal returns (Market storage m, uint256 shares) {
        LidoLendDeployer.DeployConfig memory cfg = _defaultConfig(address(weth), address(wsteth), address(wsteth));
        cfg.lltv = 0.95e18;
        cfg.activation.maxDelayInflow = 1_000_000_000 ether;
        cfg.settlementConfig = SettlementConfig({
            sliceFloorBps: 100, sliceFloorAssets: 10 ether, fullCutBelowCollateral: 10 ether, ltvStepBps: 100
        });
        m = _addMarket(cfg);
        MockPriceOracle(address(m.oracle)).setPrice(1e36);

        uint256 total = 1 ether; // idle for the WETH-transfer leg
        for (uint256 i; i < 500; ++i) {
            total += 94 ether + (i % 50) * 0.01 ether;
        }
        _fund(m.loanToken, lender, total);
        shares = m.vaultDeposit(lender, total);

        for (uint256 i; i < 500; ++i) {
            address b = address(uint160(0x600000 + i));
            _fund(m.collateralToken, b, 100 ether);
            vm.startPrank(b);
            m.collateralToken.approve(address(m.core), 100 ether);
            m.core.supplyCollateral(m.params, 100 ether, b, "");
            vm.stopPrank();
        }
        m.activateCollateral();
        for (uint256 i; i < 500; ++i) {
            address b = address(uint160(0x600000 + i));
            vm.prank(b);
            m.core.borrow(m.params, 94 ether + (i % 50) * 0.01 ether, 0, b, b);
        }

        vm.prank(lender);
        m.vault.approve(address(vaultAdapter), type(uint256).max);
    }

    /// @dev The costliest path, asserted rather than assumed: 100 iterations touch 100 distinct
    ///      borrowers, every cut is partial and exactly one LTV step, and the heap keeps its 500
    ///      entries.
    function test_pathShape_partialRekeyBook() public {
        (Market storage m, uint256 shares) = _seedPartialRekeyBook();
        assertEq(m.controller.settlementBorrowersCount(), 500, "heap holds the book");

        vm.prank(lender);
        m.vault.fallbackExit(shares, lender, lender, 100);

        assertEq(m.controller.settlementBorrowersCount(), 500, "no position closed: heap still 500");
        uint256 touched;
        for (uint256 i; i < 500; ++i) {
            address b = address(uint160(0x600000 + i));
            uint128 bs = m.core.position(m.id, b).borrowShares;
            assertGt(bs, 0, "every cut partial: no borrower closed");
            uint256 debt = uint256(bs) * (m.core.market(m.id).totalBorrowAssets + 1)
                / (m.core.market(m.id).totalBorrowShares + 1e6);
            uint256 col = m.core.position(m.id, b).collateral;
            uint256 ltvBps = debt * 10_000 / col; // price 1e36: value == raw
            if (ltvBps < 9_390) {
                touched++;
                assertGt(ltvBps, 9_280, "touched borrower moved exactly one step");
            } else {
                assertGe(ltvBps, 9_390, "untouched borrower still in the seeded band");
            }
        }
        assertEq(touched, 100, "100 iterations touched 100 distinct borrowers");
    }

    /// @dev The invariant the default is sized for: the default-bounded exit on the costliest path
    ///      fits the execution budget of a transaction at the gas cap. The starved rerun proves the
    ///      budget binds, so the fit assertion cannot pass vacuously.
    function test_gasCapped_partialRekeyBook_defaultBound() public {
        (Market storage m,) = _seedPartialRekeyBook();

        uint256 snap = vm.snapshotState();
        (bool ok, uint256 budget, uint256 used) = _runCappedExit(m, TX_GAS_CAP);
        assertTrue(ok, "the default-bounded worst-path exit fits a capped transaction");
        console2.log("  execBudget", budget, "used", used);
        console2.log("  headroom", budget - used);
        vm.revertToState(snap);

        (bool starved,, uint256 usedStarved) = _runCappedExit(m, 2_000_000 + 21_000);
        assertFalse(starved, "a starved budget fails, so the budget binds");
        console2.log("  starved control used", usedStarved);
    }

    /// @dev One full three-leg exit (settle, unwrap wstETH, forward WETH) at the vault's default
    ///      iteration bound, given the execution budget of a transaction whose gas limit is
    ///      `txGasLimit`: the limit minus 21,000 intrinsic minus its calldata cost.
    function _runCappedExit(Market storage m, uint256 txGasLimit)
        internal
        returns (bool ok, uint256 budget, uint256 used)
    {
        Call[] memory three = new Call[](3);
        three[0] = _call(
            address(vaultAdapter),
            abi.encodeCall(vaultAdapter.fallbackExit, (address(m.vault), type(uint256).max, 0, address(adapter), 0, 1))
        );
        three[1] = _adapterCall(abi.encodeCall(adapter.unwrapStEth, (type(uint256).max, lender)));
        three[2] = _adapterCall(abi.encodeCall(adapter.erc20Transfer, (address(weth), lender, type(uint256).max)));
        bytes memory cd = abi.encodeCall(bundler3.multicall, (three));
        budget = txGasLimit - 21_000 - _calldataGas(cd);

        vm.prank(lender);
        uint256 g0 = gasleft();
        (ok,) = address(bundler3).call{gas: budget}(cd);
        used = g0 - gasleft();
    }

    /// @dev Standard calldata pricing: 4 gas for a zero byte, 16 for any other.
    function _calldataGas(bytes memory data) internal pure returns (uint256 g) {
        for (uint256 i; i < data.length; ++i) {
            g += data[i] == 0 ? 4 : 16;
        }
    }
}
