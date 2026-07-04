// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {LidoLendSetup} from "../setup/LidoLendSetup.sol";
import {Market} from "../setup/Types.sol";
import {MockERC20} from "../setup/Mocks.sol";
import {LidoLendERC4626} from "../../src/LidoLendERC4626.sol";
import {ILidoLendERC4626} from "../../src/interfaces/ILidoLendERC4626.sol";
import {OssifiableProxy} from "../../src/proxy/OssifiableProxy.sol";
import {MarketParams} from "@lido-lend/src/interfaces/IMorpho.sol";

/// @notice W4: `LidoLendERC4626.initialize` must reject a controller that governs a different market than the
///         vault's, so a vault cannot be bound to a mismatched controller.
contract VaultControllerBindingTest is LidoLendSetup {
    function setUp() public {
        MockERC20 loan = new MockERC20("Loan", "LOAN", 18);
        MockERC20 collateral = new MockERC20("Collateral", "COLL", 18);
        _deployProtocol(_defaultConfig(address(loan), address(collateral), address(collateral)));
    }

    function _deployVault(MarketParams memory params, address controller) internal returns (address) {
        address impl = address(new LidoLendERC4626(address(protocol.core)));
        bytes memory initData = abi.encodeCall(LidoLendERC4626.initialize, (params, controller, "Vault", "VLT"));
        return address(new OssifiableProxy(impl, address(this), initData));
    }

    function test_W4_initializeRejectsMismatchedController() public {
        Market storage m = protocol.markets[0];

        // A different market id (fresh oracle) but the market's own controller, which governs the original id.
        MarketParams memory rogueParams = m.params;
        rogueParams.oracle = address(0x0AC1E);

        // Deploy the impl first; the mismatch reverts inside the proxy's initialize delegatecall.
        address impl = address(new LidoLendERC4626(address(protocol.core)));
        bytes memory initData =
            abi.encodeCall(LidoLendERC4626.initialize, (rogueParams, address(m.controller), "Rogue", "RGE"));
        vm.expectRevert(ILidoLendERC4626.ControllerMarketMismatch.selector);
        new OssifiableProxy(impl, address(this), initData);
    }

    function test_W4_initializeAcceptsMatchingController() public {
        Market storage m = protocol.markets[0];
        address vault = _deployVault(m.params, address(m.controller));
        assertEq(address(ILidoLendERC4626(vault).controller()), address(m.controller), "matching controller bound");
    }
}
