// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {ILidoLend} from "@lido-lend/src/interfaces/ILidoLend.sol";
import {Id, MarketParams, Market} from "@lido-lend/src/interfaces/IMorpho.sol";
import {ORACLE_PRICE_SCALE} from "@lido-lend/src/libraries/ConstantsLib.sol";
import {SharesMathLib} from "@lido-lend/src/libraries/SharesMathLib.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Test} from "forge-std/Test.sol";

import {ILidoLendMarketController} from "../../src/interfaces/ILidoLendMarketController.sol";
import {SettlementConfig} from "../../src/types/SettlementTypes.sol";
import {LidoLendDeployer} from "../../script/lib/LidoLendDeployer.sol";

interface IOracle {
    function price() external view returns (uint256);
}

/// @dev Pins a fixed wstETH/WETH price so the math is deterministic and needs no fork.
contract FixedPriceOracle is IOracle {
    uint256 private immutable PRICE;

    constructor(uint256 price_) {
        PRICE = price_;
    }

    function price() external view returns (uint256) {
        return PRICE;
    }
}

contract MockToken is ERC20 {
    constructor(string memory n, string memory s) ERC20(n, s) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Rounding behaviour of the two `settle` anchors on a freshly deployed core driven through the real
///         controller hook. The core's `settle` is dual-anchored: pass `supplyShares` to burn an exact lender
///         cut, or pass `borrowShares` to cancel an exact borrower cut. The derived side always rounds up, so
///         the test asserts which party absorbs that up-rounding in each mode, that collateral is seized at the
///         oracle par, and that a supply-anchored full close trips the debt bound.
contract SettleRoundingTest is Test, LidoLendDeployer {
    uint256 internal constant LLTV = 0.945e18;
    uint256 internal constant PRICE = 1.2e36; // 1.2 WETH per wstETH (ORACLE_PRICE_SCALE = 1e36)

    address internal constant LENDER = address(0x9000);
    address internal constant BORROWER = address(0xB0B);
    address internal constant FILLER = address(0xF111);
    address internal constant RECEIVER = address(0x5EED);

    uint256 internal constant SUPPLY = 133e18; // == total borrows -> ~100% utilization, settle is the only exit
    uint256 internal constant COLLATERAL = 200e18; // value 240 WETH @ 1.2; ample headroom over the debt
    uint256 internal constant BORROW = 113e18;
    // A second borrower carrying part of the book, so closing BORROWER cancels less than the whole pool debt
    // and stays within the lender's settleable supply (the borrow-anchored close rounds the debt up by 1).
    uint256 internal constant FILLER_COLLATERAL = 100e18;
    uint256 internal constant FILLER_BORROW = 20e18;

    MockToken internal loan;
    MockToken internal collateral;
    ILidoLend internal core;
    ILidoLendMarketController internal controller;
    MarketParams internal params;
    Id internal id;

    function setUp() public {
        loan = new MockToken("Wrapped Ether", "WETH");
        collateral = new MockToken("Wrapped stETH", "wstETH");

        address[] memory guardians = new address[](1);
        guardians[0] = address(this);

        Deployed memory d = _deployForkStack(
            DeployConfig({
                admin: address(this),
                loanToken: address(loan),
                collateralToken: address(collateral),
                oracleSource: address(collateral),
                lltv: LLTV,
                enableSettlement: true,
                activation: CollateralActivationConfigParams({
                    minActivationDelay: 10 minutes,
                    maxActivationDelay: 2 hours,
                    delayPerStrike: 2 hours,
                    activatingLockAmount: 0,
                    activatingLockDuration: 0,
                    maxDelayInflow: 100_000 ether,
                    minActivationAmount: 1e18,
                    maxGuardiansQuorumDelay: 0
                }),
                settlementConfig: SettlementConfigParams({
                    sliceFloorBps: 100,
                    sliceFloorAssets: 0,
                    // Above the borrower's post-close collateral remainder, so a full-debt slice strands "dust"
                    // and the queue lifts it to a whole close — letting the borrow-anchored close cancel all debt.
                    fullCutBelowCollateral: 150e18,
                    ltvStepBps: 100
                }),
                guardians: guardians,
                quorum: 1,
                vaultName: "Lido WETH Vault",
                vaultSymbol: "lidoWETH"
            })
        );

        core = ILidoLend(d.core);
        controller = ILidoLendMarketController(d.controllerProxy);
        params = d.params;
        id = d.marketId;

        // Sole lender funds the whole book.
        loan.mint(LENDER, SUPPLY);
        vm.startPrank(LENDER);
        loan.approve(d.core, type(uint256).max);
        core.supply(params, SUPPLY, 0, LENDER, "");
        vm.stopPrank();

        // Borrower posts collateral, waits out activation, then borrows against it.
        collateral.mint(BORROWER, COLLATERAL);
        vm.startPrank(BORROWER);
        collateral.approve(d.core, type(uint256).max);
        core.supplyCollateral(params, COLLATERAL, BORROWER, "");
        vm.stopPrank();

        // A filler borrower carries the rest of the book.
        collateral.mint(FILLER, FILLER_COLLATERAL);
        vm.startPrank(FILLER);
        collateral.approve(d.core, type(uint256).max);
        core.supplyCollateral(params, FILLER_COLLATERAL, FILLER, "");
        vm.stopPrank();

        vm.warp(block.timestamp + 3 hours); // past maxActivationDelay -> collateral active
        vm.prank(BORROWER);
        core.borrow(params, BORROW, 0, BORROWER, BORROWER);
        vm.prank(FILLER);
        core.borrow(params, FILLER_BORROW, 0, FILLER, FILLER);

        // Borrower opts into settlement with a near-zero target LTV, so the allowed slice is the whole
        // debt and a full close is permitted by the queue.
        vm.prank(BORROWER);
        controller.setSettlementLtv(1);

        // Accrue interest so totalBorrow/totalSupply drift off the flat 1:1e6 mint ratio and the
        // share<->asset conversions actually round; realize the drift into storage before the reads.
        vm.warp(block.timestamp + 7 days);
        core.accrueInterest(params);

        (, uint256 sliceAssets) = controller.settlementLtv(BORROWER);
        assertGt(sliceAssets, 0, "borrower is settle-eligible");
    }

    /// @dev Borrow-anchored: passing the borrower's whole `borrowShares` zeroes the position; the lender's
    ///      supply burn is derived and rounded up, so the lender absorbs the rounding.
    function test_borrowAnchored_closesBorrowerToZero_lenderBearsRounding() public {
        Market memory m = core.market(id);
        uint256 borrowShares = core.position(id, BORROWER).borrowShares;
        uint256 lenderBefore = core.position(id, LENDER).supplyShares;

        uint256 expDebt = SharesMathLib.toAssetsUp(borrowShares, m.totalBorrowAssets, m.totalBorrowShares);
        uint256 expSupplyBurn = SharesMathLib.toSharesUp(expDebt, m.totalSupplyAssets, m.totalSupplyShares);
        uint256 expSeized = expDebt * ORACLE_PRICE_SCALE / PRICE;

        vm.prank(LENDER);
        (uint256 seized, uint256 debtCanceled) = core.settle(params, 0, borrowShares, LENDER, BORROWER, RECEIVER);

        assertEq(debtCanceled, expDebt, "debt canceled = borrowShares valued up");
        assertEq(seized, expSeized, "collateral seized at oracle par");
        assertEq(core.position(id, BORROWER).borrowShares, 0, "borrower closed to zero");
        assertEq(lenderBefore - core.position(id, LENDER).supplyShares, expSupplyBurn, "lender supply burn rounded up");
        assertEq(collateral.balanceOf(RECEIVER), expSeized, "receiver got the seized collateral");
        // Settler-adverse: the burned lender shares are worth at least the debt they cancelled.
        assertGe(
            SharesMathLib.toAssetsDown(expSupplyBurn, m.totalSupplyAssets, m.totalSupplyShares),
            debtCanceled,
            "lender gave up supply worth >= debt cancelled"
        );
    }

    /// @dev Supply-anchored: burning an exact lender cut leaves the borrower's debt burn to be derived and
    ///      rounded up, so the borrower absorbs the rounding.
    function test_supplyAnchored_partialCut_borrowerBearsRounding() public {
        Market memory m = core.market(id);
        uint256 borrowBefore = core.position(id, BORROWER).borrowShares;
        uint256 lenderBefore = core.position(id, LENDER).supplyShares;

        uint256 supplyCut = lenderBefore / 3; // partial: cancels ~1/3 of the debt value, well below a full close

        uint256 expDebt = SharesMathLib.toAssetsDown(supplyCut, m.totalSupplyAssets, m.totalSupplyShares);
        uint256 expBorrowBurn = SharesMathLib.toSharesUp(expDebt, m.totalBorrowAssets, m.totalBorrowShares);
        uint256 expSeized = expDebt * ORACLE_PRICE_SCALE / PRICE;

        vm.prank(LENDER);
        (uint256 seized, uint256 debtCanceled) = core.settle(params, supplyCut, 0, LENDER, BORROWER, RECEIVER);

        assertEq(debtCanceled, expDebt, "debt canceled = supplyCut valued down");
        assertEq(seized, expSeized, "collateral seized at oracle par");
        assertEq(lenderBefore - core.position(id, LENDER).supplyShares, supplyCut, "exact lender shares burned");
        assertEq(
            borrowBefore - core.position(id, BORROWER).borrowShares, expBorrowBurn, "borrower debt burn rounded up"
        );
    }

    /// @dev The mirror of the borrow-anchored close: trying the same full close supply-anchored makes the
    ///      derived borrow burn round up past the borrower's last share, which the core rejects.
    function testRevert_supplyAnchored_fullCloseOvershootsDebt() public {
        Market memory m = core.market(id);
        uint256 borrowShares = core.position(id, BORROWER).borrowShares;
        uint256 debtAssets = SharesMathLib.toAssetsUp(borrowShares, m.totalBorrowAssets, m.totalBorrowShares);
        uint256 supplyCut = SharesMathLib.toSharesUp(debtAssets, m.totalSupplyAssets, m.totalSupplyShares);

        vm.prank(LENDER);
        vm.expectRevert(bytes("settlement exceeds debt"));
        core.settle(params, supplyCut, 0, LENDER, BORROWER, RECEIVER);
    }

    // ── Deploy (no fork): everything mocked, core deployed from out/
    // ──────────────────────

    /// @dev Override the deployer's wstETH rate oracle with a fixed-price one.
    function _deployOracle(address, address) internal override returns (address) {
        return address(new FixedPriceOracle(PRICE));
    }

    // forge 1.5 `vm.getCode` only resolves artifacts compiled with the test's own solc version, so it
    // cannot fetch the cross-version IRM (`AdaptiveCurveIrm`). `fs_permissions` allows reading `./out`, so
    // read each artifact's creation bytecode straight from its JSON and deploy via CREATE.
    function _deployOut(string memory file, string memory name, bytes memory args) internal returns (address a) {
        string memory json = vm.readFile(string.concat("out/", file, "/", name, ".json"));
        bytes memory code = bytes.concat(vm.parseJsonBytes(json, ".bytecode.object"), args);
        assembly ("memory-safe") {
            a := create(0, add(code, 0x20), mload(code))
        }
        require(a != address(0) && a.code.length != 0, "SettleRounding: deploy failed");
    }

    /// @dev Deploy the submodule core.
    function _deployCore(address admin) internal override returns (address) {
        address impl = _deployOut("LidoLend.sol", "LidoLend", "");
        bytes memory initData = abi.encodeWithSignature("initialize(address)", admin);
        return _deployOut("OssifiableProxy.sol", "OssifiableProxy", abi.encode(impl, admin, initData));
    }

    function _deployGuardianSignals(address admin, address[] memory guardians, uint256 quorum)
        internal
        override
        returns (address)
    {
        address impl = _deployOut("GuardianSignals.sol", "GuardianSignals", "");
        bytes memory initData =
            abi.encodeWithSignature("initialize(address,address[],uint256)", admin, guardians, quorum);
        return _deployOut("OssifiableProxy.sol", "OssifiableProxy", abi.encode(impl, admin, initData));
    }

    function _deployIrm(address core, address owner) internal override returns (address) {
        return _deployOut("AdaptiveCurveIrm.sol", "AdaptiveCurveIrm", abi.encode(core, owner));
    }

    function _deployController(
        address core_,
        Id marketId,
        address guardianSignals,
        address admin,
        CollateralActivationConfigParams memory activation
    ) internal override returns (address proxy, address impl) {
        impl = _deployOut("LidoLendMarketController.sol", "LidoLendMarketController", abi.encode(core_, marketId));
        bytes memory initData = abi.encodeWithSignature(
            "initialize(address,address,(uint40,uint40,uint128,uint40,uint128,uint40,uint128,uint40))",
            admin,
            guardianSignals,
            activation
        );
        proxy = _deployOut("OssifiableProxy.sol", "OssifiableProxy", abi.encode(impl, admin, initData));
    }

    function _deployVault(
        address core_,
        MarketParams memory params_,
        address controller_,
        address admin,
        string memory name_,
        string memory symbol_
    ) internal override returns (address) {
        address impl = _deployOut("LidoLendERC4626.sol", "LidoLendERC4626", abi.encode(core_));
        bytes memory initData = abi.encodeWithSignature(
            "initialize((address,address,address,address,uint256),address,string,string)",
            params_,
            controller_,
            name_,
            symbol_
        );
        return _deployOut("OssifiableProxy.sol", "OssifiableProxy", abi.encode(impl, admin, initData));
    }
}
