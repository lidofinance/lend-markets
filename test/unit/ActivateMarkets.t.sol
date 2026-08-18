// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";

import {Id, MarketParams} from "@lido-lend/src/interfaces/IMorpho.sol";
import {MarketParamsLib} from "@lido-lend/src/libraries/MarketParamsLib.sol";

import {ActivateMarkets} from "../../script/ActivateMarkets.s.sol";

contract ActivateMarketsHarness is ActivateMarkets {
    using MarketParamsLib for MarketParams;

    function configure(
        address irm,
        address router,
        address facade,
        address core,
        address circuitBreaker,
        address pauser,
        address morphoBook,
        address erc4626Book
    ) external {
        bb = Backbone({
            router: router,
            adaptiveCurveIrm: irm,
            facade: facade,
            core: core,
            circuitBreaker: circuitBreaker,
            pauserCommittee: pauser,
            hasExitBooks: true,
            morphoBook: morphoBook,
            erc4626Book: erc4626Book
        });
    }

    function resume(MarketParams memory market, address controller, address vault, address irmConfig) external {
        _resumeActivation("test-market", market, controller, vault, irmConfig);
    }

    function preflight(MarketParams memory market, address controller, address vault, address irmConfig) external view {
        _requireResumable(
            ActivationInput({
                name: "test-market", controller: controller, vault: vault, market: market, irmConfig: irmConfig
            })
        );
    }

    function load(string memory artifact) external view returns (bytes32) {
        ActivationInput memory input = _loadActivationInput(artifact);
        return Id.unwrap(input.market.id());
    }
}

contract MockActivationIrm {
    using MarketParamsLib for MarketParams;

    mapping(bytes32 id => address config) public marketCurveConfig;
    uint256 public applyCalls;

    function applyIrmConfig(MarketParams calldata market, address config) external {
        marketCurveConfig[Id.unwrap(market.id())] = config;
        ++applyCalls;
    }

    function seed(bytes32 id, address config) external {
        marketCurveConfig[id] = config;
    }
}

contract MockActivationRouter {
    using MarketParamsLib for MarketParams;

    mapping(bytes32 id => address irm) public marketIrm;
    uint256 public routeCalls;

    function setMarketIrm(MarketParams calldata market, address irm) external {
        marketIrm[Id.unwrap(market.id())] = irm;
        ++routeCalls;
    }

    function seed(bytes32 id, address irm) external {
        marketIrm[id] = irm;
    }
}

contract MockActivationCoreAndFacade {
    using MarketParamsLib for MarketParams;

    mapping(bytes32 id => uint128 lastUpdate) internal _lastUpdate;
    mapping(bytes32 id => address controller) public marketController;
    mapping(bytes32 id => bool enabled) public isSettlementEnabled;
    uint256 public createCalls;

    function market(bytes32 id) external view returns (uint128, uint128, uint128, uint128, uint128, uint128) {
        return (0, 0, 0, 0, _lastUpdate[id], 0);
    }

    function createMarket(MarketParams calldata marketParams, address controller, bool enableSettlement) external {
        bytes32 id = Id.unwrap(marketParams.id());
        _lastUpdate[id] = 1;
        marketController[id] = controller;
        isSettlementEnabled[id] = enableSettlement;
        ++createCalls;
    }

    function seed(bytes32 id, address controller, bool enableSettlement) external {
        _lastUpdate[id] = 1;
        marketController[id] = controller;
        isSettlementEnabled[id] = enableSettlement;
    }
}

contract MockActivationCircuitBreaker {
    mapping(address pausable => address pauser) public getPauser;
    uint256 public registerCalls;

    function registerPauser(address pausable, address pauser) external {
        getPauser[pausable] = pauser;
        ++registerCalls;
    }
}

contract MockActivationMorphoBook {
    using MarketParamsLib for MarketParams;

    mapping(bytes32 id => bool allowed) public isMarketAllowed;
    uint256 public allowCalls;

    function setMarketAllowed(MarketParams calldata market, bool allowed) external {
        isMarketAllowed[Id.unwrap(market.id())] = allowed;
        ++allowCalls;
    }
}

contract MockActivationErc4626Book {
    mapping(address vault => bool allowed) public isVaultAllowed;
    uint256 public allowCalls;

    function setVaultAllowed(address vault, bool allowed) external {
        isVaultAllowed[vault] = allowed;
        ++allowCalls;
    }
}

