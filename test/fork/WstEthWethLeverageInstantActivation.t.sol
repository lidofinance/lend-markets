// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";
import {Id, MarketParams, Authorization, Signature, IMorphoStaticTyping} from "@lido-lend/src/interfaces/IMorpho.sol";
import {ILidoLend} from "@lido-lend/src/interfaces/ILidoLend.sol";
import {IOracle} from "@lido-lend/src/interfaces/IOracle.sol";
import {MarketParamsLib} from "@lido-lend/src/libraries/MarketParamsLib.sol";
import {MathLib} from "@lido-lend/src/libraries/MathLib.sol";
import {ORACLE_PRICE_SCALE} from "@lido-lend/src/libraries/ConstantsLib.sol";

import {LidoLendDeployer} from "../../script/lib/LidoLendDeployer.sol";
import {SettlementConfig} from "../../src/types/SettlementTypes.sol";
import {CollateralActivationConfig} from "../../src/types/CollateralActivationTypes.sol";
import {ILidoLendMarketController} from "../../src/interfaces/ILidoLendMarketController.sol";
import {WAD, BPS} from "../../src/libs/Constants.sol";
import {ForkTest} from "./helpers/ForkTest.sol";

interface IWETH {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

interface IStETH {
    function submit(address referral) external payable returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

interface IWstETH {
    function wrap(uint256 stETHAmount) external returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

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
///         `(borrow -> swap -> supply)` against a freshly deployed real core + controller on a mainnet fork.
///         With the router granted instant activation every supply is active at once, so the loop reaches its
///         target and all collateral is active. Without it the supplied collateral lands in the activation
///         timer, and the next borrow reverts on insufficient active collateral.
contract WstEthWethLeverageInstantActivationTest is Test, LidoLendDeployer, ForkTest {
    // Populated in setUp from deployments/deployed-<network>.json (external.*).
    address internal WETH_ADDRESS;
    address internal STETH_ADDRESS;
    address internal WSTETH_ADDRESS;

    IWETH internal WETH;
    IStETH internal STETH;
    IWstETH internal WSTETH;

    uint256 internal constant LLTV = 0.8e18;

    address internal constant LENDER = address(0x1000);
    address internal constant USER = address(0x2000);

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
        WETH_ADDRESS = _addr("external.weth");
        STETH_ADDRESS = _addr("external.stEth");
        WSTETH_ADDRESS = _addr("external.wstEth");
        WETH = IWETH(WETH_ADDRESS);
        STETH = IStETH(STETH_ADDRESS);
        WSTETH = IWstETH(WSTETH_ADDRESS);
    }

    /// @notice Granted instant activation, the router compounds the loop: it reaches the collateral target and
    ///         every wstETH it supplied is active (none stuck in the timer), with real debt drawn.
    function test_leverageLoop_compoundsAllActive_withInstantActivation() public {
        (Stack memory s, WstEthWethLeverageHelper helper, uint256 initialCollateral) = _setup();

        // Trust the router: its supplies skip the timer and are active immediately.
        s.controller.grantInstantActivation(address(helper));

        uint256 target = initialCollateral * 5 / 2; // ~2.5x, within the LTV asymptote (1 / (1 - lltv) = 5x)
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

        // The router strands nothing: each iteration borrows, swaps, and supplies the full output.
        assertEq(WETH.balanceOf(address(helper)), 0, "no WETH left in the router");
        assertEq(WSTETH.balanceOf(address(helper)), 0, "no wstETH left in the router");
        assertEq(address(helper).balance, 0, "no ETH left in the router");
    }

    /// @notice Without instant activation the router's first supply lands in the activation timer, so the
    ///         second iteration borrows against collateral that is not yet active and the loop reverts.
    function testRevert_leverageLoop_revertsWithoutInstantActivation() public {
        (Stack memory s, WstEthWethLeverageHelper helper, uint256 initialCollateral) = _setup();

        // No instant-activation grant for the router this time.
        uint256 target = initialCollateral * 5 / 2;
        vm.prank(USER);
        vm.expectRevert(ILidoLendMarketController.InsufficientActiveCollateral.selector);
        helper.openLeveragedPosition(s.marketParams, target, MIN_SWAP_OUT_BPS, MAX_ITERATIONS);
    }

