// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {ILidoLend} from "@lido-lend/src/interfaces/ILidoLend.sol";
import {Id, MarketParams} from "@lido-lend/src/interfaces/IMorpho.sol";
import {LidoLend} from "@lido-lend/src/LidoLend.sol";
import {MarketParamsLib} from "@lido-lend/src/libraries/MarketParamsLib.sol";
import {ControllerMock} from "@lido-lend/src/mocks/ControllerMock.sol";
import {IrmMock} from "@lido-lend/src/mocks/IrmMock.sol";

import {LidoLendOwner} from "../../src/periphery/LidoLendOwner.sol";
import {ILidoLendOwner} from "../../src/interfaces/ILidoLendOwner.sol";
import {CollateralActivationConfig} from "../../src/types/CollateralActivationTypes.sol";
import {SettlementConfig} from "../../src/types/SettlementTypes.sol";

contract OwnerGuardianSignalsMock {
    address public lastAdded;
    address public lastRemoved;
    address public lastReplacedOld;
    address public lastReplacedNew;
    Id public lastUnbanMarket;
    address public lastUnbanAccount;
    uint256 public addCalls;
    uint256 public removeCalls;
    uint256 public replaceCalls;
    uint256 public quorum = 2;
    uint256 public suspectWindow;
    uint256 public unbanCalls;

    function addGuardian(address guardian) external {
        lastAdded = guardian;
        ++addCalls;
    }

    function removeGuardian(address guardian) external {
        lastRemoved = guardian;
        ++removeCalls;
    }

    function replaceGuardian(address oldGuardian, address newGuardian) external {
        lastReplacedOld = oldGuardian;
        lastReplacedNew = newGuardian;
        ++replaceCalls;
    }

    function setQuorum(uint256 newQuorum) external {
        quorum = newQuorum;
    }

    function setSuspectWindow(uint256 newSuspectWindow) external {
        suspectWindow = newSuspectWindow;
    }

    function unban(Id marketId, address account) external {
        lastUnbanMarket = marketId;
        lastUnbanAccount = account;
        ++unbanCalls;
    }
}

contract OwnerControllerMock {
    Id private immutable _marketId;
    address public immutable guardianSignals;

    uint256 public supplyCap;
    uint256 public unfreezeCalls;
    bytes32 public activationConfigHash;
    bytes32 public settlementConfigHash;
    address public instantActivationCaller;
    bool public instantActivationEnabled;

    constructor(Id marketId_, address guardianSignals_) {
        _marketId = marketId_;
        guardianSignals = guardianSignals_;
    }

    function marketId() external view returns (Id) {
        return _marketId;
    }

    function setSupplyCap(uint256 cap) external {
        supplyCap = cap;
    }

    function unfreeze() external {
        ++unfreezeCalls;
    }

    function setCollateralActivationConfig(CollateralActivationConfig calldata config) external {
        activationConfigHash = keccak256(abi.encode(config));
    }

    function setSettlementConfig(SettlementConfig calldata config) external {
        settlementConfigHash = keccak256(abi.encode(config));
    }

    function setInstantActivation(address caller, bool enabled) external {
        instantActivationCaller = caller;
        instantActivationEnabled = enabled;
    }
}

