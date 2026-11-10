// The file the valid_state conf verifies: re-declares the invariant pack, since `use invariant`
// never propagates through an import.

import "MorphoExitBook_LinkedCore_valid_state.spec";

use invariant meServiceFeeCapped;
use invariant meServiceFeeHasRecipient;
use invariant meZeroIdNeverCreated;
use invariant meForwardIdsNeverCreated;
use invariant meIssuedIdsDense;
use invariant meUncreatedAssetZero;
use invariant meUncreatedAssetsRemainingZero;
use invariant meUncreatedAssetsTotalZero;
use invariant meUncreatedMinFillZero;
use invariant meUncreatedStartRateZero;
use invariant meUncreatedEndRateZero;
use invariant meUncreatedRampStartZero;
use invariant meUncreatedRampEndZero;
use invariant meUncreatedCreatedAtZero;
use invariant meUncreatedDeadlineZero;
use invariant meUncreatedMaxShareBurnZero;
use invariant meUncreatedStatusNotCreated;
use invariant meRemainingImpliesOpen;
use invariant meOpenImpliesRemaining;
use invariant meRemainingLeTotal;
use invariant meCreatedAssetsTotalPositive;
use invariant meStartRateLeEndRate;
use invariant meEndRateCapped;
use invariant meRampStartLeRampEnd;
use invariant meRampEndsByDeadline;
use invariant meDeadlineAfterCreation;
use invariant meDeadlineWithinLifetime;
use invariant meCreatedAtNotInFuture;
use invariant meZeroOwnerNoIds;
use invariant meOwnerIndexIssued;
use invariant meOwnerIndexOwnership;
use invariant meOwnerIndexStrictlyIncreasing;
use invariant meZeroMarketIdNeverAllowed;
use invariant meCreatedIffMarketBound;
use invariant meAllowedMarketHasParamsRow;
use invariant meBoundMarketHasParamsRow;
use invariant meCreatedAssetIsMarketLoanToken;
use invariant meParamsRowMarketExistsOnCore;
use invariant meMinFillWithinTotal;
use invariant meOwnerIndexLenLeNextId;
use invariant meParamsRowCanonical;
use invariant meUncreatedReceiverZero;
use invariant meCreatedReceiverSet;
