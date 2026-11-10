// The standard GuardianSignals scene: base mirrors and hooks, with the role mutators and the external quorum
// scan entry cut. Cutting that entry does not remove the sync, since heartbeat calls it internally, so the
// frontier can still move under these rules.

import "GuardianSignals_base.spec";

methods {
    // Scene cleanup: the cut quorum-scan entry has its own rules in GuardianSignals_frontier.spec.
    function GuardianSignals.grantRole(bytes32, address) external => NONDET DELETE;
    function GuardianSignals.revokeRole(bytes32, address) external => NONDET DELETE;
    function GuardianSignals.renounceRole(bytes32, address) external => NONDET DELETE;
    function GuardianSignals.syncQuorumFrontier() external => NONDET DELETE;
}
