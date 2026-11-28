// Folded lane for controller high_level rules timing out in the parent, with Math.mulDiv cut to its CVL model.
// Exact here: no product the controller forms reaches 2^256, so no quotient is pruned.

import "../LidoLendMarketController_high_level.spec";
import "../../setup/math.spec";

use rule hlMcActivationDelayMonotoneBanded;
use rule hlMcInflowDecayLaws;
use rule hlMcRootSliceHonorsPolicyFloors;
use rule hlMcSettlementQuoteFitsBudget;
use rule hlMcSettlementSliceConservesDebt;
use rule hlMcSettlementViewsAgreeBorrow;
use rule hlMcSettlementViewsAgreeRemainder;
use rule hlMcSettlementViewsAgreeSupply;
use rule hlMcTopUpDeadlineIsMaxOfOldAndQuote;
