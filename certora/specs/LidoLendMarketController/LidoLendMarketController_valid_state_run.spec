// Verifies the invariants in the scene where the CVL core stub is attached. Hence a file of
// its own: the pack itself lives one level up, so a joint scene can take it without the stub.

import "LidoLendMarketController_valid_state.spec";
import "../setup/LidoLend/LidoLend_cvl.spec";
import "../setup/GuardianSignals/GuardianSignals_cvl.spec";

use invariant heapIndexToSlot;
use invariant heapSlotToAccount;
use invariant heapSlotBounded;
use invariant heapTailKeyZero;
use invariant heapParentKeyDominatesChild;
use invariant activatingRequiresTimerStart;
use invariant clearedTimerClearsDelay;
use invariant timerStartRequiresActivating;
use invariant timerStartRequiresDelay;
use invariant timerStartNotInFuture;
use invariant inflowSnapshotNotInFuture;
use invariant activatingDelayCapped;
use invariant minDelayLeMaxDelay;
use invariant maxActivationDelayCapped;
use invariant activatingLockDurationCapped;
use invariant quorumDelayZeroOrAboveMaxDelay;
use invariant maxGuardiansQuorumDelayCapped;
use invariant delayPerStrikeCapped;
use invariant delayPerSuspectCapped;
use invariant sliceFloorBpsCapped;
use invariant ltvStepBpsCapped;
use invariant settlementLtvBelowWad;
