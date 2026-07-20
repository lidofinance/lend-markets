// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {LidoLendMarketFactory} from "../../src/periphery/LidoLendMarketFactory.sol";
import {LidoLendERC4626} from "../../src/LidoLendERC4626.sol";
import {GuardianSignals} from "../../src/GuardianSignals.sol";
import {ILidoLendERC4626} from "../../src/interfaces/ILidoLendERC4626.sol";
import {Erc4626ExitBook} from "../../src/periphery/Erc4626ExitBook.sol";
import {PriorityRamp} from "../../src/types/ExitBookTypes.sol";

import {LidoLendSetup} from "../setup/LidoLendSetup.sol";
import {Market} from "../setup/Types.sol";
import {MarketActions} from "../setup/MarketActions.sol";
import {MockERC20} from "../setup/Mocks.sol";

/// @notice `LidoLendMarketFactory.deployVault` is a standalone, reusable handle, not only the internal step
///         `deployMarketContracts` takes. This scenario proves it on an already-ACTIVATED market (via the
///         `LidoLendSetup` harness): a vault it deploys against a live controller works immediately — no
///         separate registration — shares the market's supply cap and pause with the original vault, and only
///         its exit-book path needs a further governance step (`Erc4626ExitBook.setVaultAllowed`).
contract DeployVaultScenarioTest is LidoLendSetup {
    using MarketActions for Market;

    uint256 internal constant MAX_LIFETIME = 30 days;

    LidoLendMarketFactory internal factory;

    function setUp() public {
        MockERC20 loan = new MockERC20("Loan", "LOAN", 18);
        MockERC20 collateral = new MockERC20("Collateral", "COLL", 18);
        _deployProtocol(_defaultConfig(address(loan), address(collateral), address(collateral)));

        Market storage m = _m();
        // A standalone factory over the market's own controller impl + a fresh vault impl targeting the same
        // core — this test only exercises `deployVault`, not the full `LidoLendMarketBuilder` deploy flow.
        factory = new LidoLendMarketFactory(
            m.controllerImpl, address(new LidoLendERC4626(address(m.core))), address(new GuardianSignals())
        );
    }

    function _m() internal view returns (Market storage) {
        return protocol.markets[0];
    }

    function test_deployVault_worksImmediatelyOnActivatedMarket() external {
        Market storage m = _m();
        address vault2Addr =
            factory.deployVault(m.params, address(m.controller), "Second Vault", "lidoLOAN2", address(this));
        ILidoLendERC4626 vault2 = ILidoLendERC4626(vault2Addr);

        assertEq(address(vault2.asset()), address(m.loanToken), "vault2 asset");

        address lender = _actor("lender");
        _fund(m.loanToken, lender, 100 ether);

        vm.startPrank(lender);
        m.loanToken.approve(vault2Addr, 100 ether);
        uint256 shares = vault2.deposit(100 ether, lender);
        vm.stopPrank();
        assertGt(shares, 0, "deposit works with no extra registration");

        vm.prank(lender);
        vault2.withdraw(40 ether, lender, lender);
        assertEq(m.loanToken.balanceOf(lender), 40 ether, "withdraw works with no extra registration");
    }

    function test_deployVault_sharesSupplyCapWithOriginalVault() external {
        Market storage m = _m();
        // MANAGER_ROLE was granted to `admin` == address(this) in `_addMarket`.
        m.controller.setSupplyCap(150 ether);

        address vault2Addr =
            factory.deployVault(m.params, address(m.controller), "Second Vault", "lidoLOAN2", address(this));
        ILidoLendERC4626 vault2 = ILidoLendERC4626(vault2Addr);

        address lenderA = _actor("lenderA");
        _fund(m.loanToken, lenderA, 100 ether);
        m.vaultDeposit(lenderA, 100 ether); // through vault1

        // Only 50 ether of headroom remains under the shared 150 ether cap, no matter which vault asks.
        assertEq(m.vault.maxDeposit(lenderA), 50 ether, "vault1 sees the shared cap");
        assertEq(vault2.maxDeposit(address(0)), 50 ether, "vault2 sees the SAME shared cap");

        address lenderB = _actor("lenderB");
        _fund(m.loanToken, lenderB, 100 ether);
        vm.startPrank(lenderB);
        m.loanToken.approve(vault2Addr, 100 ether);
        vm.expectRevert(); // ERC4626-standard max-deposit guard, enforced against the SHARED market cap
        vault2.deposit(100 ether, lenderB);
        vault2.deposit(50 ether, lenderB); // exactly the remaining headroom
        vm.stopPrank();

        assertEq(m.vault.maxDeposit(lenderB), 0, "cap now fully used, seen from either vault");
    }

    function testRevert_deployVault_controllerFromAnotherMarket() external {
        Market storage m = _m();

        MockERC20 loan2 = new MockERC20("Loan2", "LOAN2", 18);
        MockERC20 collateral2 = new MockERC20("Collateral2", "COLL2", 18);
        _deployProtocol(_defaultConfig(address(loan2), address(collateral2), address(collateral2)));
        Market storage m2 = protocol.markets[1];

        vm.expectRevert(ILidoLendERC4626.ControllerMarketMismatch.selector);
        factory.deployVault(m.params, address(m2.controller), "Mismatched Vault", "lidoBAD", address(this));
    }

    function test_deployVault_exitBookGatingIsASeparateGovernanceStep() external {
        Market storage m = _m();
        address vault2Addr =
            factory.deployVault(m.params, address(m.controller), "Second Vault", "lidoLOAN2", address(this));

        address lender = _actor("lender");
        _fund(m.loanToken, lender, 100 ether);
        vm.startPrank(lender);
        m.loanToken.approve(vault2Addr, 100 ether);
        ILidoLendERC4626(vault2Addr).deposit(100 ether, lender);
        vm.stopPrank();

        Erc4626ExitBook book = new Erc4626ExitBook(address(this), MAX_LIFETIME);
        book.grantRole(book.ALLOWLIST_MANAGER_ROLE(), address(this));

        vm.startPrank(lender);
        IERC4626(vault2Addr).approve(address(book), type(uint256).max);
        vm.expectRevert(Erc4626ExitBook.VaultNotAllowed.selector);
        book.placeExitRequest(IERC4626(vault2Addr), 10 ether, _flat(0), block.timestamp + 1 days, false);
        vm.stopPrank();

        book.setVaultAllowed(IERC4626(vault2Addr), true);

        vm.prank(lender);
        book.placeExitRequest(IERC4626(vault2Addr), 10 ether, _flat(0), block.timestamp + 1 days, false);
    }

    function _flat(uint256 rate) internal pure returns (PriorityRamp memory) {
        return PriorityRamp({startRate: rate, endRate: rate, rampStart: 0, rampEnd: 0});
    }
}
