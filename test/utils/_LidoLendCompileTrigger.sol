// SPDX-License-Identifier: GPL-2.0-or-later
// Flexible pragma trigger: forces Forge to emit the `LidoLend` artifact (strict 0.8.19) under
// `out/` for TEST runs, so `LidoLendDeployer._deployCore` can pick it up via `vm.getCode`.
// `script/_LidoLendCompileTrigger.sol` covers `forge script` runs, which compile src+script only;
// test runs compile src+test, so each side needs its own trigger.
pragma solidity >=0.8.19;

// solhint-disable-next-line no-unused-import
import {LidoLend} from "@lido-lend/src/LidoLend.sol";
