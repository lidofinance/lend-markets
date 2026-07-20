// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {LidoLend} from "@lido-lend/src/LidoLend.sol";
import {ILidoLend} from "@lido-lend/src/interfaces/ILidoLend.sol";
import {IrmRouter} from "@lido-lend-irm/src/irm-router/IrmRouter.sol";

import {GuardianSignals} from "../../src/GuardianSignals.sol";
import {LidoLendOwner} from "../../src/periphery/LidoLendOwner.sol";
import {OssifiableProxy} from "../../src/proxy/OssifiableProxy.sol";

/// @notice Low-level, market-agnostic deploy steps shared by every deploy path (core, owner facade,
///         GuardianSignals, IRM router, and the `OssifiableProxy` wrapper). No market or curve logic.
abstract contract LidoLendPrimitives {
    function _deployCore(address admin) internal virtual returns (address) {
        address impl = address(new LidoLend());
        return _behindProxy(impl, admin, abi.encodeCall(LidoLend.initialize, (admin)));
    }

    function _deployOwnerFacade(address core, address admin, address marketCreator, address feeManager)
        internal
        virtual
        returns (address)
    {
        return address(new LidoLendOwner(ILidoLend(core), admin, marketCreator, feeManager));
    }

    /// @dev `proxyAdmin` is separate from `initAdmin` so the two can end at different holders; the suspect
    ///      window is set after deploy.
    function _deployGuardianSignals(
        address impl,
        address initAdmin,
        address proxyAdmin,
        address[] memory guardians,
        uint256 quorum
    ) internal virtual returns (address) {
        return _behindProxy(
            impl, proxyAdmin, abi.encodeCall(GuardianSignals.initialize, (initAdmin, guardians, quorum))
        );
    }

    function _behindProxy(address impl, address admin, bytes memory initData) internal returns (address) {
        return address(new OssifiableProxy(impl, admin, initData));
    }

    function _deployIrm(address core, address owner) internal virtual returns (address) {
        // The market's immutable `irm` points at this router, which forwards `borrowRate` to a switchable
        // per-market model. owner == manager == `owner`.
        address impl = address(new IrmRouter(core));
        return _behindProxy(impl, owner, abi.encodeCall(IrmRouter.initialize, (owner, owner)));
    }
}
