// The standard scene: role administration is out of it. Every spec file under specs/LidoLendMarketController/
// reaches this file except LidoLendMarketController_access_control_roles.spec and the harness-only
// SettlementSlice_properties.spec, so its method set is the one those rules are proved on.

import "LidoLendMarketController_base.spec";

methods {
    function LidoLendMarketController.grantRole(bytes32, address) external => NONDET DELETE;
    function LidoLendMarketController.revokeRole(bytes32, address) external => NONDET DELETE;
    function LidoLendMarketController.renounceRole(bytes32, address) external => NONDET DELETE;
}
