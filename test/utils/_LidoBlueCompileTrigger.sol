// SPDX-License-Identifier: GPL-2.0-or-later
// Flexible pragma trigger: forces Forge to emit the `LidoBlue` artifact (strict 0.8.19) under
// `out/` for TEST runs, so `LidoBlueDeployer._deployCore` can pick it up via `vm.getCode`.
// `script/_LidoBlueCompileTrigger.sol` covers `forge script` runs, which compile src+script only;
// test runs compile src+test, so each side needs its own trigger.
pragma solidity >=0.8.19;

// solhint-disable-next-line no-unused-import
import {LidoBlue} from "@lido-blue/src/LidoBlue.sol";
