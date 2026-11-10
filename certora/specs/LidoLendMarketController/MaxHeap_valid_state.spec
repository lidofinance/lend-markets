// Structural coherence of the MaxHeapLib container behind the settlement queue: the
// array/index bijection, the zeroed tail, the parent-dominates-child order.

function requireMaxHeapInvariants(env e) {
    requireInvariant heapIndexToSlot(e);
    requireInvariant heapSlotToAccount(e);
    requireInvariant heapSlotBounded(e);
    requireInvariant heapTailKeyZero(e);
    requireInvariant heapParentKeyDominatesChild(e);
}

// MC-VS-01: Every borrower in the settlement queue is indexed at exactly the position they occupy.
invariant heapIndexToSlot(env e)
    forall uint256 i. (1 <= to_mathint(i) && to_mathint(i) < ghostMcHeapNodesLength)
        => to_mathint(ghostMcHeapSlot[ghostMcHeapNodeAccount[i]]) == to_mathint(i)
filtered { f -> !EXCLUDED_FUNCTION_MC(f) } { preserved with (env eFunc) { SETUP_FULL_MC(e, eFunc); } }

// MC-VS-02: The position recorded for a queued borrower really holds that borrower.
invariant heapSlotToAccount(env e)
    forall address a. ghostMcHeapSlot[a] != 0 => ghostMcHeapNodeAccount[ghostMcHeapSlot[a]] == a
filtered { f -> !EXCLUDED_FUNCTION_MC(f) } { preserved with (env eFunc) { SETUP_FULL_MC(e, eFunc); } }

// MC-VS-03: A queued borrower's recorded position always lies inside the queue.
invariant heapSlotBounded(env e)
    forall address a. ghostMcHeapSlot[a] != 0
        => to_mathint(ghostMcHeapSlot[a]) < ghostMcHeapNodesLength
filtered { f -> !EXCLUDED_FUNCTION_MC(f) } { preserved with (env eFunc) { SETUP_FULL_MC(e, eFunc); } }

// MC-VS-04: No place outside the live settlement queue keeps a leftover risk score.
invariant heapTailKeyZero(env e)
    forall uint256 i. (i == 0 || to_mathint(i) >= ghostMcHeapNodesLength) => ghostMcHeapNodeKey256[i] == 0
filtered { f -> !EXCLUDED_FUNCTION_MC(f) } { preserved with (env eFunc) { SETUP_FULL_MC(e, eFunc); } }

// MC-VS-05: The settlement queue always holds the borrower with the highest recorded risk at its top.
invariant heapParentKeyDominatesChild(env e)
    forall uint256 p. forall uint256 c.
        (1 <= to_mathint(p) && to_mathint(c) < ghostMcHeapNodesLength
            && (to_mathint(c) == 2 * to_mathint(p) || to_mathint(c) == 2 * to_mathint(p) + 1))
        => ghostMcHeapNodeKey256[p] >= ghostMcHeapNodeKey256[c]
filtered { f -> !EXCLUDED_FUNCTION_MC(f) } { preserved with (env eFunc) { SETUP_FULL_MC(e, eFunc); } }
