// The file the valid_state conf verifies: re-declares the invariant pack, since `use invariant`
// never propagates through an import.

import "LidoLend_LinkedController_valid_state.spec";
// SAFE: Math.mulDiv in its CVL model; no settle path product reaches 2^256.
import "../setup/math.spec";

use invariant heapKeyFreshCoreBacked;
use invariant heapMembershipMatchesCoreLifecycle;
use invariant activationBucketsBackedByCoreCollateral;
