// The file the valid_state conf verifies: re-declares the invariant pack, since `use invariant`
// never propagates through an import.

import "AdaptiveCurveIrm_valid_state.spec";

use invariant vsAciRateWithinItsConfigBand;
use invariant vsAciPricedMarketHasConfig;
use invariant vsAciRolesNeverZero;
use invariant vsAciZeroIdNeverConfigured;
