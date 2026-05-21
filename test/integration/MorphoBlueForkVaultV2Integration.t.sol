// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {VaultV2} from "@vault-v2/src/VaultV2.sol";
import {MorphoMarketV1AdapterV2} from "@vault-v2/src/adapters/MorphoMarketV1AdapterV2.sol";
import {
    Id as AdapterId,
    MarketParams as AdapterMarketParams
} from "@vault-v2/lib/morpho-blue/src/interfaces/IMorpho.sol";
import {MarketParamsLib as AdapterMarketParamsLib} from "@vault-v2/lib/morpho-blue/src/libraries/MarketParamsLib.sol";
import {Test} from "forge-std/Test.sol";

struct LidoMarketParams {
    address loanToken;
    address collateralToken;
    address oracle;
    address irm;
    uint256 lltv;
}

interface IERC20Like {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IWETH is IERC20Like {
    function deposit() external payable;
}

interface IStETH is IERC20Like {
    function submit(address referral) external payable returns (uint256);
}

interface IWstETH is IERC20Like {
    function wrap(uint256 stETHAmount) external returns (uint256);
}

interface IMorphoBlueForkLike {
    function enableIrm(address irm) external;
    function enableLltv(uint256 lltv) external;
    function createMarket(LidoMarketParams memory marketParams, address controller, bool deleverageEnabled) external;
    function supply(
        LidoMarketParams memory marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        bytes calldata data
    ) external returns (uint256, uint256);
    function supplyCollateral(
        LidoMarketParams memory marketParams,
        uint256 assets,
        address onBehalf,
        bytes calldata data
    ) external;
    function borrow(
        LidoMarketParams memory marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        address receiver
    ) external returns (uint256, uint256);
    function deleverage(
        LidoMarketParams memory marketParams,
        uint256 supplyShares,
        address borrower,
        address onBehalf,
        address receiver
    ) external returns (uint256, uint256);
    function position(bytes32 id, address user)
        external
        view
        returns (uint256 supplyShares, uint128 borrowShares, uint128 collateral);
}

interface IControllerDeleverageHeapAdmin {
    function CONFIGURATOR_ROLE() external view returns (bytes32);

    function grantRole(bytes32 role, address account) external;

