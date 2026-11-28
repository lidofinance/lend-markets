// Folded lane for vault EIP-4626 conformance rules timing out in the parent, with Math.mulDiv cut to its CVL model.
// A quotient wider than 256 bits is pruned rather than reverted.

import "../LidoLendERC4626_erc4626.spec";
import "../../setup/math.spec";

use rule depositAtAdvertisedMaxDoesNotRevert;
use rule maxRedeemNeverReverts;
use rule redeemAtAdvertisedMaxDoesNotRevert;
use rule sharesToAssetsRoundTripNeverExceeds;
use rule withdrawAtAdvertisedMaxDoesNotRevert;