contract ActivateMarketsTest is Test {
    using MarketParamsLib for MarketParams;

    ActivateMarketsHarness internal activation;
    MockActivationIrm internal irm;
    MockActivationRouter internal router;
    MockActivationCoreAndFacade internal core;
    MockActivationCircuitBreaker internal circuitBreaker;
    MockActivationMorphoBook internal morphoBook;
    MockActivationErc4626Book internal erc4626Book;

    MarketParams internal market;
    address internal controller = makeAddr("controller");
    address internal vault = makeAddr("vault");
    address internal irmConfig = makeAddr("irmConfig");
    address internal pauser = makeAddr("pauser");

    function setUp() external {
        activation = new ActivateMarketsHarness();
        irm = new MockActivationIrm();
        router = new MockActivationRouter();
        core = new MockActivationCoreAndFacade();
        circuitBreaker = new MockActivationCircuitBreaker();
        morphoBook = new MockActivationMorphoBook();
        erc4626Book = new MockActivationErc4626Book();

        market = MarketParams({
            loanToken: makeAddr("loanToken"),
            collateralToken: makeAddr("collateralToken"),
            oracle: makeAddr("oracle"),
            irm: address(router),
            lltv: 0.8 ether
        });
        activation.configure(
            address(irm),
            address(router),
            address(core),
            address(core),
            address(circuitBreaker),
            pauser,
            address(morphoBook),
            address(erc4626Book)
        );
    }

    function test_resumeActivation_runsEveryMissingStepOnce() external {
        activation.resume(market, controller, vault, irmConfig);

        bytes32 id = Id.unwrap(market.id());
        assertEq(irm.marketCurveConfig(id), irmConfig);
        assertEq(router.marketIrm(id), address(irm));
        assertEq(core.marketController(id), controller);
        assertTrue(core.isSettlementEnabled(id));
        assertEq(circuitBreaker.getPauser(controller), pauser);
        assertTrue(morphoBook.isMarketAllowed(id));
        assertTrue(erc4626Book.isVaultAllowed(vault));
    }

    function test_resumeActivation_repairsTailAfterMarketCreationAndThenDoesNothing() external {
        bytes32 id = Id.unwrap(market.id());
        irm.seed(id, irmConfig);
        router.seed(id, address(irm));
        core.seed(id, controller, true);

        activation.resume(market, controller, vault, irmConfig);

        assertEq(irm.applyCalls(), 0);
        assertEq(router.routeCalls(), 0);
        assertEq(core.createCalls(), 0);
        assertEq(circuitBreaker.registerCalls(), 1);
        assertEq(morphoBook.allowCalls(), 1);
        assertEq(erc4626Book.allowCalls(), 1);

        activation.resume(market, controller, vault, irmConfig);

        assertEq(circuitBreaker.registerCalls(), 1);
        assertEq(morphoBook.allowCalls(), 1);
        assertEq(erc4626Book.allowCalls(), 1);
    }

    function testRevert_resumeActivation_rejectsDifferentExistingController() external {
        bytes32 id = Id.unwrap(market.id());
        irm.seed(id, irmConfig);
        router.seed(id, address(irm));
        address otherController = makeAddr("otherController");
        core.seed(id, otherController, true);

        vm.expectRevert(
            abi.encodeWithSelector(
                ActivateMarkets.UnexpectedController.selector, "test-market", controller, otherController
            )
        );
        activation.resume(market, controller, vault, irmConfig);
    }

    function testRevert_resumeActivation_rejectsDifferentExistingPauser() external {
        bytes32 id = Id.unwrap(market.id());
        irm.seed(id, irmConfig);
        router.seed(id, address(irm));
        core.seed(id, controller, true);
        address otherPauser = makeAddr("otherPauser");
        circuitBreaker.registerPauser(controller, otherPauser);

        vm.expectRevert(
            abi.encodeWithSelector(ActivateMarkets.UnexpectedPauser.selector, "test-market", pauser, otherPauser)
        );
        activation.resume(market, controller, vault, irmConfig);
    }

    function testRevert_preflight_rejectsConflictWithoutApplyingMissingEarlierSteps() external {
        bytes32 id = Id.unwrap(market.id());
        address otherController = makeAddr("otherController");
        core.seed(id, otherController, true);

        vm.expectRevert(
            abi.encodeWithSelector(
                ActivateMarkets.UnexpectedController.selector, "test-market", controller, otherController
            )
        );
        activation.preflight(market, controller, vault, irmConfig);

        assertEq(irm.applyCalls(), 0);
        assertEq(router.routeCalls(), 0);
    }

    function testRevert_loadActivationInput_rejectsRecordedIdMismatch() external {
        bytes32 actualId = Id.unwrap(market.id());
        bytes32 recordedId = bytes32(uint256(actualId) ^ 1);
        string memory artifact = string.concat(
            "[market]\nname = \"test-market\"\ncontroller = \"",
            vm.toString(controller),
            "\"\nvault = \"",
            vm.toString(vault),
            "\"\nid = \"",
            vm.toString(recordedId),
            "\"\nloan_token = \"",
            vm.toString(market.loanToken),
            "\"\ncollateral_token = \"",
            vm.toString(market.collateralToken),
            "\"\noracle = \"",
            vm.toString(market.oracle),
            "\"\nlltv = ",
            vm.toString(market.lltv),
            "\nirm_config = \"",
            vm.toString(irmConfig),
            "\"\n"
        );

        vm.expectRevert(
            abi.encodeWithSelector(ActivateMarkets.MarketIdMismatch.selector, "test-market", actualId, recordedId)
        );
        activation.load(artifact);
    }
}
