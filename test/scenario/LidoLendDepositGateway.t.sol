// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";

import {Id, MarketParams} from "@lido-lend/src/interfaces/IMorpho.sol";
import {LidoLendDepositGateway} from "../../src/periphery/LidoLendDepositGateway.sol";
import {LidoLendDeployer} from "../../script/lib/LidoLendDeployer.sol";

interface IStETH {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function submit(address referral) external payable returns (uint256);
}

interface IERC20Like {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IWETHLike is IERC20Like {
    function deposit() external payable;
}

interface IMarketLike {
    function position(Id id, address user)
        external
        view
        returns (uint256 supplyShares, uint128 borrowShares, uint128 collateral);
}

/// @notice Entry-zap flows of `LidoLendDepositGateway` on a mainnet fork (real WETH / stETH / wstETH)
///         against a freshly deployed market stack.
contract LidoLendDepositGatewayTest is Test, LidoLendDeployer {
    address internal constant WETH_ADDRESS = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant STETH_ADDRESS = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    address internal constant WSTETH_ADDRESS = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;

    IWETHLike internal constant WETH = IWETHLike(WETH_ADDRESS);
    IStETH internal constant STETH = IStETH(STETH_ADDRESS);

    address internal constant LENDER = address(0x1000);
    address internal constant BORROWER = address(0x2000);

    uint256 internal constant LLTV = 0.8e18;

    LidoLendDepositGateway internal gateway;
    Deployed internal d;

    function setUp() public {
        if (!_hasMainnetLidoContracts()) return;

        address[] memory guardians = new address[](1);
        guardians[0] = address(this);

        d = _deployForkStack(
            DeployConfig({
                admin: address(this),
                loanToken: WETH_ADDRESS,
                collateralToken: WSTETH_ADDRESS,
                oracleSource: WSTETH_ADDRESS,
                lltv: LLTV,
                enableSettlement: true,
                activation: ActivationConfig({
                    minActivationDelay: 10 minutes,
                    maxActivationDelay: 2 hours,
                    delayPerStrike: 2 hours,
                    activatingHold: 0,
                    inflowDecayWindow: 4 hours,
                    maxDelayInflow: 10_000 ether,
                    minActivationAmount: 10 ether,
                    minDecayInflow: 1_000 ether
                }),
                slicePolicy: SlicePolicyConfig({sliceFloorBps: 100, sliceFloorAssets: 0, fallbackMinRequest: 0}),
                guardians: guardians,
                quorum: 1,
                vaultName: "Lido wstETH/WETH Vault",
                vaultSymbol: "lidoWSTETH-WETH"
            })
        );

        gateway = new LidoLendDepositGateway(d.core, d.params, d.vault);
    }

    function test_supplyCollateralWithStEth_wrapsAndPostsCollateral() public {
        vm.skip(!_hasMainnetLidoContracts(), "mainnet fork with Lido contracts required");

        vm.deal(BORROWER, 12 ether);
        vm.prank(BORROWER);
        STETH.submit{value: 12 ether}(address(0));
        uint256 stBalance = STETH.balanceOf(BORROWER);

        vm.prank(BORROWER);
        STETH.approve(address(gateway), type(uint256).max);

        (,, uint128 collateralBefore) = IMarketLike(d.core).position(d.marketId, BORROWER);

        vm.prank(BORROWER);
        uint256 wstEthAmount = gateway.supplyCollateralWithStEth(stBalance, BORROWER);

        (,, uint128 collateralAfter) = IMarketLike(d.core).position(d.marketId, BORROWER);
        assertEq(uint256(collateralAfter) - collateralBefore, wstEthAmount, "collateral grew by wrapped amount");
        // stETH leaves up to 1-2 wei of share-rounding dust on transfer/wrap; the gateway holds no
        // meaningful balance.
        assertLe(STETH.balanceOf(address(gateway)), 2, "gateway holds no meaningful stETH");
        assertEq(IERC20Like(WSTETH_ADDRESS).balanceOf(address(gateway)), 0, "gateway holds no wstETH");
        assertLe(STETH.balanceOf(BORROWER), 2, "borrower stETH fully pulled (rebasing dust tolerance)");
    }

    function test_supplyWithEth_wrapsAndSupplies() public {
        vm.skip(!_hasMainnetLidoContracts(), "mainnet fork with Lido contracts required");

        vm.deal(LENDER, 5 ether);

        vm.prank(LENDER);
        (uint256 assets, uint256 shares) = gateway.supplyWithEth{value: 5 ether}(LENDER);

        assertEq(assets, 5 ether, "supplied the full msg.value");
        (uint256 supplyShares,,) = IMarketLike(d.core).position(d.marketId, LENDER);
        assertEq(supplyShares, shares, "supply shares credited to onBehalf");
        assertEq(LENDER.balance, 0, "no ETH left with lender");
        assertEq(WETH.balanceOf(address(gateway)), 0, "gateway holds no WETH");
    }

    function test_supplyWithWeth_pullsAndSupplies() public {
        vm.skip(!_hasMainnetLidoContracts(), "mainnet fork with Lido contracts required");

        vm.deal(LENDER, 5 ether);
        vm.prank(LENDER);
        WETH.deposit{value: 5 ether}();
        vm.prank(LENDER);
        WETH.approve(address(gateway), type(uint256).max);

        vm.prank(LENDER);
        (uint256 assets, uint256 shares) = gateway.supplyWithWeth(5 ether, LENDER);

        assertEq(assets, 5 ether, "supplied the requested WETH");
        (uint256 supplyShares,,) = IMarketLike(d.core).position(d.marketId, LENDER);
        assertEq(supplyShares, shares, "supply shares credited to onBehalf");
        assertEq(WETH.balanceOf(LENDER), 0, "WETH fully pulled");
        assertEq(WETH.balanceOf(address(gateway)), 0, "gateway holds no WETH");
    }

    function test_depositEthToVault_mintsShares() public {
        vm.skip(!_hasMainnetLidoContracts(), "mainnet fork with Lido contracts required");

        vm.deal(LENDER, 5 ether);

        vm.prank(LENDER);
        uint256 shares = gateway.depositEthToVault{value: 5 ether}(LENDER);

        assertGt(shares, 0, "vault shares minted");
        assertEq(IERC20Like(d.vault).balanceOf(LENDER), shares, "shares belong to receiver");
        assertEq(WETH.balanceOf(address(gateway)), 0, "gateway holds no WETH");
        // The vault forwards deposits into the market; its own market position grows.
        (uint256 vaultSupplyShares,,) = IMarketLike(d.core).position(d.marketId, d.vault);
        assertGt(vaultSupplyShares, 0, "vault supplied into the market");
    }

    function testRevert_zeroAmountAndZeroAddress() public {
        vm.skip(!_hasMainnetLidoContracts(), "mainnet fork with Lido contracts required");

        vm.expectRevert(LidoLendDepositGateway.ZeroAmount.selector);
        gateway.supplyCollateralWithStEth(0, BORROWER);

        vm.expectRevert(LidoLendDepositGateway.ZeroAddress.selector);
        gateway.supplyCollateralWithStEth(1 ether, address(0));

        vm.expectRevert(LidoLendDepositGateway.ZeroAmount.selector);
        gateway.supplyWithEth{value: 0}(LENDER);

        vm.deal(address(this), 1 ether);
        vm.expectRevert(LidoLendDepositGateway.ZeroAddress.selector);
        gateway.supplyWithEth{value: 1 ether}(address(0));

        vm.expectRevert(LidoLendDepositGateway.ZeroAmount.selector);
        gateway.supplyWithWeth(0, LENDER);

        vm.expectRevert(LidoLendDepositGateway.ZeroAmount.selector);
        gateway.depositEthToVault{value: 0}(LENDER);
    }

    function _hasMainnetLidoContracts() internal view returns (bool) {
        return block.chainid == 1 && WETH_ADDRESS.code.length != 0 && STETH_ADDRESS.code.length != 0
            && WSTETH_ADDRESS.code.length != 0;
    }
}
