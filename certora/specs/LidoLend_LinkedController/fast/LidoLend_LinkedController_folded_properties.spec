// Folded lane for linked scene timeouts in the parent, plus hlLwcMaxWithdrawableQuoteAccrualInvariant for its mutant.
// Math.mulDiv is cut to its CVL model; exact here, as no controller product reaches 2^256.

import "../LidoLend_LinkedController_properties.spec";
import "../../setup/math.spec";

use rule hlLwcBorrowLeavesDebtCoveredByActiveCollateral;
use rule hlLwcMaxWithdrawableIsWithdrawableEndToEnd;
use rule hlLwcMaxWithdrawableQuoteAccrualInvariant;
use rule hlLwcWithdrawCollateralLeavesDebtCoveredByActiveCollateral;
use rule rcLwcAccrualLiftsFeeRecipientQuote;
use rule rcLwcSettleAtRootCutsDebt;
use rule rcLwcSettleCutsDebtWithIdleLiquidityPresent;
