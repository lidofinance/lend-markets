// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IMorpho, Id, MarketParams} from "@lido-lend/src/interfaces/IMorpho.sol";
import {MorphoBalancesLib} from "@lido-lend/src/libraries/periphery/MorphoBalancesLib.sol";

import {ExitBookBase} from "../../src/periphery/ExitBookBase.sol";
import {Erc4626ExitBook} from "../../src/periphery/Erc4626ExitBook.sol";
import {WAD} from "../../src/libs/Constants.sol";
import {Request, ExitStatus, PriorityRamp} from "../../src/types/ExitBookTypes.sol";
import {LidoLendDeployer} from "../../script/lib/LidoLendDeployer.sol";
import {CollateralActivationConfig} from "../../src/types/CollateralActivationTypes.sol";
import {SettlementConfig} from "../../src/types/SettlementTypes.sol";
import {LidoLendMarketController} from "../../src/controllers/LidoLendMarketController.sol";

/// @dev Plain ERC-20 with an open mint, so the suite runs on a bare local chain (no mainnet fork).
contract MockERC20 is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Mutable-price oracle swapped in for `WstEthRateOracle` (Morpho 1e36 convention; 1e36 == parity).
contract FixedPriceOracle {
    uint256 public PRICE;

    constructor(uint256 price_) {
        PRICE = price_;
    }

    function setPrice(uint256 price_) external {
        PRICE = price_;
    }

    function price() external view returns (uint256) {
        return PRICE;
    }
}

interface IVaultLike {
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function maxWithdraw(address owner) external view returns (uint256);
    function previewWithdraw(uint256 assets) external view returns (uint256 shares);
    function previewDeposit(uint256 assets) external view returns (uint256 shares);
}

interface ICoreLike {
    function borrow(MarketParams memory p, uint256 assets, uint256 shares, address onBehalf, address receiver)
        external
        returns (uint256, uint256);
    function repay(MarketParams memory p, uint256 assets, uint256 shares, address onBehalf, bytes memory data)
        external
        returns (uint256, uint256);
    function liquidate(
        MarketParams memory p,
        address borrower,
        uint256 seizedAssets,
        uint256 repaidShares,
        bytes memory data
    ) external returns (uint256, uint256);
    function supplyCollateral(MarketParams memory p, uint256 assets, address onBehalf, bytes memory data) external;
    function position(Id id, address user)
        external
        view
        returns (uint256 supplyShares, uint128 borrowShares, uint128 collateral);
}

