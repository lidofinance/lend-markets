// The file the valid_state conf verifies: re-declares the invariant pack, since `use invariant`
// never propagates through an import.

import "IrmConfigFactory_valid_state.spec";

use invariant vsIcfZeroHashNeverResolvesToAnAdaptiveConfig;
use invariant vsIcfZeroHashNeverResolvesToALinearConfig;
