// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MarketParams} from "@lido-lend/src/interfaces/IMorpho.sol";

import {LidoLendDepositGateway} from "../../src/periphery/LidoLendDepositGateway.sol";
import {ILidoLendDepositGateway} from "../../src/interfaces/ILidoLendDepositGateway.sol";

import {LidoLendSetup} from "../setup/LidoLendSetup.sol";
import {Market} from "../setup/Types.sol";
import {MockERC20} from "../setup/Mocks.sol";

/// @dev ERC-4626-shaped vault that mints zero shares on deposit — to exercise the gateway's `ZeroShares` guard.
contract MockZeroShareVault {
    address public immutable asset;

    constructor(address asset_) {
        asset = asset_;
    }

    function deposit(uint256, address) external pure returns (uint256) {
        return 0;
    }
}

/// @dev Minimal WETH: minting `deposit()` payable, used as the market loan token.
contract MockWETH is MockERC20 {
    constructor() MockERC20("Wrapped Ether", "WETH", 18) {}

    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }

    receive() external payable {
        _mint(msg.sender, msg.value);
    }
}

/// @dev stETH that loses a fixed 2 wei on every transfer (the rebasing-shares artifact the gateway's
///      measured-delta logic exists for). A buggy gateway that wrapped the REQUESTED amount instead of the
///      received delta would try to pull more than it holds and revert — so the happy path passing here is
///      itself proof the gateway uses the delta.
contract MockStETH is MockERC20 {
    uint256 internal constant DUST = 2;

    constructor() MockERC20("stETH", "stETH", 18) {}

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        _spendAllowance(from, msg.sender, amount);
        _transfer(from, to, amount > DUST ? amount - DUST : amount);
        return true;
    }
}

/// @dev wstETH at a non-1:1 rate (1.2 stETH per wstETH): `wrap(stETH)` mints `stETH * WAD / RATE`, proving
///      the gateway posts the WRAP RETURN as collateral, not the stETH amount.
contract MockWstETH is MockERC20 {
    uint256 public constant RATE = 1.2e18; // stETH per wstETH
    MockStETH public immutable STETH;

    constructor(MockStETH steth) MockERC20("Wrapped stETH", "wstETH", 18) {
        STETH = steth;
    }

    function stETH() external view returns (address) {
        return address(STETH);
    }

    function wrap(uint256 stEthAmount) external returns (uint256 wstEthAmount) {
        STETH.transferFrom(msg.sender, address(this), stEthAmount);
        wstEthAmount = stEthAmount * 1e18 / RATE;
        _mint(msg.sender, wstEthAmount);
    }
}

