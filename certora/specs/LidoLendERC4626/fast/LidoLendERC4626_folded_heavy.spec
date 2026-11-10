// Folded lane for vault settle and fallbackExit rules timing out in the parent, with Math.mulDiv cut to its CVL model.
// A quotient wider than 256 bits is pruned rather than reverted.

import "../LidoLendERC4626_high_level.spec";
import "../../setup/math.spec";

use rule hlVaFallbackExitBurnsProRataOfConsumedBudget;
use rule hlVaSettleDoesNotDiluteRemainingHolders;
use rule hlVaSettleBurnsProRataOfConsumedBudget;
