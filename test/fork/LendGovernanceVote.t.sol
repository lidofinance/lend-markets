// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";

import {RecordedDeployment} from "../../script/deployment/RecordedDeployment.sol";
import {DeploymentSnapshot} from "../../script/deployment/DeploymentSnapshot.sol";

import {AddLendFactoriesOmnibus} from "../../script/vote/AddLendFactoriesOmnibus.sol";
import {CallsScriptBuilder} from "../../script/vote/CallsScriptBuilder.sol";

interface IAragonVoting {
    function newVote(bytes calldata executionScript, string calldata metadata, bool castVote, bool executesIfDecided)
        external;
    function vote(uint256 voteId, bool inSupport, bool executesIfDecided) external;
    function executeVote(uint256 voteId) external;
    function voteTime() external view returns (uint64);
    function votesLength() external view returns (uint256);
}

interface IAragonTokenManager {
    function forward(bytes calldata evmScript) external;
}

interface IErc20Like {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}

interface IEasyTrackViews {
    function getEVMScriptFactories() external view returns (address[] memory);
    function evmScriptFactoryPermissions(address factory) external view returns (bytes memory);
}

interface IAccessControlViews {
    function hasRole(bytes32 role, address account) external view returns (bool);
}

interface ICircuitBreakerViews {
    function ADMIN() external view returns (address);
    function getPauser(address pausable) external view returns (address);
}

interface IManagedViews {
    function owner() external view returns (address);
    function manager() external view returns (address);
}

interface ICoreViews {
    function feeRecipient() external view returns (address);
    function proxy__getAdmin() external view returns (address);
}

interface IGuardianRegistryViews {
    function isGuardian(address account) external view returns (bool);
}

contract EmptyFactoryStub {}