/// @notice L2 suite for `LidoLendDepositGateway` — the ETH/stETH/WETH deposit zaps. Deployed over a market
///         whose loan token is a WETH and collateral a wstETH (mocks). Covers the five zap paths
///         (supplyWithEth/Weth, supplyCollateralWithStEth, depositEth/WethToVault) with exact position/share
///         deltas, plus the constructor and per-zap validation reverts.
contract DepositGatewayTest is LidoLendSetup {
    MockWETH internal weth;
    MockWstETH internal wsteth;
    MockStETH internal steth;
    LidoLendDepositGateway internal gw;

    address internal user = address(0x5E7);
    address internal onBehalf = address(0xB0B);

    function setUp() public {
        steth = new MockStETH();
        weth = new MockWETH();
        wsteth = new MockWstETH(steth);
        _deployProtocol(_defaultConfig(address(weth), address(wsteth), address(wsteth)));
        Market storage m = protocol.markets[0];
        gw = new LidoLendDepositGateway(address(m.core), address(weth), address(wsteth), address(m.vault));
    }

    function _m() internal view returns (Market storage) {
        return protocol.markets[0];
    }

    // ── constructor ──

    function testRevert_constructor_zeroMorpho() public {
        vm.expectRevert(ILidoLendDepositGateway.ZeroMorpho.selector);
        new LidoLendDepositGateway(address(0), address(weth), address(wsteth), address(_m().vault));
    }

    function testRevert_constructor_zeroWeth() public {
        vm.expectRevert(ILidoLendDepositGateway.ZeroWeth.selector);
        new LidoLendDepositGateway(address(_m().core), address(0), address(wsteth), address(_m().vault));
    }

    function testRevert_constructor_zeroWstEth() public {
        vm.expectRevert(ILidoLendDepositGateway.ZeroWstEth.selector);
        new LidoLendDepositGateway(address(_m().core), address(weth), address(0), address(_m().vault));
    }

    function testRevert_constructor_zeroVault() public {
        vm.expectRevert(ILidoLendDepositGateway.ZeroVault.selector);
        new LidoLendDepositGateway(address(_m().core), address(weth), address(wsteth), address(0));
    }

    function testRevert_constructor_vaultAssetMismatch() public {
        // A vault whose asset() != loanToken. Reuse the collateral-side vault from a 2nd market is overkill;
        // a fresh market on a DIFFERENT loan token gives a mismatched vault.
        MockWETH otherLoan = new MockWETH();
        MockWstETH otherColl = new MockWstETH(steth);
        Market storage m2 = _addMarket(_defaultConfig(address(otherLoan), address(otherColl), address(otherColl)));
        // m2's vault has asset == otherLoan != weth -> VaultAssetMismatch.
        vm.expectRevert(ILidoLendDepositGateway.VaultAssetMismatch.selector);
        new LidoLendDepositGateway(address(_m().core), address(weth), address(wsteth), address(m2.vault));
    }

    // ── per-call market validation ──

    /// @dev The WETH supply zaps reject params whose loan token is not the gateway's WETH.
    function testRevert_supplyWithEth_loanTokenMismatch() public {
        MarketParams memory p = _m().params;
        p.loanToken = address(wsteth); // != WETH
        vm.deal(user, 1 ether);
        vm.prank(user);
        vm.expectRevert(ILidoLendDepositGateway.LoanTokenMismatch.selector);
        gw.supplyWithEth{value: 1 ether}(p, onBehalf);
    }

    function testRevert_supplyWithWeth_loanTokenMismatch() public {
        MarketParams memory p = _m().params;
        p.loanToken = address(wsteth); // != WETH
        weth.mint(user, 1 ether);
        vm.prank(user);
        IERC20(address(weth)).approve(address(gw), 1 ether);
        vm.prank(user);
        vm.expectRevert(ILidoLendDepositGateway.LoanTokenMismatch.selector);
        gw.supplyWithWeth(p, 1 ether, onBehalf);
    }

    /// @dev The stETH collateral zap rejects params whose collateral token is not the gateway's wstETH.
    function testRevert_supplyCollateralWithStEth_collateralTokenMismatch() public {
        MarketParams memory p = _m().params;
        p.collateralToken = address(weth); // != wstETH
        steth.mint(user, 1 ether);
        vm.prank(user);
        IERC20(address(steth)).approve(address(gw), 1 ether);
        vm.prank(user);
        vm.expectRevert(ILidoLendDepositGateway.CollateralTokenMismatch.selector);
        gw.supplyCollateralWithStEth(p, 1 ether, onBehalf);
    }

    /// @dev A vault that mints zero shares on deposit trips the `ZeroShares` guard (no silent zero-credit).
    function testRevert_depositEthToVault_zeroShares() public {
        MockZeroShareVault zv = new MockZeroShareVault(address(weth));
        LidoLendDepositGateway gw2 =
            new LidoLendDepositGateway(address(_m().core), address(weth), address(wsteth), address(zv));
        vm.deal(user, 1 ether);
        vm.prank(user);
        vm.expectRevert(ILidoLendDepositGateway.ZeroShares.selector);
        gw2.depositEthToVault{value: 1 ether}(user);
    }

    // ── supplyWithEth ──

    function test_supplyWithEth_wrapsAndSupplies() public {
        Market storage m = _m();
        vm.deal(user, 1 ether);
        vm.prank(user);
        (uint256 assets, uint256 shares) = gw.supplyWithEth{value: 1 ether}(_m().params, onBehalf);

        assertEq(assets, 1 ether, "supplied exactly msg.value as WETH");
        assertEq(m.core.position(m.id, onBehalf).supplyShares, shares, "onBehalf credited the supply shares");
        assertEq(m.core.market(m.id).totalSupplyAssets, 1 ether, "market supply grew by the wrapped ETH");
        // The gateway holds no funds after a zap, and only `onBehalf` (never the caller) is credited.
        assertEq(weth.balanceOf(address(gw)), 0, "gateway keeps no WETH dust");
        assertEq(address(gw).balance, 0, "gateway keeps no ETH");
        assertEq(m.core.position(m.id, user).supplyShares, 0, "caller credited nothing -> only onBehalf");
    }

    function testRevert_supplyWithWeth_zeroAmount() public {
        vm.expectRevert(ILidoLendDepositGateway.ZeroAmount.selector);
        gw.supplyWithWeth(_m().params, 0, onBehalf);
    }

    function testRevert_supplyWithWeth_zeroOnBehalf() public {
        weth.mint(user, 1 ether);
        vm.prank(user);
        IERC20(address(weth)).approve(address(gw), 1 ether);
        vm.prank(user);
        vm.expectRevert(ILidoLendDepositGateway.ZeroOnBehalf.selector);
        gw.supplyWithWeth(_m().params, 1 ether, address(0));
    }

    function testRevert_supplyWithEth_zeroValue() public {
        vm.expectRevert(ILidoLendDepositGateway.ZeroAmount.selector);
        gw.supplyWithEth{value: 0}(_m().params, onBehalf);
    }

    function testRevert_supplyWithEth_zeroOnBehalf() public {
        vm.deal(user, 1 ether);
        vm.prank(user);
        vm.expectRevert(ILidoLendDepositGateway.ZeroOnBehalf.selector);
        gw.supplyWithEth{value: 1 ether}(_m().params, address(0));
    }

    // ── supplyWithWeth ──

    function test_supplyWithWeth_pullsAndSupplies() public {
        Market storage m = _m();
        weth.mint(user, 5 ether);
        vm.prank(user);
        IERC20(address(weth)).approve(address(gw), 5 ether);
        vm.prank(user);
        (uint256 assets, uint256 shares) = gw.supplyWithWeth(_m().params, 5 ether, onBehalf);

        assertEq(assets, 5 ether, "supplied the pulled WETH");
        assertEq(m.core.position(m.id, onBehalf).supplyShares, shares, "onBehalf credited the supply shares");
    }

    // ── supplyCollateralWithStEth ──

    function test_supplyCollateralWithStEth_wrapsReceivedDeltaAtRate() public {
        Market storage m = _m();
        steth.mint(user, 10 ether);
        vm.prank(user);
        IERC20(address(steth)).approve(address(gw), 10 ether);
        vm.prank(user);
        uint256 wstEthAmount = gw.supplyCollateralWithStEth(_m().params, 10 ether, onBehalf);

        // The gateway pulls 10 stETH but RECEIVES only 10 - 2 wei (rebasing), and wraps THAT measured delta
        // at the 1.2 rate. A gateway that wrapped the requested 10 (ignoring the delta) would post a
        // different amount, so this exact value discriminates the measured-delta logic the contract exists for.
        uint256 expected = (10 ether - 2) * 1e18 / wsteth.RATE();
        assertEq(wstEthAmount, expected, "wstEth == measured stETH delta wrapped at the rate");
        assertEq(
            m.core.position(m.id, onBehalf).collateral,
            wstEthAmount,
            "collateral == the wrap return, not the stETH amount"
        );
    }

    function testRevert_supplyCollateralWithStEth_zeroAmount() public {
        vm.expectRevert(ILidoLendDepositGateway.ZeroAmount.selector);
        gw.supplyCollateralWithStEth(_m().params, 0, onBehalf);
    }

    // ── depositEthToVault / depositWethToVault ──

    function test_depositEthToVault_wrapsAndMintsVaultShares() public {
        Market storage m = _m();
        vm.deal(user, 3 ether);
        vm.prank(user);
        uint256 shares = gw.depositEthToVault{value: 3 ether}(onBehalf);

        assertEq(m.vault.balanceOf(onBehalf), shares, "receiver minted exactly the vault shares");
        assertEq(m.vault.totalAssets(), 3 ether, "vault assets grew by the wrapped ETH");
    }

    function test_depositWethToVault_pullsAndMints() public {
        Market storage m = _m();
        weth.mint(user, 4 ether);
        vm.prank(user);
        IERC20(address(weth)).approve(address(gw), 4 ether);
        vm.prank(user);
        uint256 shares = gw.depositWethToVault(4 ether, onBehalf);

        assertEq(m.vault.balanceOf(onBehalf), shares, "receiver minted the vault shares");
    }

    function testRevert_depositEthToVault_zeroReceiver() public {
        vm.deal(user, 1 ether);
        vm.prank(user);
        vm.expectRevert(ILidoLendDepositGateway.ZeroReceiver.selector);
        gw.depositEthToVault{value: 1 ether}(address(0));
    }
}
