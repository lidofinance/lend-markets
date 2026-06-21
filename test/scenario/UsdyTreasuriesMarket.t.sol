// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";

import {Id, MarketParams} from "@lido-lend/src/interfaces/IMorpho.sol";
import {LidoLendDeployer} from "../../script/lib/LidoLendDeployer.sol";
import {UsdyStableOracle} from "../../src/oracle/UsdyStableOracle.sol";
import {LidoLendERC4626} from "../../src/LidoLendERC4626.sol";

interface IERC20Like {
    // No `returns (bool)`: USDT's approve/transfer return no data, so declaring a bool return would
    // make Solidity revert decoding the missing return value.
    function approve(address spender, uint256 amount) external;
    function balanceOf(address account) external view returns (uint256);
}

interface ICoreLike {
    function supply(MarketParams memory p, uint256 assets, uint256 shares, address onBehalf, bytes memory data)
        external
        returns (uint256, uint256);
    function supplyCollateral(MarketParams memory p, uint256 assets, address onBehalf, bytes memory data) external;
    function borrow(MarketParams memory p, uint256 assets, uint256 shares, address onBehalf, address receiver)
        external
        returns (uint256, uint256);
    function liquidate(
        MarketParams memory p,
        address borrower,
        uint256 seizedAssets,
        uint256 repaidShares,
        bytes memory data
    ) external returns (uint256, uint256);
    function accrueInterest(MarketParams memory p) external;
    function position(Id id, address user)
        external
        view
        returns (uint256 supplyShares, uint128 borrowShares, uint128 collateral);
}

interface IUsdyBlocklist {
    function owner() external view returns (address);
    function addToBlocklist(address[] calldata accounts) external;
    function isBlocked(address account) external view returns (bool);
}

