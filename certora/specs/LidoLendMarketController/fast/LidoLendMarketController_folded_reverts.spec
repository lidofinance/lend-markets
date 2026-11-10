// Folded lane for controller reverts rules timing out in the parent, with Math.mulDiv cut to its CVL model.
// Exact, revert set included: no product the controller forms reaches 2^256, so no quotient is pruned.

import "../LidoLendMarketController_reverts.spec";
import "../../setup/math.spec";

use rule rvMcCurrentActivationDelayNeverReverts;
use rule rvMcNextSettlementBorrowerNeverReverts;
use rule rvMcOnBorrowRevertsAboveActiveCapacity;
use rule rvMcOnBorrowRevertsIff;
use rule rvMcOnSettleRevertsAboveSettleableSupply;
use rule rvMcOnWithdrawCollateralRevertsIff;
use rule rvMcOnWithdrawRevertsWhenRemainingActiveInsufficient;
