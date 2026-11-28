// CVL model of the ERC-4626 surface a book calls on a symbolic vault: the underlying token is a frozen
// per-callee draw, so every read of a given vault answers the same token within a rule. The wildcard is
// UNRESOLVED: the vault's own scene runs its native code, a book call through the unlinked vaultOf lands here.

methods {
    // TRUSTED: the summary is total, so a vault that reverts on a read is out of scene.
    function _.asset() external
        => ghostErc4626Asset[calledContract] expect address UNRESOLVED;
}

persistent ghost mapping(address => address) ghostErc4626Asset {
    init_state axiom forall address v. ghostErc4626Asset[v] == 0;
}
