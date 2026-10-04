// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Id, MarketParams, Authorization, Signature, IMorphoStaticTyping} from "@lido-lend/src/interfaces/IMorpho.sol";
import {ILidoLend} from "@lido-lend/src/interfaces/ILidoLend.sol";
import {IOracle} from "@lido-lend/src/interfaces/IOracle.sol";
import {MarketParamsLib} from "@lido-lend/src/libraries/MarketParamsLib.sol";
import {MathLib} from "@lido-lend/src/libraries/MathLib.sol";
import {ORACLE_PRICE_SCALE} from "@lido-lend/src/libraries/ConstantsLib.sol";

import {ILidoLendMarketController} from "../../src/interfaces/ILidoLendMarketController.sol";
import {WAD, BPS} from "../../src/libs/Constants.sol";
import {ForkStack} from "./helpers/ForkStack.sol";
import {IWETH, IStETH, IWstETH} from "./helpers/ForkTokens.sol";

/// @title WstEthWethLeverageHelper
/// @notice Leverage-loop entrypoint bound to the wstETH/WETH market. Runs `(borrow -> swap -> supplyCollateral)`
///         cycles atomically on the caller's position. Carried over from a prior protocol version and adapted
///         to the fork core; lives here as a test fixture, not production code.
/// @dev The loop sizes each borrow from the position's RAW collateral. On the fork, borrowing power is gated by
///      ACTIVE collateral, so the loop only compounds when this helper is a trusted instant-activation caller
///      (its supplies skip the activation timer). Without that grant the second borrow hits the activating
///      supply and reverts. That contrast is what the accompanying test exercises.
contract WstEthWethLeverageHelper {
    using MarketParamsLib for MarketParams;
    using MathLib for uint256;

    /// @dev Morpho fork core for this market.
    address public immutable MORPHO;
    /// @dev Loan asset for the supported market (WETH).
    address public immutable WETH;
    /// @dev stETH contract (Lido `submit` target).
    address public immutable STETH;
    /// @dev Collateral asset for the supported market (wstETH).
    address public immutable WSTETH;

    /// @dev Loop floor (0.001 ETH); below this the swap leg's compounded rounding fails slippage.
    uint256 internal constant MIN_BORROW_PER_ITER = 1e15;

    error NotAuthorized();
    error CallerNotAuthorizer();
    error WrongAuthorizationTarget();
    error AuthorizationMustGrant();
    error UnsupportedMarket();
    error MaxIterationsZero();
    error InsufficientCollateralOut();
    error EthSenderNotWeth();

    /// @notice Emitted at the end of a successful leverage loop with the position's before/after deltas.
    event LeveragedPositionOpened(
        address indexed user,
        Id indexed id,
        uint256 collateralBefore,
        uint256 collateralAfter,
        uint256 debtBefore,
        uint256 debtAfter,
        uint256 iterations
    );

    constructor(address morpho, address weth, address steth, address wsteth) {
        MORPHO = morpho;
        WETH = weth;
        STETH = steth;
        WSTETH = wsteth;
        // Infinite approves so loop iterations don't pay an SSTORE for allowance.
        IWstETH(wsteth).approve(morpho, type(uint256).max);
        IStETH(steth).approve(wsteth, type(uint256).max);
    }

    /// @notice Leverage an existing position via a `(borrow -> swap -> supply)` loop. The caller must have
    ///         already supplied collateral and granted this helper an on-behalf authorization on the core.
    function openLeveragedPosition(
        MarketParams calldata marketParams,
        uint256 targetCollateralAmount,
        uint256 minSwapOutBps,
        uint256 maxIterations
    ) external {
        if (!IMorphoStaticTyping(MORPHO).isAuthorized(msg.sender, address(this))) {
            revert NotAuthorized();
        }
        _openLeveragedPosition(marketParams, targetCollateralAmount, minSwapOutBps, maxIterations);
    }

    /// @notice First-time variant. Consumes a one-shot signed authorization in the same tx.
    function openLeveragedPosition(
        MarketParams calldata marketParams,
        uint256 targetCollateralAmount,
        uint256 minSwapOutBps,
        uint256 maxIterations,
        Authorization calldata auth,
        Signature calldata sig
    ) external {
        if (auth.authorizer != msg.sender) revert CallerNotAuthorizer();
        if (auth.authorized != address(this)) revert WrongAuthorizationTarget();
        if (!auth.isAuthorized) revert AuthorizationMustGrant();
        IMorphoStaticTyping(MORPHO).setAuthorizationWithSig(auth, sig);
        _openLeveragedPosition(marketParams, targetCollateralAmount, minSwapOutBps, maxIterations);
    }

    function _openLeveragedPosition(
        MarketParams calldata marketParams,
        uint256 targetCollateralAmount,
        uint256 minSwapOutBps,
        uint256 maxIterations
    ) internal {
        if (marketParams.loanToken != WETH || marketParams.collateralToken != WSTETH) {
            revert UnsupportedMarket();
        }
        if (maxIterations == 0) revert MaxIterationsZero();

        Id id = marketParams.id();
        uint256 collateralPrice = IOracle(marketParams.oracle).price();

        (uint256 collateralBefore, uint256 debtBefore) = _readPositionAssets(id, msg.sender);
        uint256 iterations =
            _runLoop(marketParams, id, collateralPrice, targetCollateralAmount, minSwapOutBps, maxIterations);
        (uint256 collateralAfter, uint256 debtAfter) = _readPositionAssets(id, msg.sender);

        emit LeveragedPositionOpened(
            msg.sender, id, collateralBefore, collateralAfter, debtBefore, debtAfter, iterations
        );
    }

    /// @dev Pulled out so the public entrypoint stays under the stack-depth limit.
    function _runLoop(
        MarketParams calldata marketParams,
        Id id,
        uint256 collateralPrice,
        uint256 targetCollateral,
        uint256 minSwapOutBps,
        uint256 maxIterations
    ) internal returns (uint256 iterations) {
        for (; iterations < maxIterations; iterations++) {
            (uint256 rawCollateral, uint256 debtAssets) = _readPositionAssets(id, msg.sender);
            if (rawCollateral >= targetCollateral) break;

            uint256 borrowAssets =
                _computeNextBorrow(marketParams.lltv, rawCollateral, collateralPrice, debtAssets, targetCollateral);
            if (borrowAssets < MIN_BORROW_PER_ITER) break;

            IMorphoStaticTyping(MORPHO).borrow(marketParams, borrowAssets, 0, msg.sender, address(this));

            uint256 wstethOut = _swap(borrowAssets);

            // wstethOut * price * BPS >= borrowAssets * ORACLE_PRICE_SCALE * minSwapOutBps.
            if (wstethOut * collateralPrice * BPS < borrowAssets * ORACLE_PRICE_SCALE * minSwapOutBps) {
                revert InsufficientCollateralOut();
            }

            IMorphoStaticTyping(MORPHO).supplyCollateral(marketParams, wstethOut, msg.sender, "");
        }
    }

    function _readPositionAssets(Id id, address user)
        internal
        view
        returns (uint256 rawCollateral, uint256 debtAssets)
    {
        (, uint128 borrowShares, uint128 collateral) = IMorphoStaticTyping(MORPHO).position(id, user);
        rawCollateral = collateral;
        if (borrowShares == 0) return (rawCollateral, 0);
        (,, uint128 totalBorrowAssets, uint128 totalBorrowShares,,) = IMorphoStaticTyping(MORPHO).market(id);
        if (totalBorrowShares == 0) return (rawCollateral, 0);
        // Round up against the borrower (Morpho's `toAssetsUp` convention).
        debtAssets =
            (uint256(borrowShares) * uint256(totalBorrowAssets) + uint256(totalBorrowShares) - 1) / totalBorrowShares;
    }

    /// @dev Full raw-LTV headroom, capped by the collateral shortfall to target.
    function _computeNextBorrow(
        uint256 lltv,
        uint256 rawCollateral,
        uint256 collateralPrice,
        uint256 debtAssets,
        uint256 targetCollateral
    ) internal pure returns (uint256) {
        uint256 maxDebt = rawCollateral.mulDivDown(collateralPrice, ORACLE_PRICE_SCALE).mulDivDown(lltv, WAD);
        if (maxDebt <= debtAssets) return 0;
        uint256 headroom = maxDebt - debtAssets;

        if (rawCollateral < targetCollateral) {
            uint256 loanForShortfall = (targetCollateral - rawCollateral) * collateralPrice / ORACLE_PRICE_SCALE;
            if (loanForShortfall < headroom) return loanForShortfall;
        }
        return headroom;
    }

    /// @dev WETH -> ETH -> stETH (Lido `submit`) -> wstETH (wstETH `wrap`).
    function _swap(uint256 wethAmount) internal returns (uint256 wstethOut) {
        IWETH(WETH).withdraw(wethAmount);
        uint256 stEthBefore = IStETH(STETH).balanceOf(address(this));
        IStETH(STETH).submit{value: wethAmount}(address(0));
        uint256 stEthOut = IStETH(STETH).balanceOf(address(this)) - stEthBefore;
        wstethOut = IWstETH(WSTETH).wrap(stEthOut);
    }

    /// @notice Receives ETH only from the WETH contract during the swap leg (`IWETH.withdraw` sends the
    ///         unwrapped ETH back here). Any other sender is rejected.
    receive() external payable {
        if (msg.sender != WETH) revert EthSenderNotWeth();
    }
}

