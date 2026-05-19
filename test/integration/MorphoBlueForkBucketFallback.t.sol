// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.19;

import {MorphoBlueFork} from "../../src/MorphoBlueFork.sol";
import {IMarketController} from "../../src/interfaces/IMarketController.sol";
import {IDeleverageCandidatesRegistry} from "../../src/interfaces/IDeleverageCandidatesRegistry.sol";
import {Id, MarketParams} from "@morpho-blue/src/interfaces/IMorpho.sol";
import {ERC20Mock} from "@morpho-blue/src/mocks/ERC20Mock.sol";
import {OracleMock} from "@morpho-blue/src/mocks/OracleMock.sol";
import {MarketParamsLib} from "@morpho-blue/src/libraries/MarketParamsLib.sol";
import {Test} from "forge-std/Test.sol";

interface IControllerBucketPreview is IMarketController {
    function CONFIGURATOR_ROLE() external view returns (bytes32);

    function grantRole(bytes32 role, address account) external;

    function setDeleverageCandidatesRegistry(address registry) external;

    function setMarketConfig(Id id, IMarketController.MarketConfig calldata cfg) external;

    function defaultMarketConfig() external pure returns (IMarketController.MarketConfig memory);

    function previewDeleverageBucket(Id id, address borrower)
        external
        view
        returns (
            uint256 riskWad,
            uint16 bucket,
            bool eligible,
            uint256 maxDebtAssetsToCancel,
            uint256 maxCollateralToSeize
        );
}

interface IFallbackExitVault {
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);

    function fallbackExit(uint256 shares, address receiver, address owner, uint256 minCollateralOut)
        external
        returns (uint256 loanAssets, uint256 collateralSeized, uint256 debtCanceled);

    function balanceOf(address account) external view returns (uint256);
}