/// @notice Mainnet-fork scenario for the USD/Treasuries market on REAL contracts: USDY collateral,
///         USDT loan, priced by `UsdyStableOracle` over Ondo's real NAV oracle + the real Chainlink
///         USDT/USD feed. Verifies ADR-022's core constraint: USDY's transfer restriction means a
///         blocklisted address cannot receive seized collateral — so it can neither liquidate nor be
///         the fallback-exit receiver — while an eligible (non-blocklisted) address can.
contract UsdyTreasuriesMarketTest is Test, LidoLendDeployer {
    // Real mainnet addresses.
    address internal constant USDY = 0x96F6eF951840721AdBF46Ac996b59E0235CB985C; // 18 dec, transfer-gated
    address internal constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7; // 6 dec
    address internal constant ONDO_ORACLE = 0xA0219AA5B31e65Bc920B5b6DFb8EdF0988121De0; // getPrice() 1e18
    address internal constant USDT_USD_FEED = 0x3E7d1eAB13ad0104d2750B8863b489D65364e32D; // Chainlink, 8 dec
    address internal constant USDY_BLOCKLIST = 0xd8c8174691d936E2C80114EC449037b13421B0a8; // Ownable

    address internal constant LENDER = address(0x1000);
    address internal constant BORROWER = address(0x2000);
    address internal constant KEEPER_GOOD = address(0x6000); // eligible (not blocklisted)
    address internal constant KEEPER_BAD = address(0x7000); // will be blocklisted

    uint256 internal constant LLTV = 0.86e18;

    ICoreLike internal core;
    LidoLendERC4626 internal vault;
    MarketParams internal params;
    Id internal marketId;

    function _hasFork() internal view returns (bool) {
        return block.chainid == 1 && USDY.code.length != 0 && USDT.code.length != 0;
    }

    /// @dev Real oracle: USDY NAV (Ondo) quoted in USDT via the real Chainlink USDT/USD feed, behind an
    ///      `OssifiableProxy` (feed config set in proxy storage via `initialize`).
    function _deployOracle(address, address admin) internal override returns (address) {
        address impl = address(new UsdyStableOracle(ONDO_ORACLE, USDT_USD_FEED));
        return _behindProxy(impl, admin, abi.encodeWithSignature("initialize()"));
    }

    function setUp() public {
        if (!_hasFork()) return;

        address[] memory guardians = new address[](1);
        guardians[0] = address(this);

        Deployed memory d = _deployForkStack(
            DeployConfig({
                admin: address(this),
                loanToken: USDT,
                collateralToken: USDY,
                oracleSource: USDY, // ignored — _deployOracle overridden
                lltv: LLTV,
                enableSettlement: true,
                activation: ActivationConfig({
                    minActivationDelay: 10 minutes,
                    maxActivationDelay: 2 hours,
                    maxDelayInflow: 10_000 ether,
                    delayPerStrike: 2 hours,
                    activatingHold: 0,
                    minActivationAmount: 10 ether,
                    maxGuardiansQuorumDelay: 0
                }),
                settlementConfig: SettlementConfigParams({
                    sliceFloorBps: 100, sliceFloorAssets: 0, fullCutBelowCollateral: 10 ether, ltvStepBps: 100
                }),
                guardians: guardians,
                quorum: 1,
                vaultName: "Lido USDY/USDT Vault",
                vaultSymbol: "lidoUSDY-USDT"
            })
        );

        core = ICoreLike(d.core);
        vault = LidoLendERC4626(d.vault);
        params = d.params;
        marketId = d.marketId;
    }

    /// @dev Drop USDY NAV so the borrower becomes unhealthy (repo-standard mockCall on the price source,
    ///      mirroring how existing fork tests mock `wstETH.getStETHByWstETH`).
    function _crashUsdyPrice(uint256 newGetPrice) internal {
        vm.mockCall(ONDO_ORACLE, abi.encodeWithSignature("getPrice()"), abi.encode(newGetPrice));
    }

    function _blocklist(address account) internal {
        IUsdyBlocklist bl = IUsdyBlocklist(USDY_BLOCKLIST);
        vm.prank(bl.owner());
        address[] memory accounts = new address[](1);
        accounts[0] = account;
        bl.addToBlocklist(accounts);
        assertTrue(bl.isBlocked(account), "blocklisted");
    }

    /// @dev Borrower posts USDY collateral, waits out activation, and borrows USDT.
    function _openBorrow(uint256 collateralUsdy, uint256 borrowUsdt) internal {
        deal(USDY, BORROWER, collateralUsdy);
        vm.startPrank(BORROWER);
        IERC20Like(USDY).approve(address(core), type(uint256).max);
        core.supplyCollateral(params, collateralUsdy, BORROWER, "");
        vm.stopPrank();

        vm.warp(block.timestamp + 2 hours + 1);
        vm.prank(BORROWER);
        core.borrow(params, borrowUsdt, 0, BORROWER, BORROWER);
    }

    /* T1 — liquidation respects USDY's blocklist */

    function test_liquidate_blocklistedCannot_allowlistedCan() public {
        vm.skip(!_hasFork(), "mainnet fork required");

        // Lender funds the market with USDT liquidity.
        deal(USDT, LENDER, 2_000e6);
        vm.startPrank(LENDER);
        IERC20Like(USDT).approve(address(core), type(uint256).max);
        core.supply(params, 2_000e6, 0, LENDER, "");
        vm.stopPrank();

        _openBorrow(1_000e18, 500e6); // 1000 USDY collateral, borrow 500 USDT
        _crashUsdyPrice(0.3e18); // collateral ~$300 << $500 debt → clearly unhealthy (bad debt ok for liquidate)
        core.accrueInterest(params);

        // Both keepers hold USDT to repay; KEEPER_BAD is blocklisted on USDY.
        deal(USDT, KEEPER_GOOD, 1_000e6);
        deal(USDT, KEEPER_BAD, 1_000e6);
        vm.prank(KEEPER_GOOD);
        IERC20Like(USDT).approve(address(core), type(uint256).max);
        vm.prank(KEEPER_BAD);
        IERC20Like(USDT).approve(address(core), type(uint256).max);
        _blocklist(KEEPER_BAD);

        uint256 seize = 100e18; // seize 100 USDY

        // Blocklisted keeper: the collateral safeTransfer to it reverts → liquidate reverts.
        vm.prank(KEEPER_BAD);
        // USDY's blocklist revert ("USDY: 'to' address blocked") is wrapped by Morpho's SafeTransferLib.
        vm.expectRevert("transfer reverted");
        core.liquidate(params, BORROWER, seize, 0, "");

        // Eligible keeper: liquidation succeeds and it receives the seized USDY.
        uint256 balBefore = IERC20Like(USDY).balanceOf(KEEPER_GOOD);
        vm.prank(KEEPER_GOOD);
        (uint256 seized,) = core.liquidate(params, BORROWER, seize, 0, "");
        assertEq(seized, seize, "seized requested amount");
        assertEq(IERC20Like(USDY).balanceOf(KEEPER_GOOD) - balBefore, seize, "eligible keeper received USDY");
    }

    /* T2 — vault fallback exit respects USDY's blocklist on the receiver */

    function test_fallbackExit_blocklistedReceiverCannot_allowlistedCan() public {
        vm.skip(!_hasFork(), "mainnet fork required");

        // Lender deposits USDT into the vault (vault supplies to the market).
        deal(USDT, LENDER, 600e6);
        vm.startPrank(LENDER);
        IERC20Like(USDT).approve(address(vault), type(uint256).max);
        vault.deposit(600e6, LENDER);
        vm.stopPrank();

        // Borrower draws down most of the liquidity so ordinary (idle) withdrawal can't satisfy the
        // exit — forcing the fallback (settle) path.
        _openBorrow(1_000e18, 550e6);
        _crashUsdyPrice(0.6e18); // collateral ~$600: unhealthy (>LLTV) but solvent (>debt) → settle, not bad debt
        core.accrueInterest(params);

        _blocklist(KEEPER_BAD);

        uint256 shares = vault.balanceOf(LENDER) / 2;

        // Blocklisted receiver: settle's collateral transfer to it reverts → fallbackExit reverts.
        vm.prank(LENDER);
        // USDY's blocklist revert ("USDY: 'to' address blocked") is wrapped by Morpho's SafeTransferLib.
        vm.expectRevert("transfer reverted");
        vault.fallbackExit(shares, KEEPER_BAD, LENDER, 0);

        // Eligible receiver: succeeds and receives seized USDY collateral.
        uint256 balBefore = IERC20Like(USDY).balanceOf(KEEPER_GOOD);
        vm.prank(LENDER);
        (,, uint256 collateralSeized,) = vault.fallbackExit(shares, KEEPER_GOOD, LENDER, 0);
        assertGt(collateralSeized, 0, "collateral seized via settle");
        assertEq(IERC20Like(USDY).balanceOf(KEEPER_GOOD) - balBefore, collateralSeized, "eligible receiver got USDY");
    }
}
