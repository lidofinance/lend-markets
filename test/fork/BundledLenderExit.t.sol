// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {Call, IBundler3} from "@bundler3/src/interfaces/IBundler3.sol";

import {LidoLendVaultAdapter} from "../../src/adapters/LidoLendVaultAdapter.sol";
import {Erc4626Math} from "../setup/Erc4626Math.sol";
import {Market} from "../setup/Types.sol";
import {MarketActions} from "../setup/MarketActions.sol";
import {ForkMarketStack} from "./helpers/ForkMarketStack.sol";

/// @notice A lender exits the deployed vault through the deployed Bundler3 vault adapter: the payout lands on the
///         lender at the ERC-4626 conversion and nothing is left on the dispatcher or the adapters. Skips when the
///         run records no bundler artifact.
abstract contract BundledLenderExitForkBase is ForkMarketStack {
    using MarketActions for Market;

    IBundler3 internal bundler3;
    address internal generalAdapter;
    address internal vaultAdapter;

    constructor(string memory role) ForkMarketStack(role) {}

    function setUp() public {
        _fork();
        _bindRole();
        _skipUnlessArtifact("bundler.toml");
        bundler3 = IBundler3(_artifactAddr("bundler.toml", "bundler.bundler3"));
        generalAdapter = _artifactAddr("bundler.toml", "bundler.general_adapter");
        vaultAdapter = _artifactAddr("bundler.toml", "bundler.vault_adapter");

        LENDER = _freshActor(deployed, "bundled.lender");
        uint256 deposit = 3 * _loanUnit(deployed) + 4_321;
        _requireSupplyHeadroom(deployed, deposit);
        deal(address(deployed.loanToken), LENDER, deposit);
        lenderShares = market.vaultDeposit(LENDER, deposit);
    }

    /// @dev Inside free liquidity only the redeem leg runs: the initiator gets the ERC-4626 value of its shares in
    ///      loan tokens, with the adapter's floors set to exactly that, and the bundle leaves no residue behind.
    function test_bundledFallbackExit_liquidOnly_paysInitiator() public {
        uint256 shares = lenderShares / 2;
        uint256 expectedAssets = Erc4626Math.toAssets(deployed.vault, shares, Math.Rounding.Floor);
        assertLe(expectedAssets, _freeLiquidity(deployed), "setup: the exit fits free liquidity");

        Call[] memory bundle = new Call[](1);
        bundle[0] = Call({
            to: vaultAdapter,
            data: abi.encodeCall(
                LidoLendVaultAdapter.fallbackExit, (address(deployed.vault), shares, 0, LENDER, expectedAssets, shares)
            ),
            value: 0,
            skipRevert: false,
            callbackHash: bytes32(0)
        });
        vm.prank(LENDER);
        deployed.vault.approve(vaultAdapter, shares);
        vm.prank(LENDER);
        bundler3.multicall(bundle);

        assertEq(deployed.loanToken.balanceOf(LENDER), expectedAssets, "initiator paid the ERC-4626 value");
        assertEq(deployed.vault.balanceOf(LENDER), lenderShares - shares, "exactly the requested shares burned");
        _assertNoResidue(address(bundler3));
        _assertNoResidue(generalAdapter);
        _assertNoResidue(vaultAdapter);
    }

    /// @dev The dispatcher and adapters are stateless conduits: anything left on them is a bundle-encoding bug.
    function _assertNoResidue(address holder) internal view {
        assertEq(deployed.loanToken.balanceOf(holder), 0, "residue: loan token");
        assertEq(deployed.collateralToken.balanceOf(holder), 0, "residue: collateral token");
        assertEq(deployed.vault.balanceOf(holder), 0, "residue: vault shares");
    }
}

contract BundledLenderExitWethWstethForkTest is BundledLenderExitForkBase("weth-wsteth") {}

contract BundledLenderExitUsdyUsdtForkTest is BundledLenderExitForkBase("usdy-usdt") {}
