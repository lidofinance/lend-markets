// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {Id} from "@lido-lend/src/interfaces/IMorpho.sol";

import {GuardianSignals} from "../../src/GuardianSignals.sol";
import {ILidoLendERC4626} from "../../src/interfaces/ILidoLendERC4626.sol";
import {LidoLendERC4626} from "../../src/LidoLendERC4626.sol";
import {Erc4626ExitBook} from "../../src/periphery/Erc4626ExitBook.sol";
import {LidoLendMarketFactory} from "../../src/periphery/LidoLendMarketFactory.sol";
import {LidoLendOwner} from "../../src/periphery/LidoLendOwner.sol";
import {RiskStewardDashboard} from "../../src/periphery/RiskStewardDashboard.sol";
import {PriorityRamp} from "../../src/types/ExitBookTypes.sol";

import {LidoLendSetup} from "../setup/LidoLendSetup.sol";
import {Market} from "../setup/Types.sol";
import {MarketActions} from "../setup/MarketActions.sol";
import {MockERC20} from "../setup/Mocks.sol";

contract DeployVaultCircuitBreakerStub {}

/// @notice The factory can deploy an additional vault over an already active canonical controller. The vault
///         works without separate core registration and shares market-level policy with existing vaults.
contract DeployVaultScenarioTest is LidoLendSetup {
    using MarketActions for Market;

    uint256 internal constant MAX_LIFETIME = 30 days;

    LidoLendMarketFactory internal factory;

    function setUp() public {
        MockERC20 loan = new MockERC20("Loan", "LOAN", 18);
        MockERC20 collateral = new MockERC20("Collateral", "COLL", 18);
        _deployProtocol(_defaultConfig(address(loan), address(collateral), address(collateral)));

        MockERC20 loan2 = new MockERC20("Loan2", "LOAN2", 18);
        MockERC20 collateral2 = new MockERC20("Collateral2", "COLL2", 18);
        _deployProtocol(_defaultConfig(address(loan2), address(collateral2), address(collateral2)));

        Market storage m = _m();
        LidoLendOwner owner = new LidoLendOwner(m.core, address(this), address(0), address(0));
        m.core.setOwner(address(owner));
        factory = new LidoLendMarketFactory(
            LidoLendMarketFactory.Implementations({
                controller: m.controllerImpl,
                erc4626Wrapper: address(new LidoLendERC4626(address(m.core))),
                guardianSignals: address(new GuardianSignals())
            }),
            LidoLendMarketFactory.Dependencies({
                lidoLend: address(m.core),
                irmRouter: m.params.irm,
                lidoLendOwner: address(owner),
                circuitBreaker: address(new DeployVaultCircuitBreakerStub()),
                riskStewardDashboard: address(new RiskStewardDashboard(address(this), m.core))
            }),
            address(this)
        );
    }

    function _m() internal view returns (Market storage) {
        return protocol.markets[0];
    }

    function test_deployERC4626Wrapper_worksImmediatelyOnActivatedMarket() external {
        Market storage m = _m();
        address vault2Addr = _deploySecondVault(m);
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

    function test_deployERC4626Wrapper_sharesSupplyCapWithOriginalVault() external {
        Market storage m = _m();
        // MANAGER_ROLE was granted to `admin` == address(this) in `_addMarket`.
        m.controller.setSupplyCap(150 ether);

        address vault2Addr = _deploySecondVault(m);
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

    function testRevert_deployERC4626Wrapper_marketParamsFromAnotherMarket() external {
        Market storage m = _m();
        Market storage m2 = protocol.markets[1];

        vm.expectRevert(
            abi.encodeWithSelector(LidoLendMarketFactory.MarketIdMismatch.selector, Id.unwrap(m2.id), Id.unwrap(m.id))
        );
        factory.deployERC4626Wrapper(
            address(m.controller),
            m2.params,
            LidoLendMarketFactory.ERC4626WrapperSpec({name: "Mismatched Vault", symbol: "lidoBAD"})
        );
    }

    function test_deployERC4626Wrapper_exitBookGatingIsASeparateGovernanceStep() external {
        Market storage m = _m();
        address vault2Addr = _deploySecondVault(m);

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
        book.placeExitRequest(IERC4626(vault2Addr), 10 ether, lender, 0, 0, _flat(0), block.timestamp + 1 days);
        vm.stopPrank();

        book.setVaultAllowed(IERC4626(vault2Addr), true);

        vm.prank(lender);
        uint256 id =
            book.placeExitRequest(IERC4626(vault2Addr), 10 ether, lender, 0, 0, _flat(0), block.timestamp + 1 days);

        address filler = _actor("filler");
        vm.prank(filler);
        book.fillExitRequest(id, 10 ether, filler);

        assertEq(m.loanToken.balanceOf(lender), 10 ether, "allowed vault exits through the book");
        assertEq(book.getExitRequest(id).assetsRemaining, 0, "request filled");
    }

    function _flat(uint256 rate) internal pure returns (PriorityRamp memory) {
        return PriorityRamp({startRate: rate, endRate: rate, rampStart: 0, rampEnd: 0});
    }

    function _deploySecondVault(Market storage market) internal returns (address) {
        return factory.deployERC4626Wrapper(
            address(market.controller),
            market.params,
            LidoLendMarketFactory.ERC4626WrapperSpec({name: "Second Vault", symbol: "lidoLOAN2"})
        );
    }
}
