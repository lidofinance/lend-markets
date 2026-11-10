// The file the valid_state conf verifies: re-declares the invariant pack, since `use invariant`
// never propagates through an import.

import "Erc4626ExitBook_LinkedVaultCore_valid_state.spec";

use invariant eeServiceFeeCapped;
use invariant eeServiceFeeHasRecipient;
use invariant eeZeroIdNeverCreated;
use invariant eeForwardIdsNeverCreated;
use invariant eeIssuedIdsDense;
use invariant eeUncreatedAssetZero;
use invariant eeUncreatedAssetsTotalZero;
use invariant eeUncreatedMinFillAssetsZero;
use invariant eeUncreatedStartRateZero;
use invariant eeUncreatedEndRateZero;
use invariant eeUncreatedRampStartZero;
use invariant eeUncreatedRampEndZero;
use invariant eeUncreatedCreatedAtZero;
use invariant eeUncreatedDeadlineZero;
use invariant eeUncreatedMaxShareBurnZero;
use invariant eeUncreatedStatusNotCreated;
use invariant eeRemainingImpliesOpen;
use invariant eeOpenImpliesRemaining;
use invariant eeRemainingLeTotal;
use invariant eeCreatedAssetsTotalPositive;
use invariant eeUncreatedReceiverZero;
use invariant eeStartRateLeEndRate;
use invariant eeEndRateCapped;
use invariant eeRampStartLeRampEnd;
use invariant eeRampEndsByDeadline;
use invariant eeDeadlineAfterCreation;
use invariant eeDeadlineWithinLifetime;
use invariant eeCreatedAtNotInFuture;
use invariant eeZeroOwnerNoIds;
use invariant eeOwnerIndexIssued;
use invariant eeOwnerIndexOwnership;
use invariant eeOwnerIndexStrictlyIncreasing;
use invariant eeZeroVaultNeverAllowed;
use invariant eeCreatedIffVaultBound;
use invariant eeVaultAssetBinding;
use invariant eeCreatedReceiverSet;
use invariant eeOwnerIndexLenLeNextId;
