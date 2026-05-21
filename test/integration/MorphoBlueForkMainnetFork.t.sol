// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.19;

import {MorphoBlueFork} from "../../src/MorphoBlueFork.sol";
import {WstEthRateOracle} from "../../src/oracle/WstEthRateOracle.sol";
import {IMarketController} from "../../src/interfaces/IMarketController.sol";
import {IDeleverageHeap} from "../../src/interfaces/IDeleverageHeap.sol";
import {AdaptiveCurveIrm} from "@morpho-blue-irm/src/adaptive-curve-irm/AdaptiveCurveIrm.sol";
import {Id, MarketParams} from "@morpho-blue/src/interfaces/IMorpho.sol";
import {MarketParamsLib} from "@morpho-blue/src/libraries/MarketParamsLib.sol";
import {Test} from "forge-std/Test.sol";

interface IWETH {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function deposit() external payable;
}

interface IStETH {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function submit(address referral) external payable returns (uint256);
}

interface IWstETH {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function stEthPerToken() external view returns (uint256);
    function wrap(uint256 stETHAmount) external returns (uint256);
}

interface IControllerDeleverageHeapAdmin {
    function CONFIGURATOR_ROLE() external view returns (bytes32);

    function grantRole(bytes32 role, address account) external;

    function setDeleverageHeap(address heap) external;

    function setDeleverageHeapConfig(Id id, IMarketController.DeleverageHeapConfig calldata cfg) external;
}

