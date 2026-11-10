// Folded lane for vault reverts rules timing out in the parent, with Math.mulDiv cut to its CVL model.
// A quotient wider than 256 bits is pruned rather than reverted, which can weaken only the fallbackExit rule.

import "../LidoLendERC4626_reverts.spec";
import "../../setup/math.spec";

use rule rvVaFallbackExitDoesNotRevertWhenLiquidityCovers;
use rule rvVaSettleRevertsWhenNothingIsSettled;
