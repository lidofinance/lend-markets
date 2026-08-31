// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {console2} from "forge-std/Test.sol";

import {Call} from "@bundler3/src/interfaces/IBundler3.sol";

import {SettlementConfig} from "../../src/types/SettlementTypes.sol";
import {LidoLendDeployer} from "../../script/lib/LidoLendDeployer.sol";
import {BundlerSetup} from "../setup/BundlerSetup.sol";
import {MarketActions} from "../setup/MarketActions.sol";
import {MockERC20, MockPriceOracle} from "../setup/Mocks.sol";
import {Market} from "../setup/Types.sol";

/// @notice Measures what a fallback exit costs. The settlement loop is measured against the
///         iteration bound, along with the storage each iteration touches. The cost around the loop,
///         which one transaction pays once whatever the bound, is measured on the bundler path a
///         lender sends.
/// @dev    The two measurements need different markets. The loop runs on a mock-token market whose
///         inflow cap admits hundreds of borrowers. The cost around it is measured on the
///         WETH/wstETH market the bundler stack is deployed against.
contract FallbackExitGasBenchmark is BundlerSetup {
    using MarketActions for Market;

    /// @dev Oracle price held fixed on the loop market. A seeded price would move the gas numbers
    ///      between runs.
    uint256 internal constant PRICE = 1.2e36;

    uint256 internal constant COL_EACH = 100 ether;

    /// @dev Debt per borrower. At the fixed price this is 42% of the collateral value, under the
    ///      market's 80% liquidation threshold, so seeding a borrower never reverts.
    uint256 internal constant DEBT_EACH = 50 ether;

    uint256 internal constant BUNDLE_COLLATERAL = 100 ether;

    /// @dev Loan tokens left unborrowed on the bundle market, so the exit pays out through both legs.
    uint256 internal constant BUNDLE_IDLE = 1 ether;

    address internal lender;
    address internal borrower;

    function setUp() public {
        _deployBundledMarket();

        MockERC20 loan = new MockERC20("Loan", "LOAN", 18);
        MockERC20 collateral = new MockERC20("Collateral", "COLL", 18);
        LidoLendDeployer.DeployConfig memory cfg =
            _defaultConfig(address(loan), address(collateral), address(collateral));
        // The default cap would throttle collateral supplied by hundreds of borrowers in one window.
        cfg.activation.maxDelayInflow = 100_000_000 ether;
        _addMarket(cfg);
        MockPriceOracle(address(_loopMarket().oracle)).setPrice(PRICE);

        lender = _actor("lender");
        borrower = _actor("borrower");
    }

    /// @dev Mock-token market the settlement loop is measured on.
    function _loopMarket() internal view returns (Market storage) {
        return protocol.markets[1];
    }

    /// @dev WETH/wstETH market the bundler stack is deployed against.
    function _bundleMarket() internal view returns (Market storage) {
        return protocol.markets[0];
    }

    // ---
    // THE SETTLEMENT LOOP
    // ---

    /// @dev Sizes a cut as a fraction of the root's debt and switches the other two slice rules off,
    ///      so an iteration cuts a known amount.
    /// @param sliceFloorBps Fraction of the root's debt one cut takes, in basis points.
    /// @param fullCutBelowCollateral Collateral remainder under which a cut takes the whole position.
    function _setSlice(uint16 sliceFloorBps, uint96 fullCutBelowCollateral) internal {
        Market storage m = _loopMarket();
        SettlementConfig memory c = m.controller.settlementConfig();
        c.sliceFloorBps = sliceFloorBps;
        c.sliceFloorAssets = 0;
        c.ltvStepBps = 0;
        c.fullCutBelowCollateral = fullCutBelowCollateral;
        m.controller.setSettlementConfig(c);
    }

    /// @dev Seeds `n` borrowers and a lender whose deposit exactly covers what they borrow, so the
    ///      market ends with no free liquidity and an exit goes straight to settlement.
    function _seedBorrowers(uint256 n) internal returns (uint256 shares) {
        Market storage m = _loopMarket();
        _fund(m.loanToken, lender, DEBT_EACH * n);
        shares = m.vaultDeposit(lender, DEBT_EACH * n);

        for (uint256 i; i < n; ++i) {
            address b = address(uint160(0x100000 + i));
            _fund(m.collateralToken, b, COL_EACH);
            vm.startPrank(b);
            m.collateralToken.approve(address(m.core), COL_EACH);
            m.core.supplyCollateral(m.params, COL_EACH, b, "");
            vm.stopPrank();
        }
        m.activateCollateral();
        for (uint256 i; i < n; ++i) {
            address b = address(uint160(0x100000 + i));
            vm.prank(b);
            m.core.borrow(m.params, DEBT_EACH, 0, b, b);
        }
    }

    /// @dev Measures the gas the vault call itself consumes. Refunds are applied at the end of a
    ///      transaction, so this is the figure that has to fit under the per-transaction cap.
    function _measure(uint256 maxIterations, uint256 shares)
        internal
        returns (uint256 gasUsed, uint256 burned, uint256 debt)
    {
        Market storage m = _loopMarket();
        vm.prank(lender);
        uint256 g0 = gasleft();
        (uint256 sb,,, uint256 dc) = m.vault.fallbackExit(shares, lender, lender, maxIterations);
        gasUsed = g0 - gasleft();
        burned = sb;
        debt = dc;
    }

    function _sweep(string memory label, uint256 shares) internal {
        console2.log(label);
        uint256[9] memory bounds = [uint256(1), 2, 5, 10, 25, 50, 100, 150, 300];
        for (uint256 j; j < bounds.length; ++j) {
            uint256 snap = vm.snapshotState();
            (uint256 g, uint256 burned, uint256 debt) = _measure(bounds[j], shares);
            console2.log("  maxIterations", bounds[j], "gas", g);
            console2.log("      sharesBurned", burned, "debtCanceled", debt);
            vm.revertToState(snap);
        }
    }

    /// @dev A cut takes the root's whole debt, which closes the position and removes it from the
    ///      queue. The next iteration then reads a borrower nothing has touched yet, and the queue
    ///      re-sorts over a long tail.
    function test_gas_fullCloseEachIteration() public {
        uint256 shares = _seedBorrowers(320);
        _setSlice(10_000, 0);
        _sweep("=== gas: a cut closes the root, queue of 320 ===", shares);
    }

    /// @dev Cuts are small enough that the root keeps its place, so an iteration rewrites storage
    ///      the same call has already written.
    function test_gas_smallCutEachIteration() public {
        uint256 shares = _seedBorrowers(40);
        _setSlice(1, 0);
        _sweep("=== gas: a cut leaves the root in place, queue of 40 ===", shares);
    }

    /// @dev How many iterations a full exit needs under the slice policy the deployed market uses.
    ///      A price drop pushes one borrower past the liquidation threshold, and the lender exits
    ///      the whole pool against it.
    function test_iterationsNeededForFullExit_deployedSlicePolicy() public {
        Market storage m = _loopMarket();
        address b = address(uint160(0x200000));
        _fund(m.loanToken, lender, 100 ether);
        uint256 shares = m.vaultDeposit(lender, 100 ether);
        _fund(m.collateralToken, b, 1_000 ether);
        vm.startPrank(b);
        m.collateralToken.approve(address(m.core), 1_000 ether);
        m.core.supplyCollateral(m.params, 1_000 ether, b, "");
        vm.stopPrank();
        m.activateCollateral();
        vm.prank(b);
        m.core.borrow(m.params, 100 ether, 0, b, b);
        // 1000 collateral is worth 110 against 100 of debt, an LTV of 91% against a threshold of 80%.
        MockPriceOracle(address(m.oracle)).setPrice(0.11e36);
        m.core.accrueInterest(m.params);

        console2.log("=== iterations a full exit needs, one borrower past the threshold ===");
        uint256[8] memory bounds = [uint256(25), 50, 60, 70, 80, 90, 100, 150];
        for (uint256 j; j < bounds.length; ++j) {
            uint256 snap = vm.snapshotState();
            (uint256 g, uint256 burned,) = _measure(bounds[j], shares);
            console2.log("  maxIterations", bounds[j], "gas", g);
            console2.log("      sharesBurned", burned, "of", shares);
            console2.log("      fullyExited", burned == shares ? 1 : 0);
            vm.revertToState(snap);
        }
    }

    // ---
    // STORAGE THE LOOP TOUCHES
    // ---

    struct Acc {
        uint256 reads; // storage reads, repeats included
        uint256 writes; // storage writes, repeats included
        uint256 distinctSlots; // slots written at least once
    }

    /// @dev The contracts an exit can write storage on.
    function _accounts() internal view returns (address[] memory a) {
        Market storage m = _loopMarket();
        a = new address[](5);
        a[0] = address(m.core);
        a[1] = address(m.controller);
        a[2] = address(m.vault);
        a[3] = address(m.loanToken);
        a[4] = address(m.collateralToken);
    }

    /// @dev Counts storage access over one exit. Distinct slots are counted apart from writes
    ///      because a repricing that charges for changing a slot charges once per slot, however
    ///      many times the call writes it.
    function _countAccesses(uint256 maxIterations, uint256 shares) internal returns (Acc memory acc) {
        Market storage m = _loopMarket();
        address[] memory accounts = _accounts();
        vm.record();
        vm.prank(lender);
        m.vault.fallbackExit(shares, lender, lender, maxIterations);

        for (uint256 i; i < accounts.length; ++i) {
            (bytes32[] memory r, bytes32[] memory w) = vm.accesses(accounts[i]);
            acc.reads += r.length;
            acc.writes += w.length;
            for (uint256 j; j < w.length; ++j) {
                bool seen;
                for (uint256 k; k < j; ++k) {
                    if (w[k] == w[j]) {
                        seen = true;
                        break;
                    }
                }
                if (!seen) acc.distinctSlots++;
            }
        }
    }

    /// @dev Reports storage per iteration as the difference between two bounds, so the fixed cost
    ///      of the call drops out.
    function _reportFootprint(string memory label, uint256 shares) internal {
        uint256 snap = vm.snapshotState();
        Acc memory low = _countAccesses(50, shares);
        vm.revertToState(snap);
        snap = vm.snapshotState();
        Acc memory high = _countAccesses(150, shares);
        vm.revertToState(snap);

        console2.log(label);
        console2.log("  at 50   reads", low.reads, "writes", low.writes);
        console2.log("          distinctSlots", low.distinctSlots);
        console2.log("  at 150  reads", high.reads, "writes", high.writes);
        console2.log("          distinctSlots", high.distinctSlots);
        console2.log("  per iteration, reads", (high.reads - low.reads) / 100);
        console2.log("  per iteration, writes", (high.writes - low.writes) / 100);
        console2.log("  per iteration, distinctSlots", (high.distinctSlots - low.distinctSlots) / 100);
    }

    function test_storageFootprint_fullCloseEachIteration() public {
        uint256 shares = _seedBorrowers(320);
        _setSlice(10_000, 0);
        _reportFootprint("=== storage: a cut closes the root ===", shares);
    }

    function test_storageFootprint_smallCutEachIteration() public {
        uint256 shares = _seedBorrowers(40);
        _setSlice(1, 0);
        _reportFootprint("=== storage: a cut leaves the root in place ===", shares);
    }

    struct SlotDelta {
        uint256 created; // zero before the call, set after: this is what a state-growth charge hits
        uint256 modified; // already set before the call, still set after
        uint256 cleared; // set before the call, zero after
        uint256 untouched; // written back to the value it already held
    }

    /// @dev Splits the slots one exit writes by what the write does to them. A state-growth charge
    ///      applies only where a slot goes from zero to set, so the split decides whether such a
    ///      charge scales with the iteration bound or is paid once.
    function _classifySlots(uint256 maxIterations, uint256 shares) internal returns (SlotDelta memory d) {
        Market storage m = _loopMarket();
        address[] memory accounts = _accounts();

        address[] memory slotOwner = new address[](8192);
        bytes32[] memory slotKey = new bytes32[](8192);
        bytes32[] memory after_ = new bytes32[](8192);
        uint256 n;

        uint256 snap = vm.snapshotState();

        vm.record();
        vm.prank(lender);
        m.vault.fallbackExit(shares, lender, lender, maxIterations);

        for (uint256 i; i < accounts.length; ++i) {
            (, bytes32[] memory w) = vm.accesses(accounts[i]);
            for (uint256 j; j < w.length; ++j) {
                bool seen;
                for (uint256 k; k < n; ++k) {
                    if (slotOwner[k] == accounts[i] && slotKey[k] == w[j]) {
                        seen = true;
                        break;
                    }
                }
                if (seen) continue;
                slotOwner[n] = accounts[i];
                slotKey[n] = w[j];
                after_[n] = vm.load(accounts[i], w[j]);
                ++n;
            }
        }

        vm.revertToState(snap);

        for (uint256 k; k < n; ++k) {
            bytes32 before = vm.load(slotOwner[k], slotKey[k]);
            if (before == after_[k]) d.untouched++;
            else if (before == bytes32(0)) d.created++;
            else if (after_[k] == bytes32(0)) d.cleared++;
            else d.modified++;
        }
    }

    /// @dev Reports the slot split at two bounds, so a reader can see which counts grow with the
    ///      bound and which are fixed for the call.
    function _reportSlots(string memory label, uint256 shares) internal {
        SlotDelta memory low = _classifySlots(50, shares);
        SlotDelta memory high = _classifySlots(150, shares);

        console2.log(label);
        console2.log("  at 50   created", low.created, "modified", low.modified);
        console2.log("          cleared", low.cleared, "untouched", low.untouched);
        console2.log("  at 150  created", high.created, "modified", high.modified);
        console2.log("          cleared", high.cleared, "untouched", high.untouched);
        console2.log("  per iteration, created", (high.created - low.created) / 100);
        console2.log("  per iteration, modified", (high.modified - low.modified) / 100);
        console2.log("  per iteration, cleared", (high.cleared - low.cleared) / 100);
    }

    function test_slotGrowth_fullCloseEachIteration() public {
        uint256 shares = _seedBorrowers(320);
        _setSlice(10_000, 0);
        _reportSlots("=== slot growth: a cut closes the root ===", shares);
    }

    function test_slotGrowth_smallCutEachIteration() public {
        uint256 shares = _seedBorrowers(40);
        _setSlice(1, 0);
        _reportSlots("=== slot growth: a cut leaves the root in place ===", shares);
    }

    // ---
    // THE REST OF THE TRANSACTION
    // ---

    /// @dev Drains the bundle market so an exit has to settle. The borrower takes everything the
    ///      lender supplied except the idle remainder, and accepts settlement down to a low LTV.
    function _seedBundleMarket() internal returns (uint256 shares) {
        Market storage m = _bundleMarket();
        uint256 borrowAmount = (BUNDLE_COLLATERAL * oraclePrice) / 1e36 / 2;

        _fund(m.loanToken, lender, borrowAmount + BUNDLE_IDLE);
        shares = m.vaultDeposit(lender, borrowAmount + BUNDLE_IDLE);
        _fund(m.collateralToken, borrower, BUNDLE_COLLATERAL);
        m.supplyCollateral(borrower, BUNDLE_COLLATERAL);
        m.activateCollateral();
        m.borrow(borrower, borrowAmount);
        m.setSettlementLtv(borrower, 0.25e18);

        vm.prank(lender);
        m.vault.approve(address(vaultAdapter), type(uint256).max);
    }

    /// @dev Standard calldata pricing: 4 gas for a zero byte, 16 for any other.
    function _calldataGas(bytes memory data) internal pure returns (uint256 g) {
        for (uint256 i; i < data.length; ++i) {
            g += data[i] == 0 ? 4 : 16;
        }
    }

    /// @dev What a lender pays beyond the loop. The bare vault call is the baseline; one bundled call
    ///      adds the dispatcher and the adapter; three add the calls that convert the payout, which is
    ///      the exit a lender sends.
    function test_gas_directVersusBundled() public {
        Market storage m = _bundleMarket();
        uint256 shares = _seedBundleMarket();

        uint256 snap = vm.snapshotState();
        vm.prank(lender);
        uint256 g0 = gasleft();
        m.vault.fallbackExit(shares, lender, lender, 0);
        uint256 direct = g0 - gasleft();
        vm.revertToState(snap);

        // The dispatcher hop and the adapter, with the payout going straight to the lender.
        Call[] memory one = new Call[](1);
        one[0] = _call(
            address(vaultAdapter),
            abi.encodeCall(vaultAdapter.fallbackExit, (address(m.vault), type(uint256).max, 0, lender, 0, 1))
        );
        snap = vm.snapshotState();
        vm.prank(lender);
        g0 = gasleft();
        bundler3.multicall(one);
        uint256 bundledOneCall = g0 - gasleft();
        uint256 oneCallCalldata = _calldataGas(abi.encodeCall(bundler3.multicall, (one)));
        vm.revertToState(snap);

        // The exit a lender actually sends: the payout lands on the adapter, which unwraps the seized
        // collateral to stETH and forwards the loan token.
        Call[] memory three = new Call[](3);
        three[0] = _call(
            address(vaultAdapter),
            abi.encodeCall(
                vaultAdapter.fallbackExit,
                (address(m.vault), type(uint256).max, 0, address(adapter), BUNDLE_IDLE + 1, 1)
            )
        );
        three[1] = _adapterCall(abi.encodeCall(adapter.unwrapStEth, (type(uint256).max, lender)));
        three[2] = _adapterCall(abi.encodeCall(adapter.erc20Transfer, (address(weth), lender, type(uint256).max)));
        snap = vm.snapshotState();
        vm.prank(lender);
        g0 = gasleft();
        bundler3.multicall(three);
        uint256 bundledThreeCalls = g0 - gasleft();
        uint256 threeCallCalldata = _calldataGas(abi.encodeCall(bundler3.multicall, (three)));
        vm.revertToState(snap);

        console2.log("=== fixed cost around the loop, one settlement cut ===");
        console2.log("  vault call, no bundler          ", direct);
        console2.log("  through bundler3, 1 call        ", bundledOneCall);
        console2.log("    dispatcher + adapter overhead ", bundledOneCall - direct);
        console2.log("    its calldata gas              ", oneCallCalldata);
        console2.log("  through bundler3, 3 calls       ", bundledThreeCalls);
        console2.log("    over the bare vault call      ", bundledThreeCalls - direct);
        console2.log("    its calldata gas              ", threeCallCalldata);
    }

    // ---
    // 500-BORROWER SIZING (target market size)
    // ---

    /// @dev Sweep over the bounds that matter for sizing the default near the gas cap.
    function _sweepFine(string memory label, uint256 shares) internal {
        console2.log(label);
        uint256[8] memory bounds = [uint256(100), 120, 140, 145, 148, 150, 155, 160];
        for (uint256 j; j < bounds.length; ++j) {
            uint256 snap = vm.snapshotState();
            (uint256 g, uint256 burned, uint256 debt) = _measure(bounds[j], shares);
            console2.log("  maxIterations", bounds[j], "gas", g);
            console2.log("      sharesBurned", burned, "debtCanceled", debt);
            vm.revertToState(snap);
        }
    }

    /// @dev Worst per-cut shape at the target queue depth: every cut closes the root and pops it.
    function test_gas_fullCloseEachIteration_queue500() public {
        uint256 shares = _seedBorrowers(500);
        _setSlice(10_000, 0);
        _sweepFine("=== gas: a cut closes the root, queue of 500 ===", shares);
    }

    function test_storageFootprint_fullClose_queue500() public {
        uint256 shares = _seedBorrowers(500);
        _setSlice(10_000, 0);
        _reportFootprint("=== storage: closes-root, queue of 500 ===", shares);
    }

    function test_slotGrowth_fullClose_queue500() public {
        uint256 shares = _seedBorrowers(500);
        _setSlice(10_000, 0);
        _reportSlots("=== slot growth: closes-root, queue of 500 ===", shares);
    }

    /// @dev Adversarial 500-borrower book under the deployed slice policy: 20 whales that need a
    ///      long LTV walk plus a 480-position dust tail padding the queue, all at 90% LTV with tied
    ///      risk keys after a price drop. The pool is fully drawn, so an exit settles from the
    ///      first cut.
    function _seedAdversarialMix() internal returns (uint256 shares) {
        Market storage m = _loopMarket();
        uint256 total = 20 * 450 ether + 480 * 9 ether;
        _fund(m.loanToken, lender, total);
        shares = m.vaultDeposit(lender, total);

        for (uint256 i; i < 20; ++i) {
            address b = address(uint160(0x400000 + i));
            _fund(m.collateralToken, b, 500 ether);
            vm.startPrank(b);
            m.collateralToken.approve(address(m.core), 500 ether);
            m.core.supplyCollateral(m.params, 500 ether, b, "");
            vm.stopPrank();
        }
        for (uint256 i; i < 480; ++i) {
            address b = address(uint160(0x500000 + i));
            _fund(m.collateralToken, b, 10 ether);
            vm.startPrank(b);
            m.collateralToken.approve(address(m.core), 10 ether);
            m.core.supplyCollateral(m.params, 10 ether, b, "");
            vm.stopPrank();
        }
        m.activateCollateral();
        for (uint256 i; i < 20; ++i) {
            address b = address(uint160(0x400000 + i));
            vm.prank(b);
            m.core.borrow(m.params, 450 ether, 0, b, b);
        }
        for (uint256 i; i < 480; ++i) {
            address b = address(uint160(0x500000 + i));
            vm.prank(b);
            m.core.borrow(m.params, 9 ether, 0, b, b);
        }
        // 1.2 -> 1.0 raises every LTV from 75% to 90%; positions stay solvent (value > debt).
        MockPriceOracle(address(m.oracle)).setPrice(1e36);
    }

    function test_gas_adversarialMix500() public {
        uint256 shares = _seedAdversarialMix();
        _sweepFine("=== gas: adversarial mix, queue of 500, deployed policy ===", shares);
    }

    function test_slotGrowth_adversarialMix500() public {
        uint256 shares = _seedAdversarialMix();
        _reportSlots("=== slot growth: adversarial mix, queue of 500 ===", shares);
    }

    /// @dev Every bound in [50, 150] on one seeded book, one line per bound. Verifies the cost is
    ///      linear in the bound (no drift as the queue shrinks) and locates cap crossings exactly.
    function _denseSweep(string memory label, uint256 shares) internal {
        console2.log(label);
        for (uint256 k = 50; k <= 150; ++k) {
            uint256 snap = vm.snapshotState();
            (uint256 g,,) = _measure(k, shares);
            console2.log(k, g);
            vm.revertToState(snap);
        }
    }

    function test_gas_denseSweep_adversarialMix500() public {
        uint256 shares = _seedAdversarialMix();
        _denseSweep("=== dense 50..150: adversarial mix, queue of 500 ===", shares);
    }

    function test_gas_denseSweep_fullClose_queue500() public {
        uint256 shares = _seedBorrowers(500);
        _setSlice(10_000, 0);
        _denseSweep("=== dense 50..150: closes-root, queue of 500 ===", shares);
    }

    /// @dev Executes the exit under the exact budget a capped transaction has — 16,777,216 minus
    ///      intrinsic and calldata — so the EVM, not arithmetic, decides whether it fits today. The
    ///      4M control proves the budget is enforced: 150 cuts cannot run on 4M and must fail.
    function test_capEnforcedExecution_adversarialMix500() public {
        uint256 shares = _seedAdversarialMix();
        Market storage m = _loopMarket();
        vm.prank(lender);
        m.vault.approve(address(vaultAdapter), type(uint256).max);

        console2.log("=== executed under the EIP-7825 budget, current EVM ===");
        uint256[4] memory bounds = [uint256(100), 140, 148, 150];
        for (uint256 j; j < bounds.length; ++j) {
            uint256 snap = vm.snapshotState();
            (bool ok, uint256 budget, uint256 used) = _runCapped(m, shares, bounds[j], 16_777_216);
            assertTrue(ok, "must fit the cap on the current EVM");
            console2.log("  maxIterations", bounds[j], "ok", ok);
            console2.log("      execBudget", budget, "used", used);
            vm.revertToState(snap);
        }

        uint256 snap2 = vm.snapshotState();
        (bool okControl,, uint256 usedControl) = _runCapped(m, shares, 150, 4_000_000 + 21_000);
        assertFalse(okControl, "control: 150 cuts cannot run on a 4M budget");
        console2.log("  control 4M budget at 150: ok", okControl, "used", usedControl);
        vm.revertToState(snap2);
    }

    /// @dev One bundled exit through the dispatcher with the execution budget of a transaction whose
    ///      gas limit is `txGasLimit`: the limit minus 21,000 intrinsic minus its calldata cost.
    function _runCapped(Market storage m, uint256 shares, uint256 maxIterations, uint256 txGasLimit)
        internal
        returns (bool ok, uint256 budget, uint256 used)
    {
        Call[] memory one = new Call[](1);
        one[0] = _call(
            address(vaultAdapter),
            abi.encodeCall(vaultAdapter.fallbackExit, (address(m.vault), shares, maxIterations, lender, 0, 1))
        );
        bytes memory cd = abi.encodeCall(bundler3.multicall, (one));
        budget = txGasLimit - 21_000 - _calldataGas(cd);

        vm.prank(lender);
        uint256 g0 = gasleft();
        (ok,) = address(bundler3).call{gas: budget}(cd);
        used = g0 - gasleft();
    }
}
