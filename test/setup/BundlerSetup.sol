// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Authorization, Signature} from "@lido-lend/src/interfaces/IMorpho.sol";
import {AUTHORIZATION_TYPEHASH} from "@lido-lend/src/libraries/ConstantsLib.sol";

import {Call, IBundler3} from "@bundler3/src/interfaces/IBundler3.sol";

import {LidoLendVaultAdapter} from "../../src/adapters/LidoLendVaultAdapter.sol";

import {IGeneralAdapter1} from "./IGeneralAdapter1.sol";
import {LidoLendSetup} from "./LidoLendSetup.sol";
import {MockStETH, MockWETH, MockWstETH} from "./Mocks.sol";
import {Market} from "./Types.sol";

/// @notice Base for bundle tests: a WETH/wstETH market from `LidoLendSetup` plus a freshly deployed
///         bundler stack — the stock Bundler3 and the vendored general adapter (artifact-deployed;
///         they pin solc 0.8.28) and the Lido vault adapter — with call builders and the residue
///         invariant every bundle must satisfy. Execute bundles through `_exec` so the invariant is
///         asserted uniformly.
abstract contract BundlerSetup is LidoLendSetup {
    /// @dev Loose share-price rail for legs whose price is not under test (actual prices are ~1e21 ray).
    uint256 internal constant MAX_SHARE_PRICE_E27 = 1e30;

    IBundler3 internal bundler3;
    IGeneralAdapter1 internal adapter;
    LidoLendVaultAdapter internal vaultAdapter;

    MockWETH internal weth;
    MockStETH internal steth;
    MockWstETH internal wsteth;

    /// @dev Deploys the WETH/wstETH market and the bundler stack against it.
    function _deployBundledMarket() internal returns (Market storage m) {
        weth = new MockWETH();
        steth = new MockStETH();
        wsteth = new MockWstETH(steth);
        // ETH backing for unwraps of WETH minted via `deal` (which bypasses `deposit`).
        vm.deal(address(weth), 1e30);

        m = _deployProtocol(_defaultConfig(address(weth), address(wsteth), address(0)));

        bundler3 = IBundler3(_deployOut("Bundler3.sol", "Bundler3", ""));
        adapter = IGeneralAdapter1(
            _deployOut(
                "EthereumGeneralAdapter1.sol",
                "EthereumGeneralAdapter1",
                abi.encode(address(bundler3), address(protocol.core), address(weth), address(wsteth))
            )
        );
        vaultAdapter = new LidoLendVaultAdapter(address(bundler3));
    }

    /// @dev Deploys a contract from its compiled artifact. The vendored bundler contracts use solc
    ///      0.8.28, so reading their bytecode directly avoids Foundry's same-version artifact lookup.
    function _deployOut(string memory file, string memory name, bytes memory args) private returns (address deployed) {
        string memory json = vm.readFile(string.concat("out/", file, "/", name, ".json"));
        bytes memory code = bytes.concat(vm.parseJsonBytes(json, ".bytecode.object"), args);
        assembly ("memory-safe") {
            deployed := create(0, add(code, 0x20), mload(code))
        }
        require(deployed != address(0) && deployed.code.length != 0, "BundlerSetup: deploy failed");
    }

    // ---
    // CALL BUILDERS
    // ---

    /// @dev A plain call (no value, no callback).
    function _call(address to, bytes memory data) internal pure returns (Call memory) {
        return Call({to: to, data: data, value: 0, skipRevert: false, callbackHash: bytes32(0)});
    }

    /// @dev A value-bearing call. Empty `data` hits the target's receive function.
    function _callValue(address to, bytes memory data, uint256 value) internal pure returns (Call memory) {
        return Call({to: to, data: data, value: value, skipRevert: false, callbackHash: bytes32(0)});
    }

    /// @dev A call committing to a reenter with exactly `callbackData` (an abi-encoded Call[]).
    function _callWithCallback(address to, bytes memory data, bytes memory callbackData)
        internal
        pure
        returns (Call memory)
    {
        return Call({to: to, data: data, value: 0, skipRevert: false, callbackHash: keccak256(callbackData)});
    }

    /// @dev A plain call to the general adapter.
    function _adapterCall(bytes memory data) internal view returns (Call memory) {
        return _call(address(adapter), data);
    }

    // ---
    // EXECUTION
    // ---

    /// @dev Runs `bundle` as `user` with `value` attached, then asserts the residue invariant: no asset
    ///      of the market may remain on the dispatcher or either adapter after a bundle.
    function _exec(address user, uint256 value, Call[] memory bundle) internal {
        vm.prank(user);
        bundler3.multicall{value: value}(bundle);
        _assertNoResidue();
    }

    /// @dev The dispatcher and adapters are stateless conduits: anything left on them after a
    ///      transaction is permissionlessly sweepable, so a leak here is a bundle-encoding bug.
    ///      Checks native, stETH, and every deployed market's loan token, collateral token, and
    ///      vault shares, so the invariant scales if a suite adds markets.
    function _assertNoResidue() internal view {
        address[3] memory holders = [address(bundler3), address(adapter), address(vaultAdapter)];
        for (uint256 i; i < holders.length; ++i) {
            vm.assertEq(holders[i].balance, 0, "residue: native");
            vm.assertEq(steth.balanceOf(holders[i]), 0, "residue: stETH");
            for (uint256 j; j < protocol.markets.length; ++j) {
                Market storage m = protocol.markets[j];
                vm.assertEq(m.loanToken.balanceOf(holders[i]), 0, "residue: loan token");
                vm.assertEq(m.collateralToken.balanceOf(holders[i]), 0, "residue: collateral token");
                vm.assertEq(m.vault.balanceOf(holders[i]), 0, "residue: vault shares");
            }
        }
    }

    // ---
    // AUTHORIZATION
    // ---

    /// @dev EIP-712 authorization of `authorized` by the holder of `key`, for use as a direct bundle
    ///      Call to the core (nonce read from the core, domain bound to the proxy address).
    function _signCoreAuthorization(uint256 key, address authorized)
        internal
        view
        returns (Authorization memory auth, Signature memory sig)
    {
        address authorizer = vm.addr(key);
        auth = Authorization({
            authorizer: authorizer,
            authorized: authorized,
            isAuthorized: true,
            nonce: protocol.core.nonce(authorizer),
            deadline: block.timestamp + 1 hours
        });
        bytes32 digest = keccak256(
            bytes.concat(
                "\x19\x01", protocol.core.DOMAIN_SEPARATOR(), keccak256(abi.encode(AUTHORIZATION_TYPEHASH, auth))
            )
        );
        (sig.v, sig.r, sig.s) = vm.sign(key, digest);
    }

    /// @dev The authorization leg as a ready-made direct core Call.
    function _authorizationCall(uint256 key, address authorized) internal view returns (Call memory) {
        (Authorization memory auth, Signature memory sig) = _signCoreAuthorization(key, authorized);
        return _call(address(protocol.core), abi.encodeCall(protocol.core.setAuthorizationWithSig, (auth, sig)));
    }
}
