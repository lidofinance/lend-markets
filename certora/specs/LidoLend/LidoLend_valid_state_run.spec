// Verifies the invariants in the scene where the CVL controller stub is attached. Hence a file of
// its own: the pack itself lives one level up, so a joint scene can take it without the stub.

import "LidoLend_valid_state.spec";
import "../setup/LidoLendMarketController/LidoLendMarketController_cvl.spec";

use invariant feeCapped;
use invariant lastUpdateNotInFuture;
use invariant lastUpdateMinBound;
use invariant borrowLeSupplyAssets;
use invariant supplySharesSumCorrect;
use invariant borrowSharesSumCorrect;
use invariant borrowerCollateralizedUnlessSettlement;
use invariant zeroAddressNeverAuthorizes;
use invariant tokenBackingSolvency;