    function setDeleverageHeap(address heap) external;
}

contract MorphoBlueForkVaultV2IntegrationTest is Test {
    using AdapterMarketParamsLib for AdapterMarketParams;

    address internal constant CURATOR = address(0x1001);
    address internal constant ALLOCATOR = address(0x1002);
    address internal constant USER = address(0x1003);
    address internal constant BORROWER = address(0x1004);
    address internal constant SOLVER = address(0x1005);
    address internal constant DIRECT_LENDER = address(0x1006);
    address internal constant LOW_LTV_BORROWER = address(0x1007);

    // Run with:
    // forge test --match-path test/integration/MorphoBlueForkVaultV2Integration.t.sol \
    //   --fork-url "$MAINNET_RPC_URL"

    address internal constant WETH_ADDRESS = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant STETH_ADDRESS = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    address internal constant WSTETH_ADDRESS = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;

    IWETH internal constant WETH = IWETH(WETH_ADDRESS);
    IStETH internal constant STETH = IStETH(STETH_ADDRESS);
    IWstETH internal constant WSTETH = IWstETH(WSTETH_ADDRESS);

    uint256 internal constant LLTV = 0.8e18;
    uint256 internal constant WAD = 1e18;

    struct IntegrationContext {
        IERC20Like loanToken;
        IERC20Like collateralToken;
        IMorphoBlueForkLike market;
        LidoMarketParams lidoParams;
        AdapterMarketParams adapterParams;
        bytes32 marketId;
        VaultV2 vault;
        MorphoMarketV1AdapterV2 adapter;
    }

    function testVaultV2CanAllocateIntoLidoForkAndForceDeallocateIntoDirectMarketPosition() public {
        vm.skip(!_hasMainnetLidoContracts(), "mainnet fork with Lido contracts required");

        IntegrationContext memory ctx = _setupIntegrationContext();
        uint256 directSupplySharesBefore = _seedVaultAndDirectLender(ctx);
        _seedBorrowersAndDrainLiquidity(ctx);

        assertEq(ctx.loanToken.balanceOf(address(ctx.market)), 0, "Lido market fully utilized");

        vm.expectRevert();
        vm.prank(USER);
        ctx.vault.withdraw(10 ether, USER, USER);

        _forceDeallocateVaultUser(ctx);
        _fallbackExitDirectLenderAndAssert(ctx, directSupplySharesBefore);

        (uint256 userDirectSupplySharesAfter,,) = ctx.market.position(ctx.marketId, USER);
        assertTrue(userDirectSupplySharesAfter > 0, "direct market position remains with user");
        assertEq(ctx.vault.balanceOf(USER), 0, "user exited vault shares");
        assertEq(ctx.loanToken.balanceOf(SOLVER), 10 ether, "solver can repay temporary liquidity");
    }

    function _setupIntegrationContext() internal returns (IntegrationContext memory ctx) {
        ctx.loanToken = IERC20Like(WETH_ADDRESS);
        ctx.collateralToken = IERC20Like(WSTETH_ADDRESS);
        address oracle = _deployArtifact("WstEthRateOracle.sol:WstEthRateOracle", abi.encode(WSTETH_ADDRESS));

        ctx.market = _deployMorphoBlueFork();
        address irm = _deployArtifact(
            "lib/morpho-blue-irm/src/adaptive-curve-irm/AdaptiveCurveIrm.sol:AdaptiveCurveIrm",
            abi.encode(address(ctx.market))
        );

        ctx.lidoParams = LidoMarketParams({
            loanToken: WETH_ADDRESS, collateralToken: WSTETH_ADDRESS, oracle: oracle, irm: irm, lltv: LLTV
        });
        ctx.adapterParams = AdapterMarketParams({
            loanToken: WETH_ADDRESS, collateralToken: WSTETH_ADDRESS, oracle: oracle, irm: irm, lltv: LLTV
        });
        ctx.marketId = AdapterId.unwrap(ctx.adapterParams.id());
        address controller = _deployController(address(ctx.market), ctx.marketId);

        ctx.market.enableIrm(irm);
        ctx.market.enableLltv(LLTV);
        ctx.market.createMarket(ctx.lidoParams, controller, true);

        ctx.vault = new VaultV2(address(this), address(ctx.loanToken));
        ctx.adapter = new MorphoMarketV1AdapterV2(address(ctx.vault), address(ctx.market), irm);
        _configureVault(ctx.vault, ctx.adapter, ctx.adapterParams);
    }

    function _seedVaultAndDirectLender(IntegrationContext memory ctx) internal returns (uint256 directSupplyShares) {
        _mintWETH(USER, 10 ether);
        vm.prank(USER);
        ctx.loanToken.approve(address(ctx.vault), type(uint256).max);
        vm.prank(USER);
        uint256 vaultShares = ctx.vault.deposit(10 ether, USER);
        assertTrue(vaultShares > 0, "vault shares minted");

        vm.prank(ALLOCATOR);
        ctx.vault.allocate(address(ctx.adapter), abi.encode(ctx.adapterParams), 10 ether);

        assertEq(ctx.loanToken.balanceOf(address(ctx.vault)), 0, "vault allocated idle assets");
        assertEq(ctx.adapter.expectedSupplyAssets(ctx.marketId), 10 ether, "adapter supplied into Lido fork");

        _mintWETH(DIRECT_LENDER, 5 ether);
        vm.prank(DIRECT_LENDER);
        ctx.loanToken.approve(address(ctx.market), type(uint256).max);
        vm.prank(DIRECT_LENDER);
        ctx.market.supply(ctx.lidoParams, 5 ether, 0, DIRECT_LENDER, "");

        (directSupplyShares,,) = ctx.market.position(ctx.marketId, DIRECT_LENDER);
        assertTrue(directSupplyShares > 0, "direct lender supplied into Lido fork");
    }

    function _seedBorrowersAndDrainLiquidity(IntegrationContext memory ctx) internal {
        uint256 borrowerCollateral = _mintWstETH(BORROWER, 40 ether);
        vm.prank(BORROWER);
        ctx.collateralToken.approve(address(ctx.market), type(uint256).max);
        vm.prank(BORROWER);
        ctx.market.supplyCollateral(ctx.lidoParams, borrowerCollateral, BORROWER, "");

        uint256 lowLtvBorrowerCollateral = _mintWstETH(LOW_LTV_BORROWER, 40 ether);
        vm.prank(LOW_LTV_BORROWER);
        ctx.collateralToken.approve(address(ctx.market), type(uint256).max);
        vm.prank(LOW_LTV_BORROWER);
        ctx.market.supplyCollateral(ctx.lidoParams, lowLtvBorrowerCollateral, LOW_LTV_BORROWER, "");

        vm.warp(block.timestamp + 2 hours + 1);

        uint256 borrowerLoanBefore = ctx.loanToken.balanceOf(BORROWER);
        vm.prank(BORROWER);
        ctx.market.borrow(ctx.lidoParams, 15 ether, 0, BORROWER, BORROWER);
        assertEq(
            ctx.loanToken.balanceOf(BORROWER) - borrowerLoanBefore, 15 ether, "borrower received borrowed liquidity"
        );
    }

    function _forceDeallocateVaultUser(IntegrationContext memory ctx) internal {
        _mintWETH(SOLVER, 10 ether);
        vm.prank(SOLVER);
        ctx.loanToken.approve(address(ctx.market), type(uint256).max);
        vm.prank(SOLVER);
        ctx.market.supply(ctx.lidoParams, 10 ether, 0, USER, "");

        (uint256 userDirectSupplyShares,,) = ctx.market.position(ctx.marketId, USER);
        assertTrue(userDirectSupplyShares > 0, "user got direct Lido market supply shares");

        ctx.vault.forceDeallocate(address(ctx.adapter), abi.encode(ctx.adapterParams), 10 ether, USER);

        assertEq(ctx.adapter.expectedSupplyAssets(ctx.marketId), 0, "adapter deallocated from Lido fork");
        assertEq(ctx.loanToken.balanceOf(address(ctx.vault)), 10 ether, "vault received deallocated assets");

        vm.prank(USER);
        ctx.vault.withdraw(10 ether, SOLVER, USER);
    }

    function _fallbackExitDirectLenderAndAssert(IntegrationContext memory ctx, uint256 supplyShares) internal {
        uint256 directCollateralBefore = ctx.collateralToken.balanceOf(DIRECT_LENDER);
        (,, uint128 borrowerRawCollateralBefore) = ctx.market.position(ctx.marketId, BORROWER);

        vm.prank(DIRECT_LENDER);
        (uint256 collateralSeized, uint256 debtCanceled) =
            ctx.market.deleverage(ctx.lidoParams, supplyShares, BORROWER, DIRECT_LENDER, DIRECT_LENDER);

        (uint256 directSupplySharesAfterFallback,,) = ctx.market.position(ctx.marketId, DIRECT_LENDER);
        (,, uint128 borrowerRawCollateralAfter) = ctx.market.position(ctx.marketId, BORROWER);

        assertEq(directSupplySharesAfterFallback, 0, "direct lender exited via fallback");
        assertTrue(debtCanceled > 4.9 ether && debtCanceled <= 5 ether, "direct lender canceled near 5 WETH debt");
        assertEq(
            ctx.collateralToken.balanceOf(DIRECT_LENDER),
            directCollateralBefore + collateralSeized,
            "direct lender received collateral"
        );
        assertEq(
            uint256(borrowerRawCollateralAfter),
            uint256(borrowerRawCollateralBefore) - collateralSeized,
            "fallback debited borrower collateral"
        );
    }

    function _hasMainnetLidoContracts() internal view returns (bool) {
        return block.chainid == 1 && WETH_ADDRESS.code.length != 0 && STETH_ADDRESS.code.length != 0
            && WSTETH_ADDRESS.code.length != 0;
    }

    function _mintWETH(address user, uint256 amount) internal {
        vm.deal(user, amount);
        vm.prank(user);
        WETH.deposit{value: amount}();
    }

    function _mintWstETH(address user, uint256 ethAmount) internal returns (uint256) {
        vm.deal(user, ethAmount);
        vm.prank(user);
        STETH.submit{value: ethAmount}(address(0));

        uint256 stETHAmount = STETH.balanceOf(user);
        vm.prank(user);
        STETH.approve(WSTETH_ADDRESS, stETHAmount);

        uint256 wstETHBefore = WSTETH.balanceOf(user);
        vm.prank(user);
        WSTETH.wrap(stETHAmount);
        return WSTETH.balanceOf(user) - wstETHBefore;
    }

    function _deployMorphoBlueFork() internal returns (IMorphoBlueForkLike) {
        address deployed = _deployArtifact("MorphoBlueFork.sol:MorphoBlueFork", abi.encode(address(this)));
        return IMorphoBlueForkLike(deployed);
    }

    function _deployController(address market, bytes32 marketId) internal returns (address) {
        address accessRegistry =
            _deployArtifact("MarketAccessRegistry.sol:MarketAccessRegistry", abi.encode(address(this)));
        address implementation = _deployArtifact("LidoMarketController.sol:LidoMarketController", "");
        bytes memory initData = abi.encodeWithSignature(
            "initialize(address,bytes32,address,address)", market, marketId, accessRegistry, address(this)
        );
        address proxy =
            _deployArtifact("OssifiableProxy.sol:OssifiableProxy", abi.encode(implementation, address(this), initData));
        IControllerDeleverageHeapAdmin admin = IControllerDeleverageHeapAdmin(proxy);
        admin.grantRole(admin.CONFIGURATOR_ROLE(), address(this));
        address heap = _deployArtifact("DeleverageHeap.sol:DeleverageHeap", abi.encode(proxy));
        admin.setDeleverageHeap(heap);
        return proxy;
    }

    function _deployArtifact(string memory artifact, bytes memory args) internal returns (address deployed) {
        bytes memory bytecode = vm.getCode(artifact);
        bytes memory creationCode = bytes.concat(bytecode, args);
        assembly ("memory-safe") {
            deployed := create(0, add(creationCode, 0x20), mload(creationCode))
        }
        require(deployed != address(0) && deployed.code.length != 0, "artifact deploy failed");
    }

    function _configureVault(VaultV2 vault, MorphoMarketV1AdapterV2 adapter, AdapterMarketParams memory marketParams)
        internal
    {
        vault.setCurator(CURATOR);

        _executeTimelocked(vault, abi.encodeCall(vault.setIsAllocator, (ALLOCATOR, true)));
        _executeTimelocked(vault, abi.encodeCall(vault.addAdapter, (address(adapter))));

        _enableCap(vault, abi.encode("this", address(adapter)));
        _enableCap(vault, abi.encode("collateralToken", marketParams.collateralToken));
        _enableCap(vault, abi.encode("this/marketParams", address(adapter), marketParams));
    }

    function _enableCap(VaultV2 vault, bytes memory idData) internal {
        _executeTimelocked(vault, abi.encodeCall(vault.increaseAbsoluteCap, (idData, type(uint128).max)));
        _executeTimelocked(vault, abi.encodeCall(vault.increaseRelativeCap, (idData, WAD)));
    }

    function _executeTimelocked(VaultV2 vault, bytes memory data) internal {
        vm.prank(CURATOR);
        vault.submit(data);
        (bool success, bytes memory returnData) = address(vault).call(data);
        if (!success) {
            assembly ("memory-safe") {
                revert(add(returnData, 0x20), mload(returnData))
            }
        }
    }
}