/// @notice Scenario proving the controller's instant-activation is what lets a trusted leverage router compound
///         `(borrow -> swap -> supply)` against the ALREADY-DEPLOYED `weth-wsteth` market (bound via {ForkStack},
///         never re-deployed). With the router granted instant activation every supply is active at once, so the
///         loop reaches its target and all collateral is active. Without it the supplied collateral lands in the
///         activation timer, and the next borrow reverts on insufficient active collateral.
///
///         State-robustness / live-config contract (a shared deployed market may carry pre-existing state and
///         real governance config): actors are fresh and market-clean (`_freshActor`), so per-position reads are
///         deltas; lender liquidity is deposited through the vault and MEASURED to cover the loop's fully-levered
///         draw; and both the seed collateral and the loop target are sized from the LIVE dust floor and LLTV, so
///         every supply that must activate clears `minActivationAmount` at any live wstETH rate.
contract WstEthWethLeverageInstantActivationTest is ForkStack {
    BoundMarket internal m;

    IWETH internal WETH;
    IStETH internal STETH;
    IWstETH internal WSTETH;

    address internal WETH_ADDRESS;
    address internal STETH_ADDRESS;
    address internal WSTETH_ADDRESS;

    // Fresh, market-clean actors (start at zero position and zero vault shares), so per-actor reads are deltas.
    address internal LENDER;
    address internal USER;

    uint256 internal constant MIN_SWAP_OUT_BPS = 9900;
    uint256 internal constant MAX_ITERATIONS = 10;

    struct Stack {
        ILidoLend core;
        ILidoLendMarketController controller;
        MarketParams marketParams;
        Id id;
    }

    function setUp() public {
        _fork();
        string memory market_ = _marketForRole("weth-wsteth");
        if (bytes(market_).length == 0) return; // not applicable to this deployment
        m = _bindMarket(market_);
        _pokeAccrue(m); // fold in pending interest so the fresh borrows below start from an accrued clock

        WETH_ADDRESS = address(m.loanToken);
        STETH_ADDRESS = _ext("stEth");
        WSTETH_ADDRESS = address(m.collateralToken);
        WETH = IWETH(WETH_ADDRESS);
        STETH = IStETH(STETH_ADDRESS);
        WSTETH = IWstETH(WSTETH_ADDRESS);

        LENDER = _freshActor(m, "wstEthWethLeverage.lender");
        USER = _freshActor(m, "wstEthWethLeverage.user");
    }

    /// @notice Granted instant activation, the router compounds the loop: it reaches the collateral target and
    ///         every wstETH it supplied is active (none stuck in the timer), with real debt drawn.
    function test_leverageLoop_compoundsAllActive_withInstantActivation() public {
        (Stack memory s, WstEthWethLeverageHelper helper, uint256 initialCollateral) = _setup();

        // Trust the router: its supplies skip the timer and are active immediately. Granted through the owner
        // facade as the EasyTrack executor, which is the route production uses.
        _setInstantActivation(m, address(helper), true);

        // The router's own token/ETH balances are asserted as DELTAS: its CREATE deployment address may carry a
        // pre-existing balance on the mainnet fork (a real account can already sit there), so "strands nothing"
        // means the loop leaves those balances unchanged, not that they are zero.
        uint256 helperWethBefore = WETH.balanceOf(address(helper));
        uint256 helperWstEthBefore = WSTETH.balanceOf(address(helper));
        uint256 helperEthBefore = address(helper).balance;

        uint256 target = _loopTarget(initialCollateral);
        vm.prank(USER);
        helper.openLeveragedPosition(s.marketParams, target, MIN_SWAP_OUT_BPS, MAX_ITERATIONS);

        ILidoLendMarketController.BorrowerPosition memory pv = s.controller.positionOf(USER);
        // Lands just under target: the loop cannot close a final sub-`MIN_BORROW_PER_ITER` shortfall, and the
        // swap rounds down by a few wei. Tolerance is that floor (0.001 ETH).
        assertApproxEqAbs(pv.active, target, 0.001 ether, "loop reached ~the collateral target");
        assertGt(pv.active, initialCollateral * 2, "router compounded real leverage (>2x) into active collateral");
        assertEq(pv.activating, 0, "every router supply is active, none left in the timer");
        assertEq(pv.dust, 0, "no dust");

        uint128 borrowShares = s.core.position(s.id, USER).borrowShares;
        assertGt(borrowShares, 0, "real debt drawn against the leveraged collateral");

        // The router strands nothing: each iteration borrows, swaps, and supplies the full output, so its
        // balances are unchanged by the loop (measured against the pre-loop snapshot, not against zero).
        assertEq(WETH.balanceOf(address(helper)), helperWethBefore, "router stranded no WETH");
        assertEq(WSTETH.balanceOf(address(helper)), helperWstEthBefore, "router stranded no wstETH");
        assertEq(address(helper).balance, helperEthBefore, "router stranded no ETH");
    }

    /// @notice Without instant activation the router's first supply lands in the activation timer, so the
    ///         second iteration borrows against collateral that is not yet active and the loop reverts.
    function testRevert_leverageLoop_revertsWithoutInstantActivation() public {
        (Stack memory s, WstEthWethLeverageHelper helper, uint256 initialCollateral) = _setup();

        // No instant-activation grant for the router this time. The first loop supply clears the live dust floor
        // (seed is 2x the floor, so its full-LTV supply is well above it) and lands in the activation timer; the
        // second borrow then sizes off the raw (timer-held) collateral and trips the active-collateral gate.
        uint256 target = _loopTarget(initialCollateral);
        vm.prank(USER);
        vm.expectRevert(ILidoLendMarketController.InsufficientActiveCollateral.selector);
        helper.openLeveragedPosition(s.marketParams, target, MIN_SWAP_OUT_BPS, MAX_ITERATIONS);
    }

    // ---
    // HARNESS
    // ---

    /// @dev Binds the deployed stack into the suite's `Stack`, seeds WETH lending liquidity through the vault
    ///      (measured to cover the loop's fully-levered draw), gives USER active initial collateral sized from
    ///      the live dust floor, deploys the router and authorizes it. Leaves the instant-activation grant to the
    ///      individual test.
    function _setup() internal returns (Stack memory s, WstEthWethLeverageHelper helper, uint256 initialCollateral) {
        s.core = m.core;
        s.controller = m.controller;
        s.marketParams = m.params;
        s.id = m.id;

        // USER's initial collateral is 2x the LIVE dust floor: comfortably above `minActivationAmount`, so it
        // enters activation (not dust) and — matured below — becomes borrowable active collateral.
        initialCollateral = 2 * uint256(m.activation.minActivationAmount);
        uint256 target = _loopTarget(initialCollateral);

        // Lending liquidity so the router has WETH to borrow. The loop's debt tops out at `target` collateral
        // fully levered at the market LLTV; deposit that plus headroom through the vault (the lender path), gated
        // by the live supply-cap headroom, then MEASURE free liquidity so a pre-existing borrow cannot starve the
        // loop (a shared market may already carry supply/borrow).
        uint256 maxLoopDebt = target * m.oracle.price() / ORACLE_PRICE_SCALE * m.params.lltv / WAD;
        uint256 liquidity = maxLoopDebt + 10 ether;
        _requireSupplyHeadroom(m, liquidity);
        _mintWETH(LENDER, liquidity);
        vm.prank(LENDER);
        m.vault.deposit(liquidity, LENDER);
        require(
            _freeLiquidity(m) >= maxLoopDebt,
            "WstEthWethLeverage: market free liquidity does not cover the loop's fully-levered draw"
        );

        // Seed USER's collateral directly and mature it: USER is not a trusted caller, so the supply enters the
        // timer; warping past the LIVE activation cap makes it active before the loop, isolating the router's
        // instant grant as the only variable the two tests differ on.
        deal(WSTETH_ADDRESS, USER, initialCollateral);
        vm.startPrank(USER);
        WSTETH.approve(address(s.core), initialCollateral);
        s.core.supplyCollateral(s.marketParams, initialCollateral, USER, "");
        vm.stopPrank();
        _warpPastActivation(m);

        helper = new WstEthWethLeverageHelper(address(s.core), WETH_ADDRESS, STETH_ADDRESS, WSTETH_ADDRESS);
        vm.prank(USER);
        s.core.setAuthorization(address(helper), true);
    }

    /// @dev Collateral target for the loop, sized from the live dust floor and LLTV so the success path lands
    ///      dust-free. The loop's wstETH trajectory is price-independent: each full iteration supplies
    ///      `lltv * collateral - debt`, so after the first full supply raw collateral is `initial * (1 + lltv)`.
    ///      Setting the remaining gap to `1.1x` the dust floor makes the loop close it with a single PARTIAL
    ///      supply that is above the floor (so it activates immediately rather than settling into `dust`) yet
    ///      below the second full supply (`initial * lltv^2`, i.e. `1.28x` the floor at `initial = 2x` floor and
    ///      `lltv = 0.8`), so the loop lands that partial and stops just above `2x` the seed.
    function _loopTarget(uint256 initialCollateral) internal view returns (uint256) {
        uint256 firstReach = initialCollateral + initialCollateral * m.params.lltv / WAD;
        return firstReach + uint256(m.activation.minActivationAmount) * 11 / 10;
    }

    function _mintWETH(address user, uint256 amount) internal {
        vm.deal(user, amount);
        vm.startPrank(user);
        WETH.deposit{value: amount}();
        WETH.approve(address(m.vault), type(uint256).max);
        vm.stopPrank();
    }
}