/// @notice Executes the Add-Lend-Factories omnibus through the real Hoodi Aragon governance on a fork of a
///         deployed run, then asserts the resulting governance topology: the EVMScriptExecutor holds every
///         management capability and the legacy multisig participates only as one of the guardians.
contract LendGovernanceVoteFork is Test {
    address internal constant VOTING = 0x49B3512c44891bef83F8967d075121Bd1b07a01B;
    address internal constant TOKEN_MANAGER = 0x8ab4a56721Ad8e68c6Ad86F9D9929782A78E39E5;
    address internal constant EASY_TRACK = 0x284D91a7D47850d21A6DEaaC6E538AC7E5E6fc2a;
    address internal constant LDO = 0xEf2573966D009CcEA0Fc74451dee2193564198dc;
    address internal constant AGENT = 0x0534aA41907c9631fae990960bCC72d75fA7cfeD;
    address internal constant EXECUTOR = 0x79a20FD0FA36453B2F45eAbab19bfef43575Ba9E;
    address internal constant MULTISIG = 0xA6b2dbCCE7895347A62b4409d29bA7ce29A74655;
    address internal constant LDO_WHALE = address(uint160(uint256(keccak256("lido-lend.vote.ldo-whale"))));

    address internal ownerFacade;
    address internal irmRouter;
    address internal adaptiveCurveIrm;
    address internal circuitBreaker;
    address internal riskStewardDashboard;
    address internal core;
    address internal guardianSignals;
    address[] internal controllers;

    address[] internal factories;
    bytes[] internal permissions;

    function setUp() public {
        if (bytes(vm.envOr("DEPLOYMENT_RUN", string(""))).length == 0) {
            vm.skip(true, "governance vote requires an existing Hoodi deployment");
        }
        uint256 pin = vm.envOr("FORK_BLOCK", uint256(0));
        if (pin == 0) vm.createSelectFork(vm.envString("RPC_URL"));
        else vm.createSelectFork(vm.envString("RPC_URL"), pin);
        if (block.chainid != 560048) vm.skip(true, "hoodi governance only");
        DeploymentSnapshot memory d = RecordedDeployment.load(vm.envString("DEPLOYMENT_RUN"));
        if (d.protocol.agent != AGENT) vm.skip(true, "run is not governed by the Hoodi DAO");
        ownerFacade = d.protocol.ownerFacade;
        irmRouter = d.protocol.irmRouter;
        adaptiveCurveIrm = d.protocol.adaptiveCurveIrm;
        circuitBreaker = d.protocol.circuitBreaker;
        riskStewardDashboard = d.protocol.dashboard;
        core = d.protocol.core;
        require(d.markets.length != 0, "governance vote requires recorded markets");
        guardianSignals = d.markets[0].contracts.guardianSignals;
        for (uint256 i; i < d.markets.length; ++i) {
            assertEq(d.markets[i].contracts.guardianSignals, guardianSignals, "Hoodi shared guardian registry");
            controllers.push(d.markets[i].contracts.controller);
        }
    }

    function test_addFactoriesVote_executesAndLeavesExecutorOnlyTopology() public {
        AddLendFactoriesOmnibus omnibus = _buildOmnibus();
        uint256 voteId = _createVote(omnibus);
        assertTrue(omnibus.isValidVoteScript(voteId), "on-chain vote script differs from the omnibus items");
        _passAndEnact(voteId);

        _assertFactoriesRegistered();
        _assertExecutorHoldsEveryCapability();
        _assertMultisigIsOnlyAGuardian();
    }

    function _buildOmnibus() internal returns (AddLendFactoriesOmnibus) {
        factories.push(address(new EmptyFactoryStub()));
        factories.push(address(new EmptyFactoryStub()));

        permissions.push(
            abi.encodePacked(
                adaptiveCurveIrm,
                bytes4(keccak256("applyIrmConfig((address,address,address,address,uint256),address)")),
                irmRouter,
                bytes4(keccak256("setMarketIrm((address,address,address,address,uint256),address)")),
                ownerFacade,
                bytes4(keccak256("createMarket((address,address,address,address,uint256),address,bool)")),
                circuitBreaker,
                bytes4(keccak256("registerPauser(address,address)"))
            )
        );
        permissions.push(
            abi.encodePacked(
                ownerFacade, bytes4(keccak256("setFee((address,address,address,address,uint256),uint256)"))
            )
        );

        string[] memory descriptions = new string[](2);
        descriptions[0] = "1. Add LidoLendActivateMarket EVM script factory to EasyTrack";
        descriptions[1] = "2. Add LidoLendSetFee EVM script factory to EasyTrack";

        return new AddLendFactoriesOmnibus(VOTING, EASY_TRACK, factories, permissions, descriptions);
    }

    function _createVote(AddLendFactoriesOmnibus omnibus) internal returns (uint256 voteId) {
        uint256 agentLdoBalance = IErc20Like(LDO).balanceOf(AGENT);
        assertGt(agentLdoBalance, 0, "agent holds no LDO on this fork");
        vm.prank(AGENT);
        IErc20Like(LDO).transfer(LDO_WHALE, agentLdoBalance);
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 15);

        voteId = IAragonVoting(VOTING).votesLength();
        bytes memory newVoteScript =
            CallsScriptBuilder.create(
            VOTING,
            abi.encodeCall(
                IAragonVoting.newVote, (omnibus.getEVMScript(), "Add Lend EasyTrack factories", false, false)
            )
        )
        .result;
        vm.prank(LDO_WHALE);
        IAragonTokenManager(TOKEN_MANAGER).forward(newVoteScript);
    }

    function _passAndEnact(uint256 voteId) internal {
        vm.prank(LDO_WHALE);
        IAragonVoting(VOTING).vote(voteId, true, false);
        vm.warp(block.timestamp + IAragonVoting(VOTING).voteTime());
        IAragonVoting(VOTING).executeVote(voteId);
    }

    function _assertFactoriesRegistered() internal view {
        for (uint256 i = 0; i < factories.length; ++i) {
            assertEq(
                IEasyTrackViews(EASY_TRACK).evmScriptFactoryPermissions(factories[i]),
                permissions[i],
                "factory permissions mismatch"
            );
        }
        address[] memory registeredFactories = IEasyTrackViews(EASY_TRACK).getEVMScriptFactories();
        uint256 foundCount;
        for (uint256 i = 0; i < registeredFactories.length; ++i) {
            if (registeredFactories[i] == factories[0] || registeredFactories[i] == factories[1]) foundCount++;
        }
        assertEq(foundCount, 2, "factories not registered in EasyTrack");
    }

    function _assertExecutorHoldsEveryCapability() internal view {
        assertTrue(_hasNamedRole(ownerFacade, "MARKET_CREATOR_ROLE", EXECUTOR), "executor lacks MARKET_CREATOR");
        assertTrue(_hasNamedRole(ownerFacade, "FEE_MANAGER_ROLE", EXECUTOR), "executor lacks FEE_MANAGER");
        assertTrue(_hasNamedRole(ownerFacade, "MARKET_MANAGER_ROLE", EXECUTOR), "executor lacks MARKET_MANAGER");
        assertTrue(_hasNamedRole(ownerFacade, "GUARDIAN_MANAGER_ROLE", EXECUTOR), "executor lacks GUARDIAN_MANAGER");
        assertTrue(_hasNamedRole(riskStewardDashboard, "STEWARD_ADMIN_ROLE", EXECUTOR), "executor lacks STEWARD_ADMIN");
        assertEq(ICircuitBreakerViews(circuitBreaker).ADMIN(), EXECUTOR, "circuit breaker admin is not the executor");
        assertEq(IManagedViews(irmRouter).manager(), EXECUTOR, "router manager is not the executor");
        assertEq(IManagedViews(adaptiveCurveIrm).manager(), EXECUTOR, "irm manager is not the executor");
    }

    function _assertMultisigIsOnlyAGuardian() internal view {
        _assertRoleFree(ownerFacade, "facade");
        _assertNamedRoleAbsent(ownerFacade, "MARKET_CREATOR_ROLE", "facade");
        _assertNamedRoleAbsent(ownerFacade, "FEE_MANAGER_ROLE", "facade");
        _assertNamedRoleAbsent(ownerFacade, "MARKET_MANAGER_ROLE", "facade");
        _assertNamedRoleAbsent(ownerFacade, "GUARDIAN_MANAGER_ROLE", "facade");
        _assertRoleFree(riskStewardDashboard, "dashboard");
        _assertNamedRoleAbsent(riskStewardDashboard, "STEWARD_ADMIN_ROLE", "dashboard");
        assertTrue(IGuardianRegistryViews(guardianSignals).isGuardian(MULTISIG), "multisig must stay a guardian");
        _assertRoleFree(guardianSignals, "registry");
        _assertNamedRoleAbsent(guardianSignals, "MANAGER_ROLE", "registry");
        _assertNamedRoleAbsent(guardianSignals, "ACCESS_LIMITER_ROLE", "registry");
        _assertNamedRoleAbsent(guardianSignals, "ACCESS_RESTORER_ROLE", "registry");

        assertEq(ICoreViews(core).feeRecipient(), AGENT, "fee recipient must be the agent, not the multisig");
        assertEq(ICoreViews(core).proxy__getAdmin(), AGENT, "core proxy admin must be the agent");
        assertTrue(IManagedViews(irmRouter).owner() != MULTISIG, "multisig must not own the router");

        for (uint256 i = 0; i < controllers.length; ++i) {
            address controller = controllers[i];
            _assertRoleFree(controller, "controller");
            _assertNamedRoleAbsent(controller, "MANAGER_ROLE", "controller");
            _assertNamedRoleAbsent(controller, "PAUSER_ROLE", "controller");
            _assertNamedRoleAbsent(controller, "RESUMER_ROLE", "controller");
            _assertNamedRoleAbsent(controller, "FREEZER_ROLE", "controller");
            _assertNamedRoleAbsent(controller, "UNFREEZER_ROLE", "controller");
            assertTrue(
                ICircuitBreakerViews(circuitBreaker).getPauser(controller) != MULTISIG,
                "multisig must not be the registered pauser"
            );
        }
    }

    function _hasNamedRole(address target, string memory roleName, address account) internal view returns (bool) {
        return IAccessControlViews(target).hasRole(keccak256(bytes(roleName)), account);
    }

    function _assertNamedRoleAbsent(address target, string memory roleName, string memory label) internal view {
        assertFalse(
            _hasNamedRole(target, roleName, MULTISIG), string.concat(label, ": multisig still holds ", roleName)
        );
    }

    function _assertRoleFree(address target, string memory label) internal view {
        assertFalse(
            IAccessControlViews(target).hasRole(bytes32(0), MULTISIG),
            string.concat(label, ": multisig still holds DEFAULT_ADMIN_ROLE")
        );
    }
}
