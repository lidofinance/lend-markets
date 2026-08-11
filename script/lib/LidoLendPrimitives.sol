// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {LidoLend} from "@lido-lend/src/LidoLend.sol";
import {ILidoLend} from "@lido-lend/src/interfaces/ILidoLend.sol";
import {IrmRouter} from "@lido-lend-irm/src/irm-router/IrmRouter.sol";

import {GuardianSignals} from "../../src/GuardianSignals.sol";
import {LidoLendOwner} from "../../src/periphery/LidoLendOwner.sol";
import {OssifiableProxy} from "../../src/proxy/OssifiableProxy.sol";

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

    function _deployGuardianSignals(address impl, address admin, address[] memory guardians, uint256 quorum)
        internal
        virtual
        returns (address)
    {
        return _behindProxy(impl, admin, abi.encodeCall(GuardianSignals.initialize, (admin, guardians, quorum)));
    }

    function _behindProxy(address impl, address admin, bytes memory initData) internal returns (address) {
        return address(new OssifiableProxy(impl, admin, initData));
    }

    function _deployIrm(address core, address owner) internal virtual returns (address) {
        address impl = address(new IrmRouter(core));
        return _behindProxy(impl, owner, abi.encodeCall(IrmRouter.initialize, (owner, owner)));
    }
}