/// @notice Scenario coverage for the ERC-4626 exit book on a freshly deployed stack over mock ERC-20s.
contract ExitBookTest is Test, LidoLendDeployer {
    address internal constant LENDER = address(0x1000);
    address internal constant FILLER = address(0x2000);
    address internal constant BORROWER = address(0x3000);
    address internal constant FEE_RECIPIENT = address(0x4000);
    address internal constant REWARD_RECIPIENT = address(0x5000);

    uint256 internal constant LLTV = 0.8e18;
    uint256 internal constant ORACLE_PRICE = 1e36; // collateral:loan parity
    uint256 internal constant SERVICE_FEE = 0.01e18; // 1% cut of the priority fee (WAD)
    uint256 internal constant PRIORITY_FEE = 0.05e18; // 5% priority-fee rate (WAD)
    uint256 internal constant MAX_LIFETIME = 30 days;

    MockERC20 internal loan;
    MockERC20 internal collateral;
    Erc4626ExitBook internal vaultBook;
    Deployed internal d;

    /// @dev Swap the default wstETH oracle for a local price source so no Lido contract is needed. It is mutable
    ///      only so the loss regression can lower the price after placement.
    function _deployOracle(address, address) internal override returns (address) {
        return address(new FixedPriceOracle(ORACLE_PRICE));
    }

    function setUp() public {
        loan = new MockERC20("Loan", "LOAN");
        collateral = new MockERC20("Collateral", "COLL");

        address[] memory guardians = new address[](1);
        guardians[0] = address(this);

        d = _deployForkStack(
            DeployConfig({
                admin: address(this),
                loanToken: address(loan),
                collateralToken: address(collateral),
                oracleSource: address(collateral), // ignored — _deployOracle is overridden
                lltv: LLTV,
                supplyCap: 0,
                enableSettlement: true,
                activation: CollateralActivationConfig({
                    minActivationDelay: 10 minutes,
                    maxActivationDelay: 2 hours,
                    activatingLockDuration: 0,
                    maxDelayInflow: 10_000 ether,
                    minActivationAmount: 10 ether,
                    minDepositAmount: 0,
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
                vaultName: "Lido Loan Vault",
                vaultSymbol: "lidoLOAN"
            })
        );

        vaultBook = new Erc4626ExitBook(address(this), MAX_LIFETIME);
        vaultBook.grantRole(vaultBook.ALLOWLIST_MANAGER_ROLE(), address(this));
        vaultBook.grantRole(vaultBook.FEE_MANAGER_ROLE(), address(this));
        vaultBook.setVaultAllowed(IERC4626(d.vault), true);
        vaultBook.setServiceFee(FEE_RECIPIENT, SERVICE_FEE);
    }

    // ---
    // ERC-4626 BOOK
    // ---

    /* Full single fill at a flat priority fee: flat price → no yield → reward is purely the fee. */
    function test_erc4626_fill_pushesPayouts() public {
        uint256 assets = 10 ether;
        _depositToVault(LENDER, assets);
        uint256 deadline = block.timestamp + 7 days;

        vm.prank(LENDER);
        IVaultLike(d.vault).approve(address(vaultBook), type(uint256).max);
        vm.prank(LENDER);
        uint256 id = vaultBook.placeExitRequest(IERC4626(d.vault), assets, LENDER, 0, 0, _flat(PRIORITY_FEE), deadline);

        Request memory request = vaultBook.getExitRequest(id);
        assertEq(request.owner, LENDER, "owner stored");
        assertEq(request.receiver, LENDER, "receiver stored");
        assertEq(request.assetsRemaining, assets, "size is the requested assets");
        assertEq(uint8(request.status), uint8(ExitStatus.Open), "open");

        uint256 fee = assets * PRIORITY_FEE / WAD;
        uint256 serviceCut = fee * SERVICE_FEE / WAD;
        uint256 lenderBefore = loan.balanceOf(LENDER);
        uint256 fillerBefore = loan.balanceOf(FILLER);
        uint256 recipientBefore = loan.balanceOf(FEE_RECIPIENT);

        vm.warp(deadline);
        vm.prank(FILLER);
        vaultBook.fillExitRequest(id, assets, FILLER);

        assertEq(loan.balanceOf(LENDER) - lenderBefore, assets - fee, "lender: assets minus fee");
        assertEq(loan.balanceOf(FILLER) - fillerBefore, fee - serviceCut, "filler: fee minus cut");
        assertEq(loan.balanceOf(FEE_RECIPIENT) - recipientBefore, serviceCut, "service: cut of gross");
        assertEq(loan.balanceOf(address(vaultBook)), 0, "book never holds a balance");

        request = vaultBook.getExitRequest(id);
        assertEq(uint8(request.status), uint8(ExitStatus.Filled), "filled");
        assertEq(request.assetsRemaining, 0, "fully drained");
    }

    /* Filler prepares source liquidity independently, then routes the fill reward to another address. */
    function test_erc4626_externalDepositThenFill_routesPositionAndRewardIndependently() public {
        _depositToVault(LENDER, 10 ether);
        _drain(BORROWER, 90 ether, 9 ether);
        uint256 id = _place(LENDER, 10 ether, LENDER, 0, _flat(PRIORITY_FEE));
        vm.warp(block.timestamp + 20 days);

        uint256 expectedDeposit = 10 ether - IVaultLike(d.vault).maxWithdraw(LENDER);
        uint256 expectedDepositShares = IVaultLike(d.vault).previewDeposit(expectedDeposit);
        _fund(loan, FILLER, expectedDeposit + 5 ether);
        uint256[5] memory balancesBefore = [
            loan.balanceOf(FILLER),
            IVaultLike(d.vault).balanceOf(FILLER),
            loan.balanceOf(LENDER),
            loan.balanceOf(FEE_RECIPIENT),
            loan.balanceOf(REWARD_RECIPIENT)
        ];
        uint256 priorityFee = Math.mulDiv(10 ether, PRIORITY_FEE, WAD);
        uint256 serviceCut = Math.mulDiv(priorityFee, SERVICE_FEE, WAD);

        vm.startPrank(FILLER);
        loan.approve(d.vault, expectedDeposit);
        IVaultLike(d.vault).deposit(expectedDeposit, FILLER);
        uint256 expectedSharesBurned = IVaultLike(d.vault).previewWithdraw(10 ether);
        vm.expectEmit(true, true, true, true, address(vaultBook));
        emit ExitBookBase.ExitProcessed(
            id,
            FILLER,
            REWARD_RECIPIENT,
            address(loan),
            10 ether,
            expectedSharesBurned,
            priorityFee - serviceCut,
            serviceCut
        );
        vaultBook.fillExitRequest(id, 10 ether, REWARD_RECIPIENT);
        vm.stopPrank();

        assertEq(loan.balanceOf(FILLER), balancesBefore[0] - expectedDeposit, "executor funds its chosen strategy");
        assertEq(
            IVaultLike(d.vault).balanceOf(FILLER) - balancesBefore[1], expectedDepositShares, "deposit shares credited"
        );
        assertEq(IVaultLike(d.vault).balanceOf(REWARD_RECIPIENT), 0, "source position stays with provider");
        assertEq(loan.balanceOf(LENDER) - balancesBefore[2], 10 ether - priorityFee, "receiver payout");
        assertEq(loan.balanceOf(FEE_RECIPIENT) - balancesBefore[3], serviceCut, "service cut");
        assertEq(
            loan.balanceOf(REWARD_RECIPIENT) - balancesBefore[4], priorityFee - serviceCut, "reward routed separately"
        );
        assertEq(uint8(vaultBook.getExitRequest(id).status), uint8(ExitStatus.Filled), "request filled");
    }

    function test_loss_stillFillsExactRequestedAssetsAtLiveSharePrice() public {
        address lender = _actor("lender");
        address borrower = _actor("borrower");
        address filler = _actor("filler");
        _depositToVault(lender, 200 ether);
        _drain(borrower, 160 ether, 80 ether);

        uint256 fillAssets = 50 ether;
        uint256 sharesAtPlacement = IVaultLike(d.vault).previewWithdraw(fillAssets);
        uint256 id = _place(lender, fillAssets, lender, 0, _flat(0));

        FixedPriceOracle(d.oracle).setPrice(ORACLE_PRICE / 10);
        address keeper = _actor("keeper");
        _fund(loan, keeper, 1_000 ether);
        (,, uint128 borrowerCollateral) = ICoreLike(d.core).position(d.marketId, borrower);
        vm.startPrank(keeper);
        loan.approve(d.core, type(uint256).max);
        ICoreLike(d.core).liquidate(d.params, borrower, borrowerCollateral, 0, "");
        vm.stopPrank();

        uint256 liveShares = IVaultLike(d.vault).previewWithdraw(fillAssets);
        assertGt(liveShares, sharesAtPlacement, "loss increases live share burn");
        assertLe(liveShares, IVaultLike(d.vault).balanceOf(lender), "request remains backed");

        uint256 lenderAssetsBefore = loan.balanceOf(lender);
        _fillAndAssert(id, fillAssets, filler);

        assertEq(loan.balanceOf(lender) - lenderAssetsBefore, fillAssets, "asset target is unchanged");
    }

    function test_yield_reducesLiveShareBurnWithoutChangingAssetTarget() public {
        address lender = _actor("lender");
        address filler = _actor("filler");
        _depositToVault(lender, 1_000 ether);
        _drain(_actor("borrower"), 1_600 ether, 800 ether);

        uint256 fillAssets = 100 ether;
        uint256 sharesAtPlacement = IVaultLike(d.vault).previewWithdraw(fillAssets);
        uint256 id = _place(lender, fillAssets, lender, 0, _flat(0));
        vm.warp(block.timestamp + 20 days);

        uint256 liveShares = IVaultLike(d.vault).previewWithdraw(fillAssets);
        assertLt(liveShares, sharesAtPlacement, "yield reduces live share burn");
        uint256 ownerSharesBefore = IVaultLike(d.vault).balanceOf(lender);
        _fillAndAssert(id, fillAssets, filler);
        uint256 ownerSharesAfter = IVaultLike(d.vault).balanceOf(lender);
        assertEq(ownerSharesBefore - ownerSharesAfter, liveShares, "only exact requested assets are withdrawn");
        assertGt(IERC4626(d.vault).previewRedeem(ownerSharesAfter), 900 ether, "accrued yield stays with lender");
        assertEq(uint8(vaultBook.getExitRequest(id).status), uint8(ExitStatus.Filled), "exact target filled");
    }

    function test_repayPreparesLiquidityWithoutUsingExecutorAssets() public {
        address lender = _actor("lender");
        address borrower = _actor("borrower");
        address filler = _actor("filler");
        _depositToVault(lender, 100 ether);
        _drain(borrower, 180 ether, 90 ether);
        uint256 id = _place(lender, 40 ether, lender, 0, _flat(0));

        _repayAll(borrower);
        uint256 assetsBefore = loan.balanceOf(filler);
        uint256 sharesBefore = IVaultLike(d.vault).balanceOf(filler);

        vm.prank(filler);
        vaultBook.fillExitRequest(id, 40 ether, filler);

        assertEq(loan.balanceOf(filler), assetsBefore, "fill does not take executor assets");
        assertEq(IVaultLike(d.vault).balanceOf(filler), sharesBefore, "fill does not create a source position");
    }

    function testRevert_insufficientSourceLiquidity_rollsBackRequestWithoutUsingExecutorAssets() public {
        address lender = _actor("lender");
        address filler = _actor("filler");
        _depositToVault(lender, 100 ether);
        address borrower = _actor("borrower");
        _drain(borrower, 160 ether, 80 ether);
        uint256 id = _place(lender, 40 ether, lender, 0, _flat(0));

        vm.prank(borrower);
        ICoreLike(d.core).borrow(d.params, 10 ether, 0, borrower, borrower);
        uint256 liveCapacity = IVaultLike(d.vault).maxWithdraw(lender);
        assertLt(liveCapacity, 40 ether, "source is illiquid");
        _fund(loan, filler, 40 ether);
        uint256 fillerAssetsBefore = loan.balanceOf(filler);

        vm.prank(filler);
        vm.expectRevert(
            abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxWithdraw.selector, lender, 40 ether, liveCapacity)
        );
        vaultBook.fillExitRequest(id, 40 ether, filler);

        assertEq(loan.balanceOf(filler), fillerAssetsBefore, "executor assets are untouched");
        assertEq(vaultBook.getExitRequest(id).assetsRemaining, 40 ether, "request debit rolled back");
    }

    function test_externalSelfDepositThenFill_preservesLenderBalances() public {
        address lender = _actor("lender");
        _depositToVault(lender, 100 ether);
        _drain(_actor("borrower"), 200 ether, 100 ether);
        uint256 id = _place(lender, 40 ether, lender, 0, _flat(0));

        _fund(loan, lender, 40 ether);
        uint256 assetsBefore = loan.balanceOf(lender);
        uint256 sharesBefore = IVaultLike(d.vault).balanceOf(lender);

        vm.startPrank(lender);
        loan.approve(d.vault, 40 ether);
        IVaultLike(d.vault).deposit(40 ether, lender);
        vaultBook.fillExitRequest(id, 40 ether, lender);
        vm.stopPrank();

        assertEq(loan.balanceOf(lender), assetsBefore, "self-filler recovers externally supplied assets");
        assertEq(IVaultLike(d.vault).balanceOf(lender), sharesBefore, "external mint offsets the fill burn");
        assertEq(uint8(vaultBook.getExitRequest(id).status), uint8(ExitStatus.Filled), "request filled");
    }

    function testRevert_sourcePause_blocksExactWithdrawalAndRollsBackRequest() public {
        address lender = _actor("lender");
        _depositToVault(lender, 20 ether);
        uint256 id = _place(lender, 10 ether, lender, 0, _flat(0));

        LidoLendMarketController controller = LidoLendMarketController(d.controllerProxy);
        controller.grantRole(controller.PAUSER_ROLE(), address(this));
        controller.pauseFor(1 days);
        address filler = _actor("filler");
        vm.prank(filler);
        vm.expectRevert(abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxWithdraw.selector, lender, 10 ether, 0));
        vaultBook.fillExitRequest(id, 10 ether, filler);

        assertEq(vaultBook.getExitRequest(id).assetsRemaining, 10 ether, "request debit rolled back");
    }

    function test_sourceFreeze_allowsExternalDepositAndExactWithdrawal() public {
        address lender = _actor("lender");
        address filler = _actor("filler");
        _depositToVault(lender, 100 ether);
        _drain(_actor("borrower"), 180 ether, 90 ether);
        uint256 id = _place(lender, 40 ether, lender, 0, _flat(0));
        uint256 requiredDeposit = 40 ether - IVaultLike(d.vault).maxWithdraw(lender);
        _fund(loan, filler, requiredDeposit);
        LidoLendMarketController controller = LidoLendMarketController(d.controllerProxy);
        controller.grantRole(controller.FREEZER_ROLE(), address(this));
        controller.freeze();

        vm.startPrank(filler);
        loan.approve(d.vault, requiredDeposit);
        IVaultLike(d.vault).deposit(requiredDeposit, filler);
        vaultBook.fillExitRequest(id, 40 ether, filler);
        vm.stopPrank();

        assertEq(
            uint8(vaultBook.getExitRequest(id).status), uint8(ExitStatus.Filled), "freeze leaves lender exits open"
        );
    }

    // ---
    // HELPERS
    // ---

    /// @dev A flat priority fee: `rate` from creation, no ramp.
    function _flat(uint256 rate) internal pure returns (PriorityRamp memory) {
        return PriorityRamp({startRate: rate, endRate: rate, rampStart: 0, rampEnd: 0});
    }

    function _depositToVault(address lender, uint256 amount) internal returns (uint256 shares) {
        loan.mint(lender, amount);
        vm.startPrank(lender);
        loan.approve(d.vault, type(uint256).max);
        shares = IVaultLike(d.vault).deposit(amount, lender);
        vm.stopPrank();
    }

    function _place(address lender, uint256 assets, address receiver, uint256 minFillAssets, PriorityRamp memory ramp)
        internal
        returns (uint256 id)
    {
        vm.startPrank(lender);
        IVaultLike(d.vault).approve(address(vaultBook), type(uint256).max);
        id = vaultBook.placeExitRequest(
            IERC4626(d.vault), assets, receiver, minFillAssets, 0, ramp, block.timestamp + MAX_LIFETIME
        );
        vm.stopPrank();
    }

    /// @dev Borrower posts collateral, waits out activation, and borrows to drain idle loan liquidity.
    function _drain(address borrower, uint256 collateralAmount, uint256 borrowAmount) internal {
        collateral.mint(borrower, collateralAmount);
        vm.startPrank(borrower);
        collateral.approve(d.core, type(uint256).max);
        ICoreLike(d.core).supplyCollateral(d.params, collateralAmount, borrower, "");
        vm.stopPrank();

        vm.warp(block.timestamp + 2 hours + 1);
        vm.prank(borrower);
        ICoreLike(d.core).borrow(d.params, borrowAmount, 0, borrower, borrower);
    }

    function _repayAll(address borrower) internal {
        (, uint128 borrowShares,) = ICoreLike(d.core).position(d.marketId, borrower);
        loan.mint(borrower, 1_000 ether);
        vm.startPrank(borrower);
        loan.approve(d.core, type(uint256).max);
        ICoreLike(d.core).repay(d.params, 0, borrowShares, borrower, "");
        vm.stopPrank();
    }

    function _actor(string memory name) internal returns (address) {
        return makeAddr(name);
    }

    function _fund(MockERC20 token, address account, uint256 amount) internal {
        token.mint(account, amount);
    }

    function _priorityRate(Request memory request) internal view returns (uint256) {
        uint256 elapsed = block.timestamp - request.createdAt;
        if (elapsed < request.rampStart) return request.startRate;
        if (elapsed >= request.rampEnd) return request.endRate;
        return request.startRate + (request.endRate - request.startRate) * (elapsed - request.rampStart)
            / (request.rampEnd - request.rampStart);
    }

    function _fillAndAssert(uint256 id, uint256 fillAssets, address filler) internal {
        Request memory requestBefore = vaultBook.getExitRequest(id);
        uint256 sharesToBurn = IVaultLike(d.vault).previewWithdraw(fillAssets);
        uint256 ownerSharesBefore = IVaultLike(d.vault).balanceOf(requestBefore.owner);
        uint256[3] memory balancesBefore =
            [loan.balanceOf(requestBefore.receiver), loan.balanceOf(filler), loan.balanceOf(FEE_RECIPIENT)];

        uint256 priorityFee = Math.mulDiv(fillAssets, _priorityRate(requestBefore), WAD);
        uint256 serviceCut = Math.mulDiv(priorityFee, SERVICE_FEE, WAD);

        vm.prank(filler);
        vaultBook.fillExitRequest(id, fillAssets, filler);

        assertEq(
            loan.balanceOf(requestBefore.receiver) - balancesBefore[0], fillAssets - priorityFee, "receiver payout"
        );
        assertEq(loan.balanceOf(filler) - balancesBefore[1], priorityFee - serviceCut, "filler reward");
        assertEq(loan.balanceOf(FEE_RECIPIENT) - balancesBefore[2], serviceCut, "service cut");
        assertEq(
            ownerSharesBefore - IVaultLike(d.vault).balanceOf(requestBefore.owner), sharesToBurn, "live shares burned"
        );

        Request memory requestAfter = vaultBook.getExitRequest(id);
        assertEq(requestBefore.assetsRemaining - requestAfter.assetsRemaining, fillAssets, "exact request debit");
        assertEq(loan.balanceOf(address(vaultBook)), 0, "book retains no assets");
    }
}
