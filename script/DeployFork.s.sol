// SPDX-License-Identifier: GPL-2.0-or-later
// Pragma matches MarketAccessRegistry (the strictest local dependency). MorphoBlueFork itself
// is pinned to 0.8.19, so the script deploys it via `vm.getCode` to stay Solc-agnostic.
pragma solidity 0.8.24;

import {Script, console2} from "forge-std/Script.sol";

import {MarketAccessRegistry} from "../src/controllers/MarketAccessRegistry.sol";
import {OssifiableProxy} from "../src/proxy/OssifiableProxy.sol";
import {IMorphoBase, MarketParams, Id} from "@morpho-blue/src/interfaces/IMorpho.sol";
import {MarketParamsLib} from "@morpho-blue/src/libraries/MarketParamsLib.sol";

interface IMorphoBlueForkExtras {
    function createMarket(MarketParams memory marketParams, address controller, bool deleverageEnabled) external;
}

/// @notice Sketch deploy script for a wstETH/WETH lending market on the lido-lending fork.
///         Bring up the core, the AccessRegistry, an upgradeable LidoMarketController behind
///         OssifiableProxy, then enable IRM/LLTV and create the market.
///
/// @dev See `script/DEPLOYMENT.md` for the matching runbook.
///
/// Usage (dry run against a fork):
///   forge script script/DeployFork.s.sol \
///     --fork-url "$MAINNET_RPC_URL" \
///     --sender "$DEPLOYER" -vvv
///
/// Usage (broadcast):
///   forge script script/DeployFork.s.sol \
///     --rpc-url "$RPC_URL" --broadcast --private-key "$PK" \
///     --verify --etherscan-api-key "$ETHERSCAN_API_KEY"
contract DeployFork is Script {
    using MarketParamsLib for MarketParams;

    // wstETH/WETH mainnet addresses. Override per chain when porting.
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;

    uint256 internal constant LLTV = 0.8e18;

    struct Deployment {
        address core;
        MarketAccessRegistry accessRegistry;
        address oracle;
        address irm;
        address controllerProxy;
        address controllerImpl;
        Id marketId;
    }

    function run() external returns (Deployment memory d) {
        address admin = msg.sender;

        vm.startBroadcast();

        d.core = _deployArtifact("MorphoBlueFork.sol:MorphoBlueFork", abi.encode(admin));
        d.accessRegistry = new MarketAccessRegistry(admin);
        d.oracle = _deployArtifact("WstEthRateOracle.sol:WstEthRateOracle", abi.encode(WSTETH));
        d.irm = _deployArtifact("AdaptiveCurveIrm.sol:AdaptiveCurveIrm", abi.encode(d.core));

        MarketParams memory params = MarketParams({
            loanToken: WETH,
            collateralToken: WSTETH,
            oracle: d.oracle,
            irm: d.irm,
            lltv: LLTV
        });
        d.marketId = params.id();

        // Controller behind an upgradeable proxy. Implementation deployed plain; proxy points at it.
        // The controller's `initialize` runs through the proxy with the controlled market id.
        d.controllerImpl = _deployArtifact("LidoMarketController.sol:LidoMarketController", "");
        bytes memory initData = abi.encodeWithSignature(
            "initialize(address,bytes32,address,address)",
            d.core,
            Id.unwrap(d.marketId),
            address(d.accessRegistry),
            admin
        );
        d.controllerProxy = address(new OssifiableProxy(d.controllerImpl, admin, initData));

        IMorphoBase(d.core).enableIrm(d.irm);
        IMorphoBase(d.core).enableLltv(LLTV);
        IMorphoBlueForkExtras(d.core).createMarket(params, d.controllerProxy, true);

        vm.stopBroadcast();

        _logDeployment(d);
    }

    /// @dev Deploys an artifact by name; lets the script stay Solc-agnostic for contracts that
    ///      pin a different pragma (the core is `0.8.19`, this script is `0.8.24`).
    function _deployArtifact(string memory artifact, bytes memory args) internal returns (address deployed) {
        bytes memory bytecode = vm.getCode(artifact);
        bytes memory creationCode = bytes.concat(bytecode, args);
        assembly ("memory-safe") {
            deployed := create(0, add(creationCode, 0x20), mload(creationCode))
        }
        require(deployed != address(0) && deployed.code.length != 0, "artifact deploy failed");
    }

    function _logDeployment(Deployment memory d) internal pure {
        console2.log("core               :", d.core);
        console2.log("accessRegistry     :", address(d.accessRegistry));
        console2.log("oracle             :", d.oracle);
        console2.log("irm                :", d.irm);
        console2.log("controller (proxy) :", d.controllerProxy);
        console2.log("controller (impl)  :", d.controllerImpl);
        console2.logBytes32(Id.unwrap(d.marketId));
    }
}
