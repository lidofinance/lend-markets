// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Script, console2} from "forge-std/Script.sol";
import {CentrifugeMocks} from "./CentrifugeMocks.sol";

/// @notice Deploys the Hoodi Centrifuge mocks at their CREATE2 addresses inside a broadcast; one already
///         deployed is left as it is. Run it before the Hoodi Centrifuge markets' scripts.
contract DeployCentrifugeMocksHoodi is Script {
    function run() external {
        require(block.chainid == 560048, "DeployCentrifugeMocksHoodi: Hoodi only");
        vm.startBroadcast();
        CentrifugeMocks.deployMissing();
        vm.stopBroadcast();
        console2.log("member list:", CentrifugeMocks.memberList());
        console2.log("JTRSY:", CentrifugeMocks.jtrsy());
        console2.log("JAAA:", CentrifugeMocks.jaaa());
        console2.log("deJTRSY:", CentrifugeMocks.dejtrsy());
        console2.log("deJAAA:", CentrifugeMocks.dejaaa());
        console2.log("Spoke:", CentrifugeMocks.spoke());
    }
}