contract MorphoBlueForkBucketFallbackTest is Test {
    using MarketParamsLib for MarketParams;

    address internal constant LENDER = address(0xA11CE);
    address internal constant BORROWER = address(0xB0B);
    address internal constant OPT_IN_BORROWER = address(0xCAFE);
    address internal constant LOW_RISK_BORROWER = address(0xBEEF);

    uint256 internal constant LLTV = 0.8e18;
    uint256 internal constant ORACLE_PRICE = 1e36;

    function testFallbackUsesControllerRiskBucketPolicy() public {
        ERC20Mock loanToken = new ERC20Mock();
        ERC20Mock collateralToken = new ERC20Mock();
        OracleMock oracle = new OracleMock();
        oracle.setPrice(ORACLE_PRICE);

        MorphoBlueFork market = new MorphoBlueFork(address(this));
        MarketParams memory marketParams = MarketParams({
            loanToken: address(loanToken),
            collateralToken: address(collateralToken),
            oracle: address(oracle),
            irm: address(0),
            lltv: LLTV
        });
        Id id = marketParams.id();
        IControllerBucketPreview controller = _deployController(market, id);
        IDeleverageCandidatesRegistry candidatesRegistry = _deployDeleverageCandidatesRegistry(address(controller));
        controller.grantRole(controller.CONFIGURATOR_ROLE(), address(this));
        controller.setDeleverageCandidatesRegistry(address(candidatesRegistry));

        market.enableIrm(address(0));
        market.enableLltv(LLTV);
        market.createMarket(marketParams, address(controller), true);

        loanToken.setBalance(LENDER, 100 ether);
        vm.prank(LENDER);
        loanToken.approve(address(market), type(uint256).max);
        vm.prank(LENDER);
        market.supply(marketParams, 100 ether, 0, LENDER, "");

        collateralToken.setBalance(BORROWER, 100 ether);
        vm.prank(BORROWER);
        collateralToken.approve(address(market), type(uint256).max);
        vm.prank(BORROWER);
        market.supplyCollateral(marketParams, 100 ether, BORROWER, "");

        collateralToken.setBalance(OPT_IN_BORROWER, 100 ether);
        vm.prank(OPT_IN_BORROWER);
        collateralToken.approve(address(market), type(uint256).max);
        vm.prank(OPT_IN_BORROWER);
        market.supplyCollateral(marketParams, 100 ether, OPT_IN_BORROWER, "");
        vm.prank(OPT_IN_BORROWER);
        candidatesRegistry.setDeleverageOptInTargetRisk(0.1e18);

        vm.warp(block.timestamp + 2 hours + 1);
        vm.prank(BORROWER);
        market.borrow(marketParams, 79 ether, 0, BORROWER, BORROWER);
        vm.prank(OPT_IN_BORROWER);
        market.borrow(marketParams, 20 ether, 0, OPT_IN_BORROWER, OPT_IN_BORROWER);

        (uint256 riskWad, uint16 bucket, bool eligible, uint256 maxDebtToCancel,) =
            controller.previewDeleverageBucket(id, BORROWER);

        assertEq(bucket, 9, "79 / (100 * 80%) is in the 90-100% risk bucket");
        assertTrue(riskWad > 0.98e18 && riskWad < 0.99e18, "risk preview");
        assertTrue(eligible, "borrower bucket eligible");
        assertGt(maxDebtToCancel, 20 ether, "bucket waterline allows useful cut");

        (IDeleverageCandidatesRegistry.DeleverageCut[] memory cuts, uint256 coveredDebtAssets,) =
            candidatesRegistry.previewDeleverageCuts(30 ether, 4, 20, 0);
        assertEq(coveredDebtAssets, 30 ether, "registry covers requested deleverage debt");
        assertEq(cuts[0].borrower, BORROWER, "highest bucket first");
        assertEq(cuts[1].borrower, OPT_IN_BORROWER, "opt-in borrower fills the remainder");
        assertTrue(cuts[1].optIn, "second cut uses borrower opt-in");

        (uint256 supplyShares,,) = market.position(id, LENDER);
        uint256 collateralBefore = collateralToken.balanceOf(LENDER);

        vm.prank(LENDER);
        (uint256 collateralSeized, uint256 debtCanceled) =
            market.deleverage(marketParams, supplyShares / 5, BORROWER, LENDER, LENDER);

        assertTrue(debtCanceled > 19 ether && debtCanceled <= 20 ether, "deleverage canceled debt");
        assertEq(collateralToken.balanceOf(LENDER), collateralBefore + collateralSeized, "lender received collateral");

        collateralToken.setBalance(BORROWER, 100 ether);
        vm.prank(BORROWER);
        collateralToken.approve(address(market), type(uint256).max);
        vm.prank(BORROWER);
        market.supplyCollateral(marketParams, 100 ether, BORROWER, "");

        (, uint16 bucketAfterFreshCollateral,,,) = controller.previewDeleverageBucket(id, BORROWER);
        assertLt(bucketAfterFreshCollateral, bucket, "fresh collateral lowers borrower risk before maturity");
    }

    function testFallbackWaterfallCanReachLowRiskBucketsAndSkipDustInPreview() public {
        ERC20Mock loanToken = new ERC20Mock();
        ERC20Mock collateralToken = new ERC20Mock();
        OracleMock oracle = new OracleMock();
        oracle.setPrice(ORACLE_PRICE);

        MorphoBlueFork market = new MorphoBlueFork(address(this));
        MarketParams memory marketParams = MarketParams({
            loanToken: address(loanToken),
            collateralToken: address(collateralToken),
            oracle: address(oracle),
            irm: address(0),
            lltv: LLTV
        });
        Id id = marketParams.id();
        IControllerBucketPreview controller = _deployController(market, id);
        IDeleverageCandidatesRegistry candidatesRegistry = _deployDeleverageCandidatesRegistry(address(controller));
        controller.grantRole(controller.CONFIGURATOR_ROLE(), address(this));
        controller.setDeleverageCandidatesRegistry(address(candidatesRegistry));

        market.enableIrm(address(0));
        market.enableLltv(LLTV);
        market.createMarket(marketParams, address(controller), true);

        loanToken.setBalance(LENDER, 90 ether);
        vm.prank(LENDER);
        loanToken.approve(address(market), type(uint256).max);
        vm.prank(LENDER);
        market.supply(marketParams, 90 ether, 0, LENDER, "");

        collateralToken.setBalance(BORROWER, 100 ether);
        vm.prank(BORROWER);
        collateralToken.approve(address(market), type(uint256).max);
        vm.prank(BORROWER);
        market.supplyCollateral(marketParams, 100 ether, BORROWER, "");

        collateralToken.setBalance(LOW_RISK_BORROWER, 100 ether);
        vm.prank(LOW_RISK_BORROWER);
        collateralToken.approve(address(market), type(uint256).max);
        vm.prank(LOW_RISK_BORROWER);
        market.supplyCollateral(marketParams, 100 ether, LOW_RISK_BORROWER, "");

        vm.warp(block.timestamp + 2 hours + 1);
        vm.prank(BORROWER);
        market.borrow(marketParams, 79 ether, 0, BORROWER, BORROWER);
        vm.prank(LOW_RISK_BORROWER);
        market.borrow(marketParams, 6 ether, 0, LOW_RISK_BORROWER, LOW_RISK_BORROWER);

        (IDeleverageCandidatesRegistry.DeleverageCut[] memory cuts, uint256 coveredDebtAssets,) =
            candidatesRegistry.previewDeleverageCuts(30 ether, 4, 20, 0);
        assertEq(coveredDebtAssets, 30 ether, "waterfall reaches lower buckets");
        assertEq(cuts[0].borrower, BORROWER, "highest-risk borrower first");
        assertEq(cuts[1].borrower, LOW_RISK_BORROWER, "low-risk borrower used when upper bucket is insufficient");
        assertEq(cuts[1].debtAssetsToCancel, 5 ether, "partial cut leaves residual debt");
        assertFalse(cuts[1].optIn, "low-risk borrower was not opt-in");

        (, uint256 coveredWithDustFilter,) = candidatesRegistry.previewDeleverageCuts(40 ether, 4, 20, 10 ether);
        assertLt(coveredWithDustFilter, 40 ether, "preview minDebtCut can skip small candidates");
    }

    function testVaultFallbackExitFindsBorrowerFromRegistry() public {
        ERC20Mock loanToken = new ERC20Mock();
        ERC20Mock collateralToken = new ERC20Mock();
        OracleMock oracle = new OracleMock();
        oracle.setPrice(ORACLE_PRICE);

        MorphoBlueFork market = new MorphoBlueFork(address(this));
        MarketParams memory marketParams = MarketParams({
            loanToken: address(loanToken),
            collateralToken: address(collateralToken),
            oracle: address(oracle),
            irm: address(0),
            lltv: LLTV
        });
        Id id = marketParams.id();
        IControllerBucketPreview controller = _deployController(market, id);
        IDeleverageCandidatesRegistry candidatesRegistry = _deployDeleverageCandidatesRegistry(address(controller));
        controller.grantRole(controller.CONFIGURATOR_ROLE(), address(this));
        controller.setDeleverageCandidatesRegistry(address(candidatesRegistry));

        market.enableIrm(address(0));
        market.enableLltv(LLTV);
        market.createMarket(marketParams, address(controller), true);

        IFallbackExitVault vault = IFallbackExitVault(
            _deployArtifact(
                "MorphoBlueForkERC4626Vault.sol:MorphoBlueForkERC4626Vault",
                abi.encode(address(market), marketParams, address(candidatesRegistry), "Bucket Vault", "bvETH")
            )
        );

        loanToken.setBalance(LENDER, 79 ether);
        vm.prank(LENDER);
        loanToken.approve(address(vault), type(uint256).max);
        vm.prank(LENDER);
        uint256 vaultShares = vault.deposit(79 ether, LENDER);

        collateralToken.setBalance(BORROWER, 100 ether);
        vm.prank(BORROWER);
        collateralToken.approve(address(market), type(uint256).max);
        vm.prank(BORROWER);
        market.supplyCollateral(marketParams, 100 ether, BORROWER, "");

        vm.warp(block.timestamp + 2 hours + 1);
        vm.prank(BORROWER);
        market.borrow(marketParams, 79 ether, 0, BORROWER, BORROWER);

        uint256 collateralBefore = collateralToken.balanceOf(LENDER);
        uint256 sharesToExit = vaultShares / 5;

        vm.prank(LENDER);
        (, uint256 collateralSeized, uint256 debtCanceled) = vault.fallbackExit(sharesToExit, LENDER, LENDER, 0);

        assertGt(debtCanceled, 15 ether, "vault found borrower and canceled debt");
        assertEq(collateralToken.balanceOf(LENDER), collateralBefore + collateralSeized, "lender received collateral");
        assertEq(vault.balanceOf(LENDER), vaultShares - sharesToExit, "vault shares burned");
    }

    function _deployController(MorphoBlueFork core, Id id) internal returns (IControllerBucketPreview) {
        address accessRegistry =
            _deployArtifact("MarketAccessRegistry.sol:MarketAccessRegistry", abi.encode(address(this)));
        address implementation = _deployArtifact("LidoMarketController.sol:LidoMarketController", "");
        bytes memory initData = abi.encodeWithSignature(
            "initialize(address,bytes32,address,address)", address(core), Id.unwrap(id), accessRegistry, address(this)
        );
        address proxy =
            _deployArtifact("OssifiableProxy.sol:OssifiableProxy", abi.encode(implementation, address(this), initData));
        return IControllerBucketPreview(proxy);
    }

    function _deployDeleverageCandidatesRegistry(address controller) internal returns (IDeleverageCandidatesRegistry) {
        address registry =
            _deployArtifact("DeleverageCandidatesRegistry.sol:DeleverageCandidatesRegistry", abi.encode(controller));
        return IDeleverageCandidatesRegistry(registry);
    }

    function _deployArtifact(string memory artifact, bytes memory args) internal returns (address deployed) {
        bytes memory bytecode = vm.getCode(artifact);
        bytes memory creationCode = bytes.concat(bytecode, args);
        assembly ("memory-safe") {
            deployed := create(0, add(creationCode, 0x20), mload(creationCode))
        }
        require(deployed != address(0) && deployed.code.length != 0, "artifact deploy failed");
    }
}
