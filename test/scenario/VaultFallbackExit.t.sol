// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";

import {ILidoLend} from "@lido-lend/src/interfaces/ILidoLend.sol";
import {Id, MarketParams} from "@lido-lend/src/interfaces/IMorpho.sol";
import {LidoLendDeployer} from "../../script/lib/LidoLendDeployer.sol";
import {LidoLendERC4626} from "../../src/LidoLendERC4626.sol";

interface IWETH {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function deposit() external payable;
}

interface IStETH {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function submit(address referral) external payable returns (uint256);
}

interface IWstETH {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function stEthPerToken() external view returns (uint256);
    function wrap(uint256 stETHAmount) external returns (uint256);
}

/// @notice Mainnet-fork scenarios for the vault's two settle-backed exits, `fallbackExit` and `settle`.
///         Each shows the redeem-first design: the exit first pays out whatever ordinary liquidity
///         (idle + Morpho-withdrawable) covers, then settles the remainder against an unhealthy-but-
///         solvent borrower for collateral. This also removes the front-run griefing vector — a
///         top-up of idle before the call just flows to the owner instead of reverting the settle.
contract VaultFallbackExitTest is Test, LidoLendDeployer {
    address internal constant WETH_ADDRESS = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant STETH_ADDRESS = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    address internal constant WSTETH_ADDRESS = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;

    IWETH internal constant WETH = IWETH(WETH_ADDRESS);
    IStETH internal constant STETH = IStETH(STETH_ADDRESS);
    IWstETH internal constant WSTETH = IWstETH(WSTETH_ADDRESS);

    address internal constant LENDER = address(0x1000);
    address internal constant BORROWER = address(0x2000);

    uint256 internal constant LLTV = 0.8e18;

    ILidoLend internal core;
    LidoLendERC4626 internal vault;
    MarketParams internal params;
    Id internal marketId;

    function _hasFork() internal view returns (bool) {
        return block.chainid == 1 && WSTETH_ADDRESS.code.length != 0;
    }

    function setUp() public {
        if (!_hasFork()) return;

        address[] memory guardians = new address[](1);
        guardians[0] = address(this);

        Deployed memory d = _deployForkStack(
            DeployConfig({
                admin: address(this),
                loanToken: WETH_ADDRESS,
                collateralToken: WSTETH_ADDRESS,
                oracleSource: WSTETH_ADDRESS,
                lltv: LLTV,
                enableSettlement: true,
                activation: CollateralActivationConfigParams({
                    minActivationDelay: 10 minutes,
                    maxActivationDelay: 2 hours,
                    activatingLockAmount: 0,
                    activatingLockDuration: 0,
                    maxDelayInflow: 10_000 ether,
                    minActivationAmount: 10 ether,
                    maxGuardiansQuorumDelay: 0,
                    delayPerStrike: 0,
                    delayPerSuspect: 0
                }),
                settlementConfig: SettlementConfigParams({
                    sliceFloorBps: 100, sliceFloorAssets: 0, fullCutBelowCollateral: 10 ether, ltvStepBps: 100
                }),
                guardians: guardians,
                quorum: 1,
                suspectWindow: 0,
                vaultName: "Lido wstETH/WETH Vault",
                vaultSymbol: "lidoWSTETH-WETH"
            })
        );

        core = ILidoLend(d.core);
        vault = LidoLendERC4626(d.vault);
        params = d.params;
        marketId = d.marketId;
    }

    /// @dev Lender funds the vault, a borrower draws most of it (leaving some idle), then a negative
    ///      rebase makes the borrower unhealthy but solvent — settle-eligible, no bad debt. Returns the
    ///      idle WETH left in the market (what the redeem leg can pay out).
    function _setupExitWithIdle() internal returns (uint256 idle) {
        _mintWETH(LENDER, 20 ether);
        vm.prank(LENDER);
        vault.deposit(20 ether, LENDER);

        uint256 collateral = _mintWstETH(BORROWER, 25 ether);
        vm.prank(BORROWER);
        core.supplyCollateral(params, collateral, BORROWER, "");

        vm.warp(block.timestamp + 2 hours + 1);
        vm.prank(BORROWER);
        core.borrow(params, 18 ether, 0, BORROWER, BORROWER); // healthy now; ~2 WETH stays idle

        // Negative rebase: LTV crosses above LLTV (unhealthy) but collateral still covers debt (solvent).
        vm.mockCall(
            WSTETH_ADDRESS, abi.encodeWithSelector(IWstETH.stEthPerToken.selector), abi.encode(uint256(0.95e18))
        );

        idle = 20 ether - 18 ether;
    }

    /// @dev Asserts a vault exit ran both phases: redeemed idle as loan assets AND settled collateral.
    function _assertBothPhases(uint256 idle, uint256 loanAssets, uint256 collateralSeized) internal {
        assertGt(loanAssets, 0, "redeem leg paid loan assets");
        assertApproxEqAbs(loanAssets, idle, 1e15, "redeem leg drained the available idle");
        assertGt(collateralSeized, 0, "settle leg seized collateral for the remainder");
        assertEq(WETH.balanceOf(LENDER), loanAssets, "receiver got the loan assets");
        assertEq(WSTETH.balanceOf(LENDER), collateralSeized, "receiver got the seized collateral");
    }

    /* fallbackExit: redeem available, then settle the remainder via the risk queue */

    function test_fallbackExit_redeemsAvailableThenSettles() public {
        vm.skip(!_hasFork(), "mainnet fork with Lido contracts required");

        uint256 idle = _setupExitWithIdle();

        // Request more than idle covers, so the redeem leg pays the idle and the settle leg covers the rest.
        uint256 shares = vault.balanceOf(LENDER) / 2;
        vm.prank(LENDER);
        (, uint256 loanAssets, uint256 collateralSeized,) = vault.fallbackExit(shares, LENDER, LENDER, 0);

        _assertBothPhases(idle, loanAssets, collateralSeized);
    }

    /* settle: liquidity-neutral targeted cut — seizes collateral, withdraws NO ordinary liquidity */

    function test_settle_seizesCollateralWithoutWithdrawingLiquidity() public {
        vm.skip(!_hasFork(), "mainnet fork with Lido contracts required");

        _setupExitWithIdle();

        address[] memory borrowers = new address[](1);
        borrowers[0] = BORROWER;

        uint256 wethBefore = WETH.balanceOf(LENDER); // lender holds no idle WETH (all deposited)

        uint256 shares = vault.balanceOf(LENDER) / 2;
        vm.prank(LENDER);
        (uint256 sharesBurned, uint256 loanAssets, uint256 collateralSeized,) =
            vault.settle(shares, borrowers, LENDER, LENDER);

        // Pure settle: the cut seizes collateral to the receiver and burns the matching shares, but the
        // ordinary liquidity is left untouched — no redeem leg, so no loan assets are paid out.
        assertGt(collateralSeized, 0, "settle seized collateral for the cut");
        assertGt(sharesBurned, 0, "shares burned for the settled slice");
        assertEq(loanAssets, 0, "settle withdrew no ordinary liquidity");
        assertEq(WETH.balanceOf(LENDER), wethBefore, "receiver got no loan assets");
        assertEq(WSTETH.balanceOf(LENDER), collateralSeized, "receiver got the seized collateral");
    }

    /* settle covers a cut below the market's ordinary liquidity. The new core gate allows settling up
       to onBehalf's supply minus free liquidity (here equal to the borrower's debt), so a sub-liquidity
       cut that the old `debtCanceled > availableLiquidity` gate rejected now goes through. */

    function test_settle_smallCutBelowLiquiditySucceeds() public {
        vm.skip(!_hasFork(), "mainnet fork with Lido contracts required");

        _setupExitWithIdle(); // ~2 WETH of ordinary liquidity sits in the market

        address[] memory borrowers = new address[](1);
        borrowers[0] = BORROWER;

        uint256 wethBefore = WETH.balanceOf(LENDER);
        uint256 shares = vault.balanceOf(LENDER) / 40; // ~0.5 WETH worth, well below the ~2 WETH liquidity
        vm.prank(LENDER);
        (uint256 sharesBurned, uint256 loanAssets, uint256 collateralSeized,) =
            vault.settle(shares, borrowers, LENDER, LENDER);

        assertGt(collateralSeized, 0, "sub-liquidity settle seized collateral under the new gate");
        assertGt(sharesBurned, 0, "shares burned for the slice");
        assertEq(loanAssets, 0, "settle withdrew no ordinary liquidity");
        assertEq(WETH.balanceOf(LENDER), wethBefore, "receiver got no loan assets");
        assertEq(WSTETH.balanceOf(LENDER), collateralSeized, "receiver got the seized collateral");
    }

    function _mintWETH(address user, uint256 amount) internal {
        vm.deal(user, amount);
        vm.startPrank(user);
        WETH.deposit{value: amount}();
        WETH.approve(address(vault), type(uint256).max);
        vm.stopPrank();
    }

    function _mintWstETH(address user, uint256 ethAmount) internal returns (uint256 wstETHAmount) {
        vm.deal(user, ethAmount);
        vm.startPrank(user);
        STETH.submit{value: ethAmount}(address(0));
        STETH.approve(WSTETH_ADDRESS, STETH.balanceOf(user));
        wstETHAmount = WSTETH.wrap(STETH.balanceOf(user));
        WSTETH.approve(address(core), type(uint256).max);
        vm.stopPrank();
    }
}
