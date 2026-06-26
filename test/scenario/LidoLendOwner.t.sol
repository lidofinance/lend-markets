// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {ILidoLend} from "@lido-lend/src/interfaces/ILidoLend.sol";
import {Id, MarketParams} from "@lido-lend/src/interfaces/IMorpho.sol";
import {MarketParamsLib} from "@lido-lend/src/libraries/MarketParamsLib.sol";
import {ControllerMock} from "@lido-lend/src/mocks/ControllerMock.sol";
import {IrmMock} from "@lido-lend/src/mocks/IrmMock.sol";

import {LidoLendOwner} from "../../src/LidoLendOwner.sol";
import {ILidoLendOwner} from "../../src/interfaces/ILidoLendOwner.sol";

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
        // Core impl is pinned to solc 0.8.30, so it is deployed from its compiled artifact via `getCode`. That
        // artifact is emitted only when `test/utils/_LidoLendCompileTrigger.sol` compiles, which a full
        // `forge test` does but a filtered (`--match-path`/`--match-contract`) sparse compile does not. Detect
        // its absence and skip with a clear reason instead of failing with an opaque `getCode` error.
        bytes memory creationCode;
        try this.coreCreationCode() returns (bytes memory code) {
            creationCode = code;
        } catch {
            vm.skip(true, "requires full `forge test`: LidoLend artifact absent under sparse (filtered) compilation");
            return;
        }

        address impl;
        assembly ("memory-safe") {
            impl := create(0, add(creationCode, 0x20), mload(creationCode))
        }
        require(impl != address(0), "core impl deploy failed");
        bytes memory initData = abi.encodeWithSignature("initialize(address)", address(this));
        core = ILidoLend(address(new ERC1967Proxy(impl, initData)));

        // Market creation makes the core call `irm.borrowRate`, so a real (mock) IRM contract is required.
        irm = address(new IrmMock());

        // Capability roles left unset here; granted per test via `_grant` (the constructor-granting path is
        // covered separately).
        facade = new LidoLendOwner(core, ADMIN, address(0), address(0));
        // `initialize` made this test the core owner; hand it to the facade.
        core.setOwner(address(facade));
    }

    /// @dev External wrapper so the `getCode` cheatcode revert (artifact absent) is catchable in `setUp`.
    function coreCreationCode() external returns (bytes memory) {
        return vm.getCode("lib/lido-lend/src/LidoLend.sol:LidoLend");
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
    ///         first-use sequence `EnableIrm`, `EnableLltv`, `CreateMarket`.
    function test_createMarket_withRole_createsMarket() public {
        _grant(facade.MARKET_CREATOR_ROLE(), CREATOR);
        MarketParams memory p = _params(1);
        Id id = p.id();

        vm.expectEmit(true, true, true, true, address(core));
        emit EnableIrm(irm);
        vm.expectEmit(true, true, true, true, address(core));
        emit EnableLltv(p.lltv);
        vm.expectEmit(true, true, true, true, address(core));
        emit CreateMarket(id, p);
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
        emit EnableIrm(irm);
        vm.expectEmit(true, true, true, true, address(core));
        emit EnableLltv(p.lltv);
        vm.expectEmit(true, true, true, true, address(core));
        emit SetMarketController(id, address(controller));
        vm.expectEmit(true, true, true, true, address(core));
        emit EnableSettlement(id);
        vm.expectEmit(true, true, true, true, address(core));
        emit CreateMarket(id, p);
        vm.prank(CREATOR);
        facade.createMarket(p, address(controller), true);

        assertEq(core.marketController(id), address(controller), "controller bound");
        assertTrue(core.isSettlementEnabled(id), "settlement enabled");
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
        facade.transferCoreOwnership(newOwner);

        assertEq(core.owner(), newOwner, "core owner moved");
    }

    /// @notice Only `DEFAULT_ADMIN_ROLE` may transfer core ownership; a market creator cannot.
    function testRevert_transferCoreOwnership_withoutAdmin() public {
        _grant(facade.MARKET_CREATOR_ROLE(), CREATOR);
        bytes32 role = facade.DEFAULT_ADMIN_ROLE();
        vm.expectRevert(_unauthorized(CREATOR, role));
        vm.prank(CREATOR);
        facade.transferCoreOwnership(address(0xBEEF));
    }

    /// @notice Transferring ownership to the zero address is rejected before reaching the core.
    function testRevert_transferCoreOwnership_zeroAddress() public {
        vm.prank(ADMIN);
        vm.expectRevert(ILidoLendOwner.ZeroAddress.selector);
        facade.transferCoreOwnership(address(0));
    }

    /// @notice After ownership leaves the facade, the facade can no longer drive the core even with a granted
    ///         role: the facade's gate passes, but the core rejects the now-non-owner facade.
    function test_transferCoreOwnership_revokesFacadeControl() public {
        _grant(facade.MARKET_CREATOR_ROLE(), CREATOR);
        vm.prank(ADMIN);
        facade.transferCoreOwnership(address(0xBEEF));

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

    function testRevert_constructor_zeroCore() public {
        vm.expectRevert(ILidoLendOwner.ZeroAddress.selector);
        new LidoLendOwner(ILidoLend(address(0)), ADMIN, address(0), address(0));
    }

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
