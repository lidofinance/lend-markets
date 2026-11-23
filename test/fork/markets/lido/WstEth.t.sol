// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Call, IBundler3} from "@bundler3/src/interfaces/IBundler3.sol";
import {Id, MarketParams, IMorphoStaticTyping} from "@lido-lend/src/interfaces/IMorpho.sol";
import {IOracle} from "@lido-lend/src/interfaces/IOracle.sol";
import {MarketParamsLib} from "@lido-lend/src/libraries/MarketParamsLib.sol";
import {MathLib} from "@lido-lend/src/libraries/MathLib.sol";
import {ORACLE_PRICE_SCALE} from "@lido-lend/src/libraries/ConstantsLib.sol";

import {ILidoLendMarketController} from "../../../../src/interfaces/ILidoLendMarketController.sol";
import {WAD, BPS} from "../../../../src/libs/Constants.sol";
import {BundlerParameters} from "../../../../script/deployment/DeployBundlerBase.s.sol";
import {IGeneralAdapter1} from "../../../setup/IGeneralAdapter1.sol";
import {Market} from "../../../setup/Types.sol";
import {MarketActions} from "../../../setup/MarketActions.sol";
import {ForkStack} from "../../helpers/ForkStack.sol";

/// @dev Lido stETH: `submit` stakes ETH.
interface IStETH {
    function submit(address referral) external payable returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/// @dev Lido wstETH: `wrap` turns stETH into wstETH.
interface IWstETH {
    function stETH() external view returns (address);
    function wrap(uint256 stETHAmount) external returns (uint256);
    function getWstETHByStETH(uint256 stETHAmount) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/// @dev WETH: `deposit` wraps ETH and `withdraw` unwraps it.
interface IWETH {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/// @notice A market whose collateral is Lido's wstETH, whatever its oracle, against the real stETH and wstETH: ETH
///         staked for stETH and wrapped backs a borrow and comes back in full. On every market whose collateral
///         wraps stETH.
contract WstEthForkTest is ForkStack {
    using MarketActions for Market;

    IWstETH internal wstEth;

    function setUp() public {
        _setUpTarget();
        (bool ok, bytes memory returned) = address(market.collateralToken).staticcall(abi.encodeCall(IWstETH.stETH, ()));
        if (!ok || returned.length != 32) vm.skip(true, "WstEth: the collateral does not wrap stETH");
        wstEth = IWstETH(address(market.collateralToken));
    }

    /// @dev Collateral staked through the real Lido contracts: ETH is submitted for stETH and wrapped into wstETH,
    ///      which backs a borrow and comes back in full after the repayment.
    function test_stakedCollateral_borrowsAndComesBack() public {
        address borrower = _freshActor(market, "wsteth.staker");
        IStETH stEth = IStETH(wstEth.stETH());
        vm.deal(borrower, 3 * uint256(_activationConfig(market).minActivationAmount));
        vm.startPrank(borrower);
        stEth.submit{value: borrower.balance}(address(0));
        uint256 staked = stEth.balanceOf(borrower);
        stEth.approve(address(wstEth), staked);
        uint256 collateral = wstEth.wrap(staked);
        vm.stopPrank();
        assertGt(collateral, _activationConfig(market).minActivationAmount, "the wrap clears the dust threshold");

        uint256 borrowAssets = _maxBorrow(market, collateral, market.oracle.price()) / 4;
        address lender = _freshActor(market, "wsteth.lender");
        _requireSupplyHeadroom(market, 2 * borrowAssets);
        deal(address(market.loanToken), lender, 2 * borrowAssets);
        market.vaultDeposit(lender, 2 * borrowAssets);

        market.supplyCollateral(borrower, collateral);
        market.activateCollateral();
        uint256 shares = market.borrow(borrower, borrowAssets);
        deal(address(market.loanToken), borrower, market.repayAssets(shares));
        market.repay(borrower, shares);
        market.withdrawCollateral(borrower, collateral, borrower);
        assertEq(wstEth.balanceOf(borrower), collateral, "the staked collateral comes back in full");
    }
}

/// @notice Leverage router fixture for a WETH/wstETH market: `(borrow -> stake -> supplyCollateral)` cycles on the
///         caller's position in one transaction.
/// @dev The loop sizes each borrow from the position's raw collateral, while the core lets it borrow only against
///      active collateral. So it compounds only when the router is an instant-activation caller, whose supplies skip
///      the activation timer; without the grant the second borrow meets the activating supply and reverts.
contract WstEthWethLeverageRouter {
    using MarketParamsLib for MarketParams;
    using MathLib for uint256;

    address public immutable MORPHO;
    address public immutable WETH;
    address public immutable STETH;
    address public immutable WSTETH;

    /// @dev Below this borrow (0.001 ETH) the swap leg's rounding fails the slippage check.
    uint256 internal constant MIN_BORROW_PER_ITER = 1e15;

    error NotAuthorized();
    error UnsupportedMarket();
    error MaxIterationsZero();
    error InsufficientCollateralOut();
    error EthSenderNotWeth();

    constructor(address morpho, address weth, address steth, address wsteth) {
        MORPHO = morpho;
        WETH = weth;
        STETH = steth;
        WSTETH = wsteth;
        IWstETH(wsteth).approve(morpho, type(uint256).max);
        IStETH(steth).approve(wsteth, type(uint256).max);
    }

    /// @notice Levers the caller's position up to `targetCollateral`; the caller has supplied collateral and
    ///         authorized this router on the core.
    function openLeveragedPosition(
        MarketParams calldata marketParams,
        uint256 targetCollateral,
        uint256 minSwapOutBps,
        uint256 maxIterations
    ) external {
        if (!IMorphoStaticTyping(MORPHO).isAuthorized(msg.sender, address(this))) {
            revert NotAuthorized();
        }
        if (marketParams.loanToken != WETH || marketParams.collateralToken != WSTETH) revert UnsupportedMarket();
        if (maxIterations == 0) revert MaxIterationsZero();
        Id id = marketParams.id();
        uint256 price = IOracle(marketParams.oracle).price();
        for (uint256 i; i < maxIterations; ++i) {
            (uint256 collateral, uint256 debt) = _position(id, msg.sender);
            if (collateral >= targetCollateral) break;
            uint256 borrowAssets = _nextBorrow(marketParams.lltv, collateral, price, debt, targetCollateral);
            if (borrowAssets < MIN_BORROW_PER_ITER) break;
            IMorphoStaticTyping(MORPHO).borrow(marketParams, borrowAssets, 0, msg.sender, address(this));
            uint256 wstEthOut = _stake(borrowAssets);
            if (wstEthOut * price * BPS < borrowAssets * ORACLE_PRICE_SCALE * minSwapOutBps) {
                revert InsufficientCollateralOut();
            }
            IMorphoStaticTyping(MORPHO).supplyCollateral(marketParams, wstEthOut, msg.sender, "");
        }
    }

    /// @dev The raw collateral and the debt rounded up, against the borrower.
    function _position(Id id, address user) internal view returns (uint256 collateral, uint256 debt) {
        (, uint128 borrowShares, uint128 rawCollateral) = IMorphoStaticTyping(MORPHO).position(id, user);
        collateral = rawCollateral;
        if (borrowShares == 0) return (collateral, 0);
        (,, uint128 totalBorrowAssets, uint128 totalBorrowShares,,) = IMorphoStaticTyping(MORPHO).market(id);
        debt = (uint256(borrowShares) * totalBorrowAssets + totalBorrowShares - 1) / totalBorrowShares;
    }

    /// @dev The raw-LTV headroom less one wei, as the borrow's shares round up and back to one wei more, capped by
    ///      what reaches the target.
    function _nextBorrow(uint256 lltv, uint256 collateral, uint256 price, uint256 debt, uint256 targetCollateral)
        internal
        pure
        returns (uint256)
    {
        uint256 maxDebt = collateral.mulDivDown(price, ORACLE_PRICE_SCALE).mulDivDown(lltv, WAD);
        if (maxDebt <= debt + 1) return 0;
        uint256 headroom = maxDebt - debt - 1;
        uint256 toTarget = (targetCollateral - collateral) * price / ORACLE_PRICE_SCALE;
        return toTarget < headroom ? toTarget : headroom;
    }

    /// @dev WETH -> ETH -> stETH (Lido `submit`) -> wstETH (`wrap`).
    function _stake(uint256 wethAmount) internal returns (uint256) {
        IWETH(WETH).withdraw(wethAmount);
        uint256 stEthBefore = IStETH(STETH).balanceOf(address(this));
        IStETH(STETH).submit{value: wethAmount}(address(0));
        return IWstETH(WSTETH).wrap(IStETH(STETH).balanceOf(address(this)) - stEthBefore);
    }

    receive() external payable {
        if (msg.sender != WETH) revert EthSenderNotWeth();
    }
}

/// @notice A leverage router compounds on a market that lends the network's WETH against its wstETH only with instant
///         activation: granted, every supply is active at once and the loop reaches its target; without it the
///         first supply waits in the activation timer and the next borrow reverts. Other markets skip.
contract WstEthLeverageForkTest is ForkStack {
    uint256 internal constant MIN_SWAP_OUT_BPS = 9900;
    uint256 internal constant MAX_ITERATIONS = 10;

    IWETH internal weth;
    IWstETH internal wstEth;
    address internal lender;
    address internal user;

    function setUp() public {
        _setUpTarget();
        BundlerParameters memory tokens = network.bundler.getConfig();
        if (address(market.loanToken) != tokens.weth || address(market.collateralToken) != tokens.wstEth) {
            vm.skip(true, "WstEthLeverage: the market does not lend WETH against wstETH");
        }
        weth = IWETH(tokens.weth);
        wstEth = IWstETH(tokens.wstEth);
        lender = _freshActor(market, "wstEthLeverage.lender");
        user = _freshActor(market, "wstEthLeverage.user");
    }

    function test_leverageLoop_compoundsAllActive_withInstantActivation() public {
        (WstEthWethLeverageRouter router, uint256 initialCollateral) = _routerOverActiveCollateral();
        _setInstantActivation(address(router), true);
        // The router's address may hold balances on the fork already: it must leave them as they were.
        uint256 wethBefore = weth.balanceOf(address(router));
        uint256 wstEthBefore = wstEth.balanceOf(address(router));
        uint256 ethBefore = address(router).balance;

        uint256 target = _loopTarget(initialCollateral);
        vm.prank(user);
        router.openLeveragedPosition(market.params, target, MIN_SWAP_OUT_BPS, MAX_ITERATIONS);

        ILidoLendMarketController.BorrowerPosition memory position = market.controller.positionOf(user);
        // Short of the target by less than the loop's floor: it stops below `MIN_BORROW_PER_ITER`.
        assertApproxEqAbs(position.active, target, 0.001 ether, "the loop reaches the collateral target");
        assertGt(position.active, 2 * initialCollateral, "the router compounds into active collateral");
        assertEq(position.activating, 0, "every router supply is active");
        assertEq(position.dust, 0, "no dust");
        assertGt(market.core.position(market.id, user).borrowShares, 0, "the leveraged collateral backs a debt");
        assertEq(weth.balanceOf(address(router)), wethBefore, "the router keeps no WETH");
        assertEq(wstEth.balanceOf(address(router)), wstEthBefore, "the router keeps no wstETH");
        assertEq(address(router).balance, ethBefore, "the router keeps no ETH");
    }

    function testRevert_leverageLoop_withoutInstantActivation() public {
        (WstEthWethLeverageRouter router, uint256 initialCollateral) = _routerOverActiveCollateral();
        uint256 target = _loopTarget(initialCollateral);
        vm.prank(user);
        vm.expectRevert(ILidoLendMarketController.InsufficientActiveCollateral.selector);
        router.openLeveragedPosition(market.params, target, MIN_SWAP_OUT_BPS, MAX_ITERATIONS);
    }

    /// @dev Deposits the liquidity the loop draws at most, gives `user` active collateral of twice the dust threshold
    ///      and a router that `user` authorizes; the instant-activation grant is each test's own.
    function _routerOverActiveCollateral()
        internal
        returns (WstEthWethLeverageRouter router, uint256 initialCollateral)
    {
        initialCollateral = 2 * uint256(_activationConfig(market).minActivationAmount);
        uint256 maxLoopDebt =
            _loopTarget(initialCollateral) * market.oracle.price() / ORACLE_PRICE_SCALE * market.params.lltv / WAD;
        uint256 liquidity = maxLoopDebt + 10 ether;
        _requireSupplyHeadroom(market, liquidity);
        vm.deal(lender, liquidity);
        vm.startPrank(lender);
        weth.deposit{value: liquidity}();
        weth.approve(address(market.vault), liquidity);
        market.vault.deposit(liquidity, lender);
        vm.stopPrank();
        require(_freeLiquidity() >= maxLoopDebt, "WstEthLeverage: free liquidity does not cover the loop");

        collateralIssuer.dealCollateral(user, initialCollateral);
        vm.startPrank(user);
        wstEth.approve(address(market.core), initialCollateral);
        market.core.supplyCollateral(market.params, initialCollateral, user, "");
        vm.stopPrank();
        _warpPastActivation();

        router = new WstEthWethLeverageRouter(address(market.core), address(weth), wstEth.stETH(), address(wstEth));
        vm.prank(user);
        market.core.setAuthorization(address(router), true);
    }

    /// @dev The first full supply brings the collateral to `initial * (1 + lltv)` at any price; 1.1 dust thresholds
    ///      more makes the second supply a partial one above the threshold, so it activates and the loop stops.
    function _loopTarget(uint256 initialCollateral) internal view returns (uint256) {
        return initialCollateral + initialCollateral * market.params.lltv / WAD
            + uint256(_activationConfig(market).minActivationAmount) * 11 / 10;
    }
}

/// @notice The frontend guide's native-ETH bundles on a market that lends the network's WETH against its wstETH,
///         through the deployed general adapter and the real Lido contracts: ETH staked, wrapped and posted as
///         collateral in one bundle, and a borrow paid out as ETH. Other markets skip.
contract WstEthBundleForkTest is ForkStack {
    IBundler3 internal bundler3;
    IGeneralAdapter1 internal adapter;
    IWstETH internal wstEth;

    function setUp() public {
        _setUpTarget();
        BundlerParameters memory tokens = network.bundler.getConfig();
        if (
            bundler.bundler == address(0) || address(market.loanToken) != tokens.weth
                || address(market.collateralToken) != tokens.wstEth
        ) vm.skip(true, "WstEthBundle: the market does not lend WETH against wstETH through a bundler");
        bundler3 = IBundler3(bundler.bundler);
        adapter = IGeneralAdapter1(bundler.generalAdapter);
        wstEth = IWstETH(tokens.wstEth);
    }

    /// @dev ETH goes to the adapter, to Lido for stETH, is wrapped into wstETH and posted for the user; the stETH
    ///      dust that shares rounding may leave goes back to the user.
    function test_bundle_enterFromEth_stakesWrapsAndPostsTheCollateral() public {
        address user = _freshActor(market, "wstEthBundle.user");
        uint256 amount = lot;
        vm.deal(user, amount);
        uint256 expectedCollateral = wstEth.getWstETHByStETH(amount);

        Call[] memory bundle = new Call[](5);
        bundle[0] = Call({to: address(adapter), data: "", value: amount, skipRevert: false, callbackHash: bytes32(0)});
        bundle[1] = _adapterCall(
            abi.encodeCall(
                IGeneralAdapter1.stakeEth, (type(uint256).max, type(uint256).max, address(0), address(adapter))
            )
        );
        bundle[2] = _adapterCall(abi.encodeCall(IGeneralAdapter1.wrapStEth, (type(uint256).max, address(adapter))));
        bundle[3] = _adapterCall(
            abi.encodeCall(IGeneralAdapter1.morphoSupplyCollateral, (market.params, type(uint256).max, user, ""))
        );
        bundle[4] =
            _adapterCall(abi.encodeCall(IGeneralAdapter1.erc20Transfer, (wstEth.stETH(), user, type(uint256).max)));
        vm.prank(user);
        bundler3.multicall{value: amount}(bundle);

        // stETH moves in shares, so the staked and wrapped amount may fall a wei or two short.
        assertApproxEqAbs(
            market.core.position(market.id, user).collateral, expectedCollateral, 2, "the staked ETH posted as wstETH"
        );
        assertEq(user.balance, 0, "the whole ETH staked");
        assertEq(wstEth.balanceOf(address(adapter)), 0, "no wstETH left on the adapter");
    }

    /// @dev The authorized adapter borrows WETH to itself and unwraps it to the borrower as ETH.
    function test_bundle_borrowToNativeEth() public {
        _seedLenderAndBorrower();
        uint256 assets = _maxBorrow(market, lot, market.oracle.price()) / 10;
        uint256 ethBefore = BORROWER.balance;
        vm.prank(BORROWER);
        market.core.setAuthorization(address(adapter), true);

        Call[] memory bundle = new Call[](2);
        bundle[0] = _adapterCall(
            abi.encodeCall(IGeneralAdapter1.morphoBorrow, (market.params, assets, 0, 0, address(adapter)))
        );
        bundle[1] = _adapterCall(abi.encodeCall(IGeneralAdapter1.unwrapNative, (type(uint256).max, BORROWER)));
        vm.prank(BORROWER);
        bundler3.multicall(bundle);

        assertEq(BORROWER.balance, ethBefore + assets, "the borrow paid out as ETH");
        assertEq(market.loanToken.balanceOf(address(adapter)), 0, "no WETH left on the adapter");
    }

    function _adapterCall(bytes memory data) internal view returns (Call memory) {
        return Call({to: address(adapter), data: data, value: 0, skipRevert: false, callbackHash: bytes32(0)});
    }
}