contract MorphoBlueForkMainnetForkTest is Test {
    using MarketParamsLib for MarketParams;

    // Run with:
    // forge test --match-path test/integration/MorphoBlueForkMainnetFork.t.sol \
    //   --fork-url "$MAINNET_RPC_URL"

    address internal constant WETH_ADDRESS = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant STETH_ADDRESS = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    address internal constant WSTETH_ADDRESS = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;

    IWETH internal constant WETH = IWETH(WETH_ADDRESS);
    IStETH internal constant STETH = IStETH(STETH_ADDRESS);
    IWstETH internal constant WSTETH = IWstETH(WSTETH_ADDRESS);

    address internal constant LENDER = address(0x1000);
    address internal constant BORROWER = address(0x2000);
    address internal constant SECOND_BORROWER = address(0x3000);
    address internal constant DONOR = address(0x4000);
    address internal constant THIRD_BORROWER = address(0x5000);

    uint256 internal constant LLTV = 0.8e18;

    struct TestMarket {
        MorphoBlueFork market;
        IMarketController controller;
        address accessRegistry;
        MarketParams marketParams;
        Id id;
        uint256 price;
    }

    function testHappyPathControllerPromotesDustAndBorrowsAfterMaturityWithRealLidoWstETH() public {
        vm.skip(!_hasMainnetLidoContracts(), "mainnet fork with Lido contracts required");

        TestMarket memory ctx = _deployMarket(false);

        _mintWETH(ctx.market, LENDER, 10 ether);
        uint256 borrowerDust = _mintWstETH(ctx.market, BORROWER, 7 ether);
        uint256 donorTopUp = _mintWstETH(ctx.market, DONOR, 7 ether);
        uint256 activatedCollateral = borrowerDust + donorTopUp;

        vm.prank(LENDER);
        ctx.market.supply(ctx.marketParams, 10 ether, 0, LENDER, "");

        vm.prank(BORROWER);
        ctx.market.supplyCollateral(ctx.marketParams, borrowerDust, BORROWER, "");
        _assertCollateralState(ctx.controller, ctx.id, BORROWER, 0, 0, borrowerDust);

        vm.prank(DONOR);
        ctx.market.supplyCollateral(ctx.marketParams, donorTopUp, BORROWER, "");
        _assertCollateralState(ctx.controller, ctx.id, BORROWER, 0, activatedCollateral, 0);

        vm.warp(block.timestamp + 2 hours + 1);

        vm.prank(BORROWER);
        (uint256 borrowedAssets,) = ctx.market.borrow(ctx.marketParams, 3 ether, 0, BORROWER, BORROWER);

        assertEq(borrowedAssets, 3 ether, "borrowed after maturity");
        assertEq(WETH.balanceOf(BORROWER), 3 ether, "borrower received real WETH");
        _assertCollateralState(ctx.controller, ctx.id, BORROWER, activatedCollateral, 0, 0);
    }

    function testHappyPathControllerFallbackExitWithRealLidoWstETH() public {
        vm.skip(!_hasMainnetLidoContracts(), "mainnet fork with Lido contracts required");

        TestMarket memory ctx = _deployMarket(true);

        _mintWETH(ctx.market, LENDER, 10 ether);
        uint256 borrowerCollateral = _mintWstETH(ctx.market, BORROWER, 20 ether);
        uint256 secondBorrowerCollateral = _mintWstETH(ctx.market, SECOND_BORROWER, 20 ether);

        vm.prank(LENDER);
        ctx.market.supply(ctx.marketParams, 10 ether, 0, LENDER, "");

        vm.prank(BORROWER);
        ctx.market.supplyCollateral(ctx.marketParams, borrowerCollateral, BORROWER, "");
        vm.prank(SECOND_BORROWER);
        ctx.market.supplyCollateral(ctx.marketParams, secondBorrowerCollateral, SECOND_BORROWER, "");

        vm.warp(block.timestamp + 2 hours + 1);

        uint256 borrowerDebt = 7 ether;
        uint256 secondBorrowerDebt = 3 ether;
        assertTrue(borrowerDebt < _maxBorrow(borrowerCollateral, ctx.price), "borrower debt under LLTV");
        assertTrue(secondBorrowerDebt < _maxBorrow(secondBorrowerCollateral, ctx.price), "second debt under LLTV");

        vm.prank(BORROWER);
        ctx.market.borrow(ctx.marketParams, borrowerDebt, 0, BORROWER, BORROWER);
        vm.prank(SECOND_BORROWER);
        ctx.market.borrow(ctx.marketParams, secondBorrowerDebt, 0, SECOND_BORROWER, SECOND_BORROWER);

        _assertCollateralState(ctx.controller, ctx.id, BORROWER, borrowerCollateral, 0, 0);
        _assertCollateralState(ctx.controller, ctx.id, SECOND_BORROWER, secondBorrowerCollateral, 0, 0);

        _fallbackExitAndAssert(ctx, borrowerCollateral);
    }

    /// @notice One scenario exercising the heap-driven deleverage ordering end-to-end.
    /// @dev Covers, in order:
    ///        - three borrowers at different risk levels; heap root tracks the highest-LTV one;
    ///        - a cut targeting the heap root reduces it but does not flip the order;
    ///        - the heap re-sorts after the root borrower partially repays, so a new borrower becomes root;
    ///        - a cut targeting the new root succeeds while the previous root is no longer reached;
    ///        - the lowest-LTV borrower is never touched throughout the scenario.
    function testHeapDeleverageScenarioMultipleBorrowersWithRealLidoWstETH() public {
        vm.skip(!_hasMainnetLidoContracts(), "mainnet fork with Lido contracts required");

        TestMarket memory ctx = _deployMarket(true);

        // Lender saturates the market so every cut below has to go through deleverage and not
        // the ordinary withdraw path.
        _mintWETH(ctx.market, LENDER, 12 ether);
        vm.prank(LENDER);
        ctx.market.supply(ctx.marketParams, 12 ether, 0, LENDER, "");

        uint256 highCol = _mintWstETH(ctx.market, BORROWER, 20 ether);
        uint256 midCol = _mintWstETH(ctx.market, SECOND_BORROWER, 20 ether);
        uint256 lowCol = _mintWstETH(ctx.market, THIRD_BORROWER, 20 ether);
        vm.prank(BORROWER);
        ctx.market.supplyCollateral(ctx.marketParams, highCol, BORROWER, "");
        vm.prank(SECOND_BORROWER);
        ctx.market.supplyCollateral(ctx.marketParams, midCol, SECOND_BORROWER, "");
        vm.prank(THIRD_BORROWER);
        ctx.market.supplyCollateral(ctx.marketParams, lowCol, THIRD_BORROWER, "");

        vm.warp(block.timestamp + 2 hours + 1);

        vm.prank(BORROWER);
        ctx.market.borrow(ctx.marketParams, 6 ether, 0, BORROWER, BORROWER);
        vm.prank(SECOND_BORROWER);
        ctx.market.borrow(ctx.marketParams, 4 ether, 0, SECOND_BORROWER, SECOND_BORROWER);
        vm.prank(THIRD_BORROWER);
        ctx.market.borrow(ctx.marketParams, 2 ether, 0, THIRD_BORROWER, THIRD_BORROWER);

        IDeleverageHeap heap = IDeleverageHeap(IMarketController(address(ctx.controller)).DELEVERAGE_HEAP());

        // (1) Initial heap order: highest-LTV borrower is at the root.
        assertEq(heap.size(), 3, "all three active borrowers tracked");
        (address root,) = heap.peek();
        assertEq(root, BORROWER, "highest-LTV borrower at root");

        // (2) Targeted cut on the heap root reduces it but does not flip the order.
        (uint256 lenderShares,,) = ctx.market.position(ctx.id, LENDER);
        uint256 firstCutShares = lenderShares / 6; // ~2 WETH cut
        vm.prank(LENDER);
        ctx.market.deleverage(ctx.marketParams, firstCutShares, BORROWER, LENDER, LENDER);
        (root,) = heap.peek();
        assertEq(root, BORROWER, "BORROWER still highest after small partial cut");

        // (3) BORROWER partially repays. The heap re-sorts and SECOND_BORROWER becomes root.
        _mintWETH(ctx.market, BORROWER, 3 ether);
        vm.prank(BORROWER);
        ctx.market.repay(ctx.marketParams, 3 ether, 0, BORROWER, "");
        (root,) = heap.peek();
        assertEq(root, SECOND_BORROWER, "heap re-sorts after BORROWER deleverages off-protocol");

        // (4) A cut against the new root succeeds. The cut size must exceed the idle liquidity
        //     left by BORROWER's repay, otherwise core rejects with "ordinary liquidity available".
        (uint256 lenderSharesAfterRepay,,) = ctx.market.position(ctx.id, LENDER);
        uint256 secondCutShares = lenderSharesAfterRepay / 3;
        vm.prank(LENDER);
        ctx.market.deleverage(ctx.marketParams, secondCutShares, SECOND_BORROWER, LENDER, LENDER);

        // (5) THIRD_BORROWER (lowest LTV) has not been touched at any point.
        (, uint128 lowBorrowSharesAfter, uint128 lowCollateralAfter) = ctx.market.position(ctx.id, THIRD_BORROWER);
        assertEq(uint256(lowCollateralAfter), lowCol, "low-LTV borrower's collateral untouched");
        assertGt(lowBorrowSharesAfter, 0, "low-LTV borrower still has debt");
    }

    function _fallbackExitAndAssert(TestMarket memory ctx, uint256 borrowerCollateral) internal {
        (uint256 supplyShares,,) = ctx.market.position(ctx.id, LENDER);
        uint256 sharesToExit = supplyShares / 5;

        vm.prank(LENDER);
        (uint256 collateralSeized, uint256 debtCanceled) =
            ctx.market.deleverage(ctx.marketParams, sharesToExit, BORROWER, LENDER, LENDER);

        uint256 expectedCollateralSeized = debtCanceled * 1e36 / ctx.price;
        assertEq(collateralSeized, expectedCollateralSeized, "oracle-rate collateral");
        assertTrue(debtCanceled > 1.9 ether && debtCanceled <= 2 ether, "debt canceled near 2 WETH");
        assertEq(WSTETH.balanceOf(LENDER), collateralSeized, "lender received real wstETH");

        _assertBorrowerCollateralDebited(ctx, borrowerCollateral, collateralSeized);
    }

    function _hasMainnetLidoContracts() internal view returns (bool) {
        return block.chainid == 1 && WETH_ADDRESS.code.length != 0 && STETH_ADDRESS.code.length != 0
            && WSTETH_ADDRESS.code.length != 0;
    }

    function _maxBorrow(uint256 collateral, uint256 price) internal pure returns (uint256) {
        return (collateral * price / 1e36 * LLTV) / 1e18;
    }

    function _assertBorrowerCollateralDebited(
        TestMarket memory ctx,
        uint256 initialCollateral,
        uint256 collateralSeized
    ) internal view {
        (,, uint128 borrowerRawCollateral) = ctx.market.position(ctx.id, BORROWER);
        assertEq(uint256(borrowerRawCollateral), initialCollateral - collateralSeized, "raw collateral debited");
        _assertCollateralState(ctx.controller, ctx.id, BORROWER, initialCollateral - collateralSeized, 0, 0);
    }

    function _deployMarket(bool deleverageEnabled) internal returns (TestMarket memory ctx) {
        ctx.market = new MorphoBlueFork(address(this));
        WstEthRateOracle oracle = new WstEthRateOracle(WSTETH_ADDRESS);
        AdaptiveCurveIrm irm = new AdaptiveCurveIrm(address(ctx.market));

        ctx.marketParams = MarketParams({
            loanToken: WETH_ADDRESS,
            collateralToken: WSTETH_ADDRESS,
            oracle: address(oracle),
            irm: address(irm),
            lltv: LLTV
        });
        ctx.id = ctx.marketParams.id();
        ctx.price = oracle.price();
        (ctx.controller, ctx.accessRegistry) = _deployController(ctx.market, ctx.id);

        ctx.market.enableIrm(address(irm));
        ctx.market.enableLltv(LLTV);
        ctx.market.createMarket(ctx.marketParams, address(ctx.controller), deleverageEnabled);
    }

    function _mintWETH(MorphoBlueFork market, address user, uint256 amount) internal {
        vm.deal(user, amount);
        vm.prank(user);
        WETH.deposit{value: amount}();
        vm.prank(user);
        WETH.approve(address(market), type(uint256).max);
    }

    function _mintWstETH(MorphoBlueFork market, address user, uint256 ethAmount) internal returns (uint256) {
        vm.deal(user, ethAmount);
        vm.prank(user);
        STETH.submit{value: ethAmount}(address(0));

        uint256 stETHAmount = STETH.balanceOf(user);
        vm.prank(user);
        STETH.approve(WSTETH_ADDRESS, stETHAmount);
        vm.prank(user);
        uint256 wstETHAmount = WSTETH.wrap(stETHAmount);
        vm.prank(user);
        WSTETH.approve(address(market), type(uint256).max);
        return wstETHAmount;
    }

    function _deployController(MorphoBlueFork core, Id id) internal returns (IMarketController, address) {
        address accessRegistry =
            _deployArtifact("MarketAccessRegistry.sol:MarketAccessRegistry", abi.encode(address(this)));
        address implementation = _deployArtifact("LidoMarketController.sol:LidoMarketController", "");
        bytes memory initData = abi.encodeWithSignature(
            "initialize(address,bytes32,address,address)", address(core), Id.unwrap(id), accessRegistry, address(this)
        );
        address proxy =
            _deployArtifact("OssifiableProxy.sol:OssifiableProxy", abi.encode(implementation, address(this), initData));
        IControllerDeleverageHeapAdmin admin = IControllerDeleverageHeapAdmin(proxy);
        admin.grantRole(admin.CONFIGURATOR_ROLE(), address(this));
        address heap = _deployArtifact("DeleverageHeap.sol:DeleverageHeap", abi.encode(proxy));
        admin.setDeleverageHeap(heap);
        return (IMarketController(proxy), accessRegistry);
    }

    function _deployArtifact(string memory artifact, bytes memory args) internal returns (address deployed) {
        bytes memory bytecode = vm.getCode(artifact);
        bytes memory creationCode = bytes.concat(bytecode, args);
        assembly ("memory-safe") {
            deployed := create(0, add(creationCode, 0x20), mload(creationCode))
        }
        require(deployed != address(0) && deployed.code.length != 0, "artifact deploy failed");
    }

    function _assertCollateralState(
        IMarketController controller,
        Id id,
        address borrower,
        uint256 matured,
        uint256 activating,
        uint256 dust
    ) internal view {
        IMarketController.CollateralState memory state = controller.collateralState(id, borrower);
        assertEq(uint256(state.maturedCollateral), matured, "matured collateral");
        assertEq(uint256(state.activatingCollateral), activating, "activating collateral");
        assertEq(uint256(state.dustCollateral), dust, "dust collateral");
    }
}
