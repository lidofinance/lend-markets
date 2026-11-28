// The file valid_state.conf verifies: `use invariant` never propagates through an import, so the pack is
// re-declared here.

import "LinearKinkIrm_valid_state.spec";

use invariant vsLkiKinkBelowFullUtilization;
use invariant vsLkiPeakRateWithinCap;
use invariant vsLkiUnsetRowCarriesNoParams;
use invariant vsLkiRolesAreLive;
use invariant vsLkiZeroIdRowStaysEmpty;
