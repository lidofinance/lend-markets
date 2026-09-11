// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {Position} from "@lido-lend/src/interfaces/IMorpho.sol";

import {ILidoLendERC4626} from "../../src/interfaces/ILidoLendERC4626.sol";
import {Erc4626Math} from "../setup/Erc4626Math.sol";
import {Market} from "../setup/Types.sol";
import {MarketActions} from "../setup/MarketActions.sol";
import {ForkMarketStack} from "./helpers/ForkMarketStack.sol";

/// @notice The lender exits the deployed market offers, each held to an independent recompute: the ERC-4626 entry
///         points and the direct core position against the share maths, a targeted settle through the borrower's
///         personal settlement LTV, and `fallbackExit` inside free liquidity, which must never read the oracle.
abstract contract LenderExitsForkBase is ForkMarketStack {
    using MarketActions for Market;

    address internal DIRECT_LENDER;
    address internal RECEIVER;

    constructor(string memory role) ForkMarketStack(role) {}

    function setUp() public {
        _fork();
        _bindRole();
        _seedLenderAndBorrower();
        DIRECT_LENDER = _freshActor(deployed, "lenderExits.directLender");
        RECEIVER = _freshActor(deployed, "lenderExits.receiver");
    }

    // ---
    // ERC-4626 ENTRY POINTS (each helper holds the call to the recomputed conversion)
    // ---

    function test_vaultMint_pullsAssetsByErc4626Formula() public {
        uint256 shares = lenderShares / 7 + 1;
        deal(address(deployed.loanToken), LENDER, Erc4626Math.toAssets(deployed.vault, shares, Math.Rounding.Ceil));
        market.vaultMint(LENDER, shares);
    }

    function test_vaultWithdraw_burnsSharesByErc4626Formula() public {
        uint256 assets = Erc4626Math.toAssets(deployed.vault, lenderShares / 3, Math.Rounding.Floor);
        assertLe(assets, deployed.vault.maxWithdraw(LENDER), "setup: the withdrawal must fit free liquidity");
        market.vaultWithdraw(LENDER, assets);
    }

    function test_vaultRedeem_paysAssetsByErc4626Formula() public {
        uint256 shares = lenderShares / 5;
        assertLe(shares, deployed.vault.maxRedeem(LENDER), "setup: the redemption must fit free liquidity");
        market.vaultRedeem(LENDER, shares);
    }

    function test_coreSupplyThenWithdraw_bySharesMath() public {
        uint256 assets = 2 * _loanUnit(deployed) + 321;
        _requireSupplyHeadroom(deployed, assets);
        deal(address(deployed.loanToken), DIRECT_LENDER, assets);
        market.coreSupply(DIRECT_LENDER, assets);
        market.coreWithdraw(DIRECT_LENDER, assets);
        assertEq(deployed.core.position(deployed.id, DIRECT_LENDER).supplyShares, 0, "round trip leaves no position");
    }

    // ---
    // SETTLEMENT THROUGH THE PERSONAL LTV
    // ---

    /// @dev The borrower opts in; the lender's cut is exactly the slice that lands the borrower on its target,
    ///      the burn is what the core derives for it, and the seized collateral goes to the receiver.
    function test_settle_personalLtv_cutsExactlyTheRecomputedSlice() public {
        market.setSettlementLtv(BORROWER, 0.05e18);
        uint256 shares = lenderShares / 2;
        MarketActions.SettlementExpectation memory expected = market.expectedPersonalSettlement(shares, BORROWER);
        Position memory before = deployed.core.position(deployed.id, BORROWER);

        address[] memory borrowers = new address[](1);
        borrowers[0] = BORROWER;
        (uint256 sharesBurned, uint256 collateralSeized, uint256 debtCanceled) =
            market.settle(LENDER, shares, borrowers, RECEIVER);

        Position memory after_ = deployed.core.position(deployed.id, BORROWER);
        assertEq(before.borrowShares - after_.borrowShares, expected.cutBorrowShares, "borrower debt shares cut");
        assertEq(before.collateral - after_.collateral, collateralSeized, "borrower collateral debited");
        assertEq(deployed.collateralToken.balanceOf(RECEIVER), collateralSeized, "receiver holds the seized collateral");
        assertEq(deployed.vault.balanceOf(LENDER), lenderShares - sharesBurned, "lender shares burned");
        assertGt(debtCanceled, 0, "a real cut");
    }

    function testRevert_vaultSettle_noPersonalLtv_NothingSettled() public {
        address[] memory borrowers = new address[](1);
        borrowers[0] = BORROWER;
        uint256 shares = lenderShares / 2;
        vm.prank(LENDER);
        vm.expectRevert(ILidoLendERC4626.NothingSettled.selector);
        deployed.vault.settle(shares, borrowers, LENDER, LENDER);
    }

    // ---
    // FALLBACK EXIT INSIDE LIQUIDITY
    // ---

    /// @dev With the oracle down the settle leg cannot even be quoted, so a request that free liquidity covers
    ///      succeeding proves only the redeem leg ran.
    function test_fallbackExit_withinLiquidity_liquidLegOnly_oracleNotRead() public {
        _mockOracleRevert(deployed);
        market.fallbackExitLiquid(LENDER, lenderShares / 4, RECEIVER);
    }
}

contract LenderExitsWethWstethForkTest is LenderExitsForkBase("weth-wsteth") {}

contract LenderExitsUsdyUsdtForkTest is LenderExitsForkBase("usdy-usdt") {}
