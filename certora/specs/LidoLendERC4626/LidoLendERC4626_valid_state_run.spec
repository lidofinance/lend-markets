// Verifies the invariants in the scene where the CVL core and controller stubs are attached. Hence a file
// of its own: the pack itself lives one level up, so a joint scene can take it without the stubs.

import "LidoLendERC4626_valid_state.spec";
import "../setup/LidoLendERC4626/LidoLendERC4626_valid_state_cvl.spec";
import "../setup/LidoLendMarketController/LidoLendMarketController_cvl.spec";

use invariant assetIsLoanToken;
use invariant marketIdCanonical;
use invariant offsetBounded;
use invariant managedSharesBackedByCorePosition;
