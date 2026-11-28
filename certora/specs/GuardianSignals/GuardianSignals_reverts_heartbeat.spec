// One revert rule: a heartbeat reporting a block outside the 256 block blockhash window is rejected. It sits
// on its own scene because the blockhash window is pinned by a scene global hook, assumed as EVM semantics
// rather than proved here.

import "GuardianSignals_valid_state.spec";

// The current block number, pinned by each rule to its env: an opcode hook cannot read the environment.
persistent ghost mathint ghostGsCurrentBlockNumber;

hook BLOCKHASH(uint n) bytes32 h {
    require((to_mathint(n) >= ghostGsCurrentBlockNumber
        || to_mathint(n) + 256 < ghostGsCurrentBlockNumber) => h == to_bytes32(0),
        "SAFE: blockhash is zero outside the recent 256 block window");
}

// GS-RV-25: A heartbeat naming the current block, or one more than 256 blocks old, fails.
rule rvGsHeartbeatRevertsOnAgedOutBlock(env e, GuardianSignals.BlockInfoWithHash blk) {

    setupGuardianSignalsValidState(e);
    require(ghostGsCurrentBlockNumber == to_mathint(e.block.number),
        "SAFE: the hook's block mirror is this call's block number");
    bool outsideWindow = to_mathint(blk.number) + 256 < to_mathint(e.block.number)
        || to_mathint(blk.number) >= to_mathint(e.block.number);

    heartbeat@withrevert(e, e.msg.sender, blk);
    bool reverted = lastReverted;

    assert(outsideWindow => reverted,
        "heartbeat rejects a block outside the 256-block blockhash window");
}
