// SPDX-License-Identifier: GPL-2.0-or-later
// Flexible pragma trigger: forces Forge to emit the `LidoBlue` artifact (strict 0.8.19) under
// `out/` so `LidoBlueDeployer._deployCore` can pick it up via `vm.getCode`. The deploy script and
// our scenario tests all run on 0.8.35; this isolated trigger is the only place that touches the
// strict-0.8.19 concrete type. Forge script compiles src+script (not test), so a script-side
// trigger is required for `forge script DeployMarket` runs.
pragma solidity >=0.8.19;

// solhint-disable-next-line no-unused-import
import {LidoBlue} from "@lido-blue/src/LidoBlue.sol";