/// @notice Unit tests for the role-gated core owner facade on a freshly deployed core (no fork needed: the
///         owner surface is independent of token/oracle/IRM behaviour). Verifies the role-to-capability mapping,
///         the events each capability forwards from the core, that every capability reverts without its role
///         and under a foreign role, and that the facade actually holds the core's owner.
contract LidoLendOwnerTest is Test {
    using MarketParamsLib for MarketParams;

    // Core events forwarded through the facade, redeclared for `vm.expectEmit` (emitted by the core proxy).
    event SetOwner(address indexed newOwner);
    event SetFee(Id indexed id, uint256 newFee);
    event SetFeeRecipient(address indexed newFeeRecipient);
    event CreateMarket(Id indexed id, MarketParams marketParams);
    event SetMarketController(Id indexed id, address indexed controller);
    event EnableSettlement(Id indexed id);
    event EnableIrm(address indexed irm);
    event EnableLltv(uint256 lltv);

    address internal constant ADMIN = address(0xA11CE);
    address internal constant CREATOR = address(0xC0FFEE);
    address internal constant FEE_MGR = address(0xFEE);

    ILidoLend internal core;
    LidoLendOwner internal facade;
    address internal irm;

    function setUp() public {
        bytes memory initData = abi.encodeWithSignature("initialize(address)", address(this));
        core = ILidoLend(address(new ERC1967Proxy(address(new LidoLend()), initData)));

        // Market creation makes the core call `irm.borrowRate`, so a real (mock) IRM contract is required.
        irm = address(new IrmMock());

        // Capability roles left unset here; granted per test via `_grant` (the constructor-granting path is
        // covered separately).
        facade = new LidoLendOwner(core, ADMIN, address(0), address(0));
        // `initialize` made this test the core owner; hand it to the facade.
        core.setOwner(address(facade));
    }

    // ---
    // HELPERS
    // ---

    function _params(uint256 salt) internal view returns (MarketParams memory) {
        return MarketParams({
            loanToken: address(uint160(0x100000 + salt)),
            collateralToken: address(uint160(0x200000 + salt)),
            oracle: address(uint160(0x300000 + salt)),
            irm: irm,
            lltv: 0.8e18 // < WAD
        });
    }

    function _grant(bytes32 role, address to) internal {
        vm.prank(ADMIN);
        facade.grantRole(role, to);
    }

    function _unauthorized(address account, bytes32 role) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, account, role);
    }

    function _createManagedMarkets()
        internal
        returns (
            MarketParams memory p1,
            MarketParams memory p2,
            OwnerControllerMock c1,
            OwnerControllerMock c2,
            OwnerGuardianSignalsMock g1,
            OwnerGuardianSignalsMock g2
        )
    {
        p1 = _params(101);
        p2 = _params(202);
        g1 = new OwnerGuardianSignalsMock();
        g2 = new OwnerGuardianSignalsMock();
        c1 = new OwnerControllerMock(p1.id(), address(g1));
        c2 = new OwnerControllerMock(p2.id(), address(g2));

        _grant(facade.MARKET_CREATOR_ROLE(), CREATOR);
        vm.startPrank(CREATOR);
        facade.createMarket(p1, address(c1), true);
        facade.createMarket(p2, address(c2), true);
        vm.stopPrank();
    }

    // ---
    // OWNERSHIP WIRING
    // ---

    /// @notice The facade is the core's owner; the admin holds the role that manages the facade.
    function test_facade_holdsCoreOwnership() public view {
        assertEq(core.owner(), address(facade), "facade owns core");
        assertTrue(facade.hasRole(facade.DEFAULT_ADMIN_ROLE(), ADMIN), "admin holds DEFAULT_ADMIN_ROLE");
    }

    // ---
    // MARKET CREATION
    // ---

    /// @notice A `MARKET_CREATOR_ROLE` holder creates a controller-less market; the core emits the full
    ///         first-use sequence `CreateMarket`, `EnableIrm`, `EnableLltv`.
    function test_createMarket_withRole_createsMarket() public {
        _grant(facade.MARKET_CREATOR_ROLE(), CREATOR);
        MarketParams memory p = _params(1);
        Id id = p.id();

        vm.expectEmit(true, true, true, true, address(core));
        emit CreateMarket(id, p);
        vm.expectEmit(true, true, true, true, address(core));
        emit EnableIrm(irm);
        vm.expectEmit(true, true, true, true, address(core));
        emit EnableLltv(p.lltv);
        vm.prank(CREATOR);
        facade.createMarket(p);

        uint128 lastUpdate = core.market(id).lastUpdate;
        assertGt(lastUpdate, 0, "market created");
    }

    /// @notice Creating a market without the role reverts at the facade's gate, never reaching the core.
    function testRevert_createMarket_withoutRole() public {
        MarketParams memory p = _params(1);
        bytes32 role = facade.MARKET_CREATOR_ROLE();
        vm.expectRevert(_unauthorized(CREATOR, role));
        vm.prank(CREATOR);
        facade.createMarket(p);
    }

    /// @notice A foreign role cannot create markets: the fee manager is rejected at the facade's gate.
    function testRevert_createMarket_wrongRole() public {
        _grant(facade.FEE_MANAGER_ROLE(), FEE_MGR);
        MarketParams memory p = _params(1);
        bytes32 role = facade.MARKET_CREATOR_ROLE();
        vm.expectRevert(_unauthorized(FEE_MGR, role));
        vm.prank(FEE_MGR);
        facade.createMarket(p);
    }

    /// @notice The controlled overload binds the controller and the settlement opt-in on the core, emitting both.
    function test_createMarket_controlled_bindsControllerAndSettlement() public {
        _grant(facade.MARKET_CREATOR_ROLE(), CREATOR);
        MarketParams memory p = _params(2);
        Id id = p.id();
        ControllerMock controller = new ControllerMock(id);

        vm.expectEmit(true, true, true, true, address(core));
        emit CreateMarket(id, p);
        vm.expectEmit(true, true, true, true, address(core));
        emit SetMarketController(id, address(controller));
        vm.expectEmit(true, true, true, true, address(core));
        emit EnableSettlement(id);
        vm.expectEmit(true, true, true, true, address(core));
        emit EnableIrm(irm);
        vm.expectEmit(true, true, true, true, address(core));
        emit EnableLltv(p.lltv);
        vm.prank(CREATOR);
        facade.createMarket(p, address(controller), true);

        assertEq(core.marketController(id), address(controller), "controller bound");
        assertTrue(core.isSettlementEnabled(id), "settlement enabled");
    }

    // ---
    // MARKET MANAGEMENT
    // ---

    function test_marketManagement_dispatchesByMarketId() public {
        (MarketParams memory p1, MarketParams memory p2, OwnerControllerMock c1, OwnerControllerMock c2,,) =
            _createManagedMarkets();
        _grant(facade.MARKET_MANAGER_ROLE(), CREATOR);

        CollateralActivationConfig memory activation1 = CollateralActivationConfig({
            minActivationDelay: 1,
            maxActivationDelay: 2,
            maxDelayInflow: 3,
            activatingLockAmount: 4,
            activatingLockDuration: 5,
            minActivationAmount: 6,
            minDepositAmount: 0,
            maxGuardiansQuorumDelay: 7,
            delayPerStrike: 8,
            delayPerSuspect: 9
        });
        CollateralActivationConfig memory activation2 = CollateralActivationConfig({
            minActivationDelay: 11,
            maxActivationDelay: 12,
            maxDelayInflow: 13,
            activatingLockAmount: 14,
            activatingLockDuration: 15,
            minActivationAmount: 16,
            minDepositAmount: 0,
            maxGuardiansQuorumDelay: 17,
            delayPerStrike: 18,
            delayPerSuspect: 19
        });
        SettlementConfig memory settlement1 =
            SettlementConfig({sliceFloorBps: 21, sliceFloorAssets: 22, fullCutBelowCollateral: 23, ltvStepBps: 24});
        SettlementConfig memory settlement2 =
            SettlementConfig({sliceFloorBps: 31, sliceFloorAssets: 32, fullCutBelowCollateral: 33, ltvStepBps: 34});

        vm.startPrank(CREATOR);
        facade.setMarketSupplyCap(p1.id(), 100);
        facade.setMarketSupplyCap(p2.id(), 200);
        facade.unfreezeMarket(p1.id());
        facade.unfreezeMarket(p2.id());
        facade.setMarketCollateralActivationConfig(p1.id(), activation1);
        facade.setMarketCollateralActivationConfig(p2.id(), activation2);
        facade.setMarketSettlementConfig(p1.id(), settlement1);
        facade.setMarketSettlementConfig(p2.id(), settlement2);
        facade.setInstantActivation(p1.id(), address(0x1111), true);
        facade.setInstantActivation(p2.id(), address(0x2222), false);
        vm.stopPrank();

        assertEq(c1.supplyCap(), 100, "market 1 supply cap");
        assertEq(c2.supplyCap(), 200, "market 2 supply cap");
        assertEq(c1.unfreezeCalls(), 1, "market 1 unfreeze");
        assertEq(c2.unfreezeCalls(), 1, "market 2 unfreeze");
        assertEq(c1.activationConfigHash(), keccak256(abi.encode(activation1)), "market 1 activation config");
        assertEq(c2.activationConfigHash(), keccak256(abi.encode(activation2)), "market 2 activation config");
        assertEq(c1.settlementConfigHash(), keccak256(abi.encode(settlement1)), "market 1 settlement config");
        assertEq(c2.settlementConfigHash(), keccak256(abi.encode(settlement2)), "market 2 settlement config");
        assertEq(c1.instantActivationCaller(), address(0x1111), "market 1 instant activation");
        assertEq(c2.instantActivationCaller(), address(0x2222), "market 2 instant activation");
        assertTrue(c1.instantActivationEnabled(), "market 1 instant activation enabled");
        assertFalse(c2.instantActivationEnabled(), "market 2 instant activation disabled");
    }

    function testRevert_marketManagement_withoutRole() public {
        MarketParams memory p = _params(999);
        Id id = p.id();
        bytes32 role = facade.MARKET_MANAGER_ROLE();
        CollateralActivationConfig memory activation;
        SettlementConfig memory settlement;

        vm.startPrank(CREATOR);
        vm.expectRevert(_unauthorized(CREATOR, role));
        facade.setMarketSupplyCap(id, 1);
        vm.expectRevert(_unauthorized(CREATOR, role));
        facade.unfreezeMarket(id);
        vm.expectRevert(_unauthorized(CREATOR, role));
        facade.setMarketCollateralActivationConfig(id, activation);
        vm.expectRevert(_unauthorized(CREATOR, role));
        facade.setMarketSettlementConfig(id, settlement);
        vm.expectRevert(_unauthorized(CREATOR, role));
        facade.setInstantActivation(id, address(1), true);
        vm.stopPrank();
    }

    // ---
    // GUARDIAN MANAGEMENT
    // ---

    function test_guardianManagement_dispatchesByMarketId() public {
        (MarketParams memory p1, MarketParams memory p2,,, OwnerGuardianSignalsMock g1, OwnerGuardianSignalsMock g2) =
            _createManagedMarkets();
        _grant(facade.GUARDIAN_MANAGER_ROLE(), CREATOR);

        vm.startPrank(CREATOR);
        facade.addGuardian(p1.id(), address(0xA1));
        facade.addGuardian(p2.id(), address(0xA2));
        facade.removeGuardian(p1.id(), address(0xB1));
        facade.removeGuardian(p2.id(), address(0xB2));
        facade.setGuardiansQuorum(p1.id(), 3);
        facade.setGuardiansQuorum(p2.id(), 4);
        facade.setGuardiansSuspectWindow(p1.id(), 5 days);
        facade.setGuardiansSuspectWindow(p2.id(), 6 days);
        Id[] memory ids = new Id[](2);
        ids[0] = p1.id();
        ids[1] = p2.id();
        facade.unbanGuardianSignals(ids, address(0xBADD));
        vm.stopPrank();

        assertEq(g1.addCalls(), 1, "market 1 add count");
        assertEq(g2.addCalls(), 1, "market 2 add count");
        assertEq(g1.removeCalls(), 1, "market 1 remove count");
        assertEq(g2.removeCalls(), 1, "market 2 remove count");
        assertEq(g1.lastRemoved(), address(0xB1), "market 1 removed guardian");
        assertEq(g2.lastRemoved(), address(0xB2), "market 2 removed guardian");
        assertEq(g1.lastAdded(), address(0xA1), "market 1 added guardian");
        assertEq(g2.lastAdded(), address(0xA2), "market 2 added guardian");
        assertEq(g1.quorum(), 3, "market 1 quorum");
        assertEq(g2.quorum(), 4, "market 2 quorum");
        assertEq(g1.suspectWindow(), 5 days, "market 1 suspect window");
        assertEq(g2.suspectWindow(), 6 days, "market 2 suspect window");
        assertEq(Id.unwrap(g1.lastUnbanMarket()), Id.unwrap(p1.id()), "market 1 unban id");
        assertEq(Id.unwrap(g2.lastUnbanMarket()), Id.unwrap(p2.id()), "market 2 unban id");
        assertEq(g1.lastUnbanAccount(), address(0xBADD), "market 1 unban account");
        assertEq(g2.lastUnbanAccount(), address(0xBADD), "market 2 unban account");
    }

    function test_replaceGuardian_dispatchesByMarketId() public {
        (MarketParams memory p1, MarketParams memory p2,,, OwnerGuardianSignalsMock g1, OwnerGuardianSignalsMock g2) =
            _createManagedMarkets();
        _grant(facade.GUARDIAN_MANAGER_ROLE(), CREATOR);

        vm.startPrank(CREATOR);
        facade.replaceGuardian(p1.id(), address(0xA1), address(0xB1));
        facade.replaceGuardian(p2.id(), address(0xA2), address(0xB2));
        vm.stopPrank();

        assertEq(g1.lastReplacedOld(), address(0xA1), "market 1 old guardian");
        assertEq(g2.lastReplacedOld(), address(0xA2), "market 2 old guardian");
        assertEq(g1.lastReplacedNew(), address(0xB1), "market 1 replacement");
        assertEq(g2.lastReplacedNew(), address(0xB2), "market 2 replacement");
        assertEq(g1.replaceCalls(), 1, "market 1 replace count");
        assertEq(g2.replaceCalls(), 1, "market 2 replace count");
    }

    function testRevert_guardianManagement_withoutRole() public {
        MarketParams memory p = _params(999);
        Id id = p.id();
        bytes32 role = facade.GUARDIAN_MANAGER_ROLE();
        Id[] memory ids = new Id[](1);
        ids[0] = id;

        vm.startPrank(CREATOR);
        vm.expectRevert(_unauthorized(CREATOR, role));
        facade.addGuardian(id, address(1));
        vm.expectRevert(_unauthorized(CREATOR, role));
        facade.replaceGuardian(id, address(1), address(2));
        vm.expectRevert(_unauthorized(CREATOR, role));
        facade.removeGuardian(id, address(1));
        vm.expectRevert(_unauthorized(CREATOR, role));
        facade.setGuardiansQuorum(id, 1);
        vm.expectRevert(_unauthorized(CREATOR, role));
        facade.setGuardiansSuspectWindow(id, 1);
        vm.expectRevert(_unauthorized(CREATOR, role));
        facade.unbanGuardianSignals(ids, address(1));
        vm.stopPrank();
    }

    function testRevert_marketAndGuardianManagement_wrongRole() public {
        bytes32 marketManagerRole = facade.MARKET_MANAGER_ROLE();
        bytes32 guardianManagerRole = facade.GUARDIAN_MANAGER_ROLE();
        _grant(marketManagerRole, CREATOR);
        MarketParams memory p = _params(999);
        Id id = p.id();

        vm.expectRevert(_unauthorized(CREATOR, guardianManagerRole));
        vm.prank(CREATOR);
        facade.addGuardian(id, address(1));

        vm.prank(ADMIN);
        facade.revokeRole(marketManagerRole, CREATOR);
        _grant(guardianManagerRole, CREATOR);
        vm.expectRevert(_unauthorized(CREATOR, marketManagerRole));
        vm.prank(CREATOR);
        facade.setMarketSupplyCap(id, 1);
    }

    function testRevert_unknownMarket() public {
        _grant(facade.MARKET_MANAGER_ROLE(), CREATOR);
        _grant(facade.GUARDIAN_MANAGER_ROLE(), CREATOR);
        Id id = _params(999).id();
        bytes memory expected = abi.encodeWithSelector(ILidoLendOwner.UnknownMarket.selector, id);

        vm.expectRevert(expected);
        vm.prank(CREATOR);
        facade.setMarketSupplyCap(id, 1);

        vm.expectRevert(expected);
        vm.prank(CREATOR);
        facade.addGuardian(id, address(1));

        vm.expectRevert(expected);
        vm.prank(CREATOR);
        facade.replaceGuardian(id, address(1), address(2));

        Id[] memory ids = new Id[](1);
        ids[0] = id;
        vm.expectRevert(expected);
        vm.prank(CREATOR);
        facade.unbanGuardianSignals(ids, address(1));
    }

    // ---
    // FEES
    // ---

    /// @notice A `FEE_MANAGER_ROLE` holder sets a market fee; the core emits `SetFee`.
    function test_setFee_withRole_setsFee() public {
        _grant(facade.MARKET_CREATOR_ROLE(), CREATOR);
        _grant(facade.FEE_MANAGER_ROLE(), FEE_MGR);
        MarketParams memory p = _params(3);
        Id id = p.id();
        vm.prank(CREATOR);
        facade.createMarket(p);

        uint256 newFee = 0.1e18; // <= MAX_FEE (0.25e18)
        vm.expectEmit(true, true, true, true, address(core));
        emit SetFee(id, newFee);
        vm.prank(FEE_MGR);
        facade.setFee(p, newFee);

        uint128 fee = core.market(id).fee;
        assertEq(fee, newFee, "fee set");
    }

    /// @notice Setting a fee without the role reverts at the facade's gate.
    function testRevert_setFee_withoutRole() public {
        _grant(facade.MARKET_CREATOR_ROLE(), CREATOR);
        MarketParams memory p = _params(3);
        vm.prank(CREATOR);
        facade.createMarket(p);

        bytes32 role = facade.FEE_MANAGER_ROLE();
        vm.expectRevert(_unauthorized(FEE_MGR, role));
        vm.prank(FEE_MGR);
        facade.setFee(p, 0.1e18);
    }

    /// @notice A foreign role cannot set fees: the market creator is rejected at the facade's gate.
    function testRevert_setFee_wrongRole() public {
        _grant(facade.MARKET_CREATOR_ROLE(), CREATOR);
        MarketParams memory p = _params(3);
        vm.prank(CREATOR);
        facade.createMarket(p);

        bytes32 role = facade.FEE_MANAGER_ROLE();
        vm.expectRevert(_unauthorized(CREATOR, role));
        vm.prank(CREATOR);
        facade.setFee(p, 0.1e18);
    }

    /// @notice A `FEE_MANAGER_ROLE` holder sets the global fee recipient; the core emits `SetFeeRecipient`.
    function test_setFeeRecipient_withRole_setsRecipient() public {
        _grant(facade.FEE_MANAGER_ROLE(), FEE_MGR);
        address recipient = address(0x1234);

        vm.expectEmit(true, true, true, true, address(core));
        emit SetFeeRecipient(recipient);
        vm.prank(FEE_MGR);
        facade.setFeeRecipient(recipient);

        assertEq(core.feeRecipient(), recipient, "fee recipient set");
    }

    /// @notice Setting the fee recipient without the role reverts at the facade's gate.
    function testRevert_setFeeRecipient_withoutRole() public {
        bytes32 role = facade.FEE_MANAGER_ROLE();
        vm.expectRevert(_unauthorized(FEE_MGR, role));
        vm.prank(FEE_MGR);
        facade.setFeeRecipient(address(0x1234));
    }

    // ---
    // OWNERSHIP TRANSFER
    // ---

    /// @notice `DEFAULT_ADMIN_ROLE` hands the core's ownership away; the core emits `SetOwner`.
    function test_transferCoreOwnership_byAdmin_movesOwner() public {
        address newOwner = address(0xBEEF);

        vm.expectEmit(true, true, true, true, address(core));
        emit SetOwner(newOwner);
        vm.prank(ADMIN);
        facade.transferLidoLendOwnership(newOwner);

        assertEq(core.owner(), newOwner, "core owner moved");
    }

    /// @notice Only `DEFAULT_ADMIN_ROLE` may transfer core ownership; a market creator cannot.
    function testRevert_transferCoreOwnership_withoutAdmin() public {
        _grant(facade.MARKET_CREATOR_ROLE(), CREATOR);
        bytes32 role = facade.DEFAULT_ADMIN_ROLE();
        vm.expectRevert(_unauthorized(CREATOR, role));
        vm.prank(CREATOR);
        facade.transferLidoLendOwnership(address(0xBEEF));
    }

    /// @notice Transferring ownership to the zero address is rejected before reaching the core.
    function testRevert_transferCoreOwnership_zeroAddress() public {
        vm.prank(ADMIN);
        vm.expectRevert(ILidoLendOwner.ZeroAddress.selector);
        facade.transferLidoLendOwnership(address(0));
    }

    /// @notice After ownership leaves the facade, the facade can no longer drive the core even with a granted
    ///         role: the facade's gate passes, but the core rejects the now-non-owner facade.
    function test_transferCoreOwnership_revokesFacadeControl() public {
        _grant(facade.MARKET_CREATOR_ROLE(), CREATOR);
        vm.prank(ADMIN);
        facade.transferLidoLendOwnership(address(0xBEEF));

        MarketParams memory p = _params(1);
        vm.expectRevert("not owner"); // core's onlyOwner string require
        vm.prank(CREATOR);
        facade.createMarket(p);
    }

    // ---
    // ROLE MANAGEMENT
    // ---

    /// @notice A revoked role loses access: a former market creator can no longer create markets.
    function testRevert_createMarket_afterRevoke() public {
        bytes32 role = facade.MARKET_CREATOR_ROLE();
        _grant(role, CREATOR);
        vm.prank(ADMIN);
        facade.revokeRole(role, CREATOR);

        MarketParams memory p = _params(1);
        vm.expectRevert(_unauthorized(CREATOR, role));
        vm.prank(CREATOR);
        facade.createMarket(p);
    }

    // ---
    // CONSTRUCTOR
    // ---

    /// @dev Constructing the facade with a zero core address reverts with `ZeroAddress`.
    function testRevert_constructor_zeroCore() public {
        vm.expectRevert(ILidoLendOwner.ZeroAddress.selector);
        new LidoLendOwner(ILidoLend(address(0)), ADMIN, address(0), address(0));
    }

    /// @dev Constructing the facade with a zero admin address reverts with `ZeroAddress`.
    function testRevert_constructor_zeroAdmin() public {
        vm.expectRevert(ILidoLendOwner.ZeroAddress.selector);
        new LidoLendOwner(core, address(0), address(0), address(0));
    }

    /// @notice The constructor grants the capability roles to the provided holders; `address(0)` grants none.
    function test_constructor_grantsProvidedRoleHolders() public {
        LidoLendOwner f = new LidoLendOwner(core, ADMIN, CREATOR, FEE_MGR);
        assertTrue(f.hasRole(f.DEFAULT_ADMIN_ROLE(), ADMIN), "admin holds DEFAULT_ADMIN_ROLE");
        assertTrue(f.hasRole(f.MARKET_CREATOR_ROLE(), CREATOR), "market creator granted at construction");
        assertTrue(f.hasRole(f.FEE_MANAGER_ROLE(), FEE_MGR), "fee manager granted at construction");

        LidoLendOwner g = new LidoLendOwner(core, ADMIN, address(0), address(0));
        assertFalse(g.hasRole(g.MARKET_CREATOR_ROLE(), address(0)), "zero market creator not granted");
        assertFalse(g.hasRole(g.FEE_MANAGER_ROLE(), address(0)), "zero fee manager not granted");
    }
}
