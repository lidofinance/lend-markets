// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Vm} from "forge-std/Vm.sol";
import {DeployCoreBase} from "../../../script/deployment/DeployCoreBase.s.sol";
import {DeployExitBooksBase} from "../../../script/deployment/DeployExitBooksBase.s.sol";
import {DeployBundlerBase} from "../../../script/deployment/DeployBundlerBase.s.sol";
import {DeployBundlerMainnet} from "../../../script/deployment/mainnet/DeployBundlerMainnet.s.sol";
import {DeployCoreMainnet} from "../../../script/deployment/mainnet/DeployCoreMainnet.s.sol";
import {DeployExitBooksMainnet} from "../../../script/deployment/mainnet/DeployExitBooksMainnet.s.sol";
import {DeployBundlerHoodi} from "../../../script/deployment/hoodi/DeployBundlerHoodi.s.sol";
import {DeployCoreHoodi} from "../../../script/deployment/hoodi/DeployCoreHoodi.s.sol";
import {DeployExitBooksHoodi} from "../../../script/deployment/hoodi/DeployExitBooksHoodi.s.sol";

// The market scripts, imported only so that `forge test` builds the artifacts that `ForkStack` creates.
import {DeployUsdcDejaaaMainnet} from "../../../script/deployment/mainnet/markets/DeployUsdcDejaaaMainnet.s.sol";
import {DeployUsdcDejtrsyMainnet} from "../../../script/deployment/mainnet/markets/DeployUsdcDejtrsyMainnet.s.sol";
import {DeployUsdcJaaaMainnet} from "../../../script/deployment/mainnet/markets/DeployUsdcJaaaMainnet.s.sol";
import {DeployUsdcJtrsyMainnet} from "../../../script/deployment/mainnet/markets/DeployUsdcJtrsyMainnet.s.sol";
import {DeployUsdcUsdyMainnet} from "../../../script/deployment/mainnet/markets/DeployUsdcUsdyMainnet.s.sol";
import {DeployWethWstethMainnet} from "../../../script/deployment/mainnet/markets/DeployWethWstethMainnet.s.sol";
import {DeployUsdcUsdyHoodi} from "../../../script/deployment/hoodi/markets/DeployUsdcUsdyHoodi.s.sol";
import {DeployUsdtUsdyHoodi} from "../../../script/deployment/hoodi/markets/DeployUsdtUsdyHoodi.s.sol";
import {DeployWethWstethHoodi} from "../../../script/deployment/hoodi/markets/DeployWethWstethHoodi.s.sol";
import {DeployUsdcUsdyNavHoodi} from "../../../script/deployment/hoodi/markets/DeployUsdcUsdyNavHoodi.s.sol";
import {DeployUsdcJtrsyHoodi} from "../../../script/deployment/hoodi/markets/DeployUsdcJtrsyHoodi.s.sol";
import {DeployUsdcDejtrsyHoodi} from "../../../script/deployment/hoodi/markets/DeployUsdcDejtrsyHoodi.s.sol";
import {DeployUsdcJaaaHoodi} from "../../../script/deployment/hoodi/markets/DeployUsdcJaaaHoodi.s.sol";
import {DeployUsdcDejaaaHoodi} from "../../../script/deployment/hoodi/markets/DeployUsdcDejaaaHoodi.s.sol";
import {CentrifugeMocks} from "../../../script/deployment/hoodi/CentrifugeMocks.sol";

/// @dev A network's deploy scripts of the core, the exit books and the bundler.
struct ForkNetwork {
    DeployCoreBase core;
    DeployExitBooksBase books;
    DeployBundlerBase bundler;
}

/// @notice The networks the fork tests run against. A market is its deploy script,
///         `script/deployment/<network>/markets/<Script>.s.sol`: the fork tests take the network from the path and
///         create the script from its artifact, which this file's imports build.
library ForkNetworks {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @notice Forks `name` and returns its deploy scripts, created on the fork. The fork is at the latest block of the
    ///         network's RPC, or at its block when set: `RPC_URL` and `FORK_BLOCK` on mainnet, `HOODI_RPC_URL` and
    ///         `HOODI_FORK_BLOCK` on Hoodi. With `FORK_RUN` set, the fork is the latest block of `RPC_URL`, whatever
    ///         the network. A network without an RPC fails the test.
    function fork(string memory name) internal returns (ForkNetwork memory n) {
        requireKnown(name);
        bool hoodi = _eq(name, "hoodi");
        string memory rpc;
        uint256 blockNumber;
        if (bytes(vm.envOr("FORK_RUN", string(""))).length != 0) {
            rpc = vm.envOr("RPC_URL", string(""));
        } else {
            rpc = vm.envOr(hoodi ? string("HOODI_RPC_URL") : string("RPC_URL"), string(""));
            blockNumber = vm.envOr(hoodi ? string("HOODI_FORK_BLOCK") : string("FORK_BLOCK"), uint256(0));
        }
        require(bytes(rpc).length != 0, string.concat("ForkNetworks: no RPC for ", name));
        // A fork at a set block keeps its RPC responses in forge's cache, so a later run at that block is local.
        if (blockNumber != 0) vm.createSelectFork(rpc, blockNumber);
        else vm.createSelectFork(rpc);
        if (hoodi) {
            // The Hoodi Centrifuge markets price against mocks; a fork from before their deployment gets them.
            CentrifugeMocks.deployMissing();
            n.core = new DeployCoreHoodi();
            n.books = new DeployExitBooksHoodi();
            n.bundler = new DeployBundlerHoodi();
        } else {
            n.core = new DeployCoreMainnet();
            n.books = new DeployExitBooksMainnet();
            n.bundler = new DeployBundlerMainnet();
        }
    }

    /// @notice Reverts unless the fork tests know the network `name`: mainnet or hoodi.
    function requireKnown(string memory name) internal pure {
        require(
            _eq(name, "mainnet") || _eq(name, "hoodi"),
            string.concat("ForkNetworks: unknown network '", name, "'; known: mainnet, hoodi")
        );
    }

    /// @notice The network of the market deploy script at `path`: its folder under `script/deployment`.
    function networkOf(string memory path) internal pure returns (string memory) {
        string[] memory parts = vm.split(path, "/");
        require(
            parts.length == 5 && _eq(parts[0], "script") && _eq(parts[1], "deployment") && _eq(parts[3], "markets"),
            string.concat("ForkNetworks: '", path, "' is not script/deployment/<network>/markets/<Script>.s.sol")
        );
        return parts[2];
    }

    /// @notice The name of the market deploy script at `path`: its file name without `.s.sol`.
    function scriptName(string memory path) internal pure returns (string memory) {
        string[] memory parts = vm.split(path, "/");
        return vm.replace(parts[parts.length - 1], ".s.sol", "");
    }

    function _eq(string memory a, string memory b) private pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }
}