    // ---
    // HARNESS
    // ---

    /// @dev Deploys the stack, seeds WETH lending liquidity, gives USER active initial collateral, deploys the
    ///      router and authorizes it. Leaves the instant-activation grant to the individual test.
    function _setup() internal returns (Stack memory s, WstEthWethLeverageHelper helper, uint256 initialCollateral) {
        s = _deployStack();

        // Lending liquidity so the router has WETH to borrow.
        _mintWETH(s.core, LENDER, 100 ether);
        vm.prank(LENDER);
        s.core.supply(s.marketParams, 100 ether, 0, LENDER, "");

        // USER's initial collateral, matured to active by warping past the activation cap (no instant needed
        // for the seed; the test isolates the router's instant grant).
        initialCollateral = _mintWstETH(s.core, USER, 12 ether);
        vm.prank(USER);
        s.core.supplyCollateral(s.marketParams, initialCollateral, USER, "");
        vm.warp(block.timestamp + 2 hours + 1);

        helper = new WstEthWethLeverageHelper(address(s.core), WETH_ADDRESS, STETH_ADDRESS, WSTETH_ADDRESS);
        vm.prank(USER);
        s.core.setAuthorization(address(helper), true);
    }

    function _deployStack() internal returns (Stack memory s) {
        address[] memory guardians = new address[](1);
        guardians[0] = address(this);

        Deployed memory d = _deployForkStack(
            DeployConfig({
                admin: address(this),
                loanToken: WETH_ADDRESS,
                collateralToken: WSTETH_ADDRESS,
                oracleSource: WSTETH_ADDRESS,
                lltv: LLTV,
                enableSettlement: false,
                activation: CollateralActivationConfig({
                    minActivationDelay: 10 minutes,
                    maxActivationDelay: 2 hours,
                    activatingLockAmount: 0,
                    activatingLockDuration: 0,
                    maxDelayInflow: 10_000 ether,
                    minActivationAmount: 1, // every loop supply activates; the test is not about the dust floor
                    maxGuardiansQuorumDelay: 0,
                    delayPerStrike: 0,
                    delayPerSuspect: 0
                }),
                settlementConfig: SettlementConfig({
                    sliceFloorBps: 100, sliceFloorAssets: 0, fullCutBelowCollateral: 10 ether, ltvStepBps: 100
                }),
                guardians: guardians,
                quorum: 1,
                suspectWindow: 0,
                vaultName: "Lido wstETH/WETH Vault",
                vaultSymbol: "lidoWSTETH-WETH"
            })
        );

        s.core = ILidoLend(d.core);
        s.controller = ILidoLendMarketController(d.controllerProxy);
        s.marketParams = d.params;
        s.id = d.marketId;
    }

    function _mintWETH(ILidoLend core, address user, uint256 amount) internal {
        vm.deal(user, amount);
        vm.prank(user);
        WETH.deposit{value: amount}();
        vm.prank(user);
        WETH.approve(address(core), type(uint256).max);
    }

    function _mintWstETH(ILidoLend core, address user, uint256 ethAmount) internal returns (uint256) {
        vm.deal(user, ethAmount);
        vm.prank(user);
        STETH.submit{value: ethAmount}(address(0));

        uint256 stETHAmount = STETH.balanceOf(user);
        vm.prank(user);
        STETH.approve(WSTETH_ADDRESS, stETHAmount);
        vm.prank(user);
        uint256 wstETHAmount = WSTETH.wrap(stETHAmount);
        vm.prank(user);
        WSTETH.approve(address(core), type(uint256).max);
        return wstETHAmount;
    }
}
