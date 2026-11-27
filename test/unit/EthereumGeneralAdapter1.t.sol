// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Call} from "@bundler3/src/interfaces/IBundler3.sol";
import {ErrorsLib as BundlerErrorsLib} from "@bundler3/src/libraries/ErrorsLib.sol";

import {BundlerSetup} from "../setup/BundlerSetup.sol";

/// @notice The Lido actions of the vendored `EthereumGeneralAdapter1` that the bundled market flows do not take: a
///         third-party receiver of the stETH and wstETH legs, the zero-amount and share-price guards, and the
///         constructor's wstETH check. Bundles reach the adapter through the deployed Bundler3, as `onlyBundler3`
///         requires; the stETH and wstETH mocks run at non-parity rates.
contract EthereumGeneralAdapter1Test is BundlerSetup {
    function setUp() public {
        _deployBundledMarket();
    }

    // ---
    // CONSTRUCTOR
    // ---

    function testRevert_constructor_zeroWstEth() public {
        bytes memory initCode = abi.encodePacked(
            vm.getCode("EthereumGeneralAdapter1.sol:EthereumGeneralAdapter1"),
            abi.encode(address(bundler3), address(protocol.core), address(weth), address(0))
        );
        (bool deployed, bytes memory revertData) = _create(initCode);
        assertFalse(deployed, "zero wstETH is rejected");
        assertEq(revertData, abi.encodeWithSelector(BundlerErrorsLib.ZeroAddress.selector), "ZeroAddress");
    }

    // ---
    // stakeEth
    // ---

    function test_stakeEth_toThirdParty_transfersStEth() public {
        address staker = _actor("staker");
        address receiver = _actor("stEthReceiver");
        uint256 amount = 1 ether;
        vm.deal(staker, amount);

        // The limit is exactly the share price paid, the largest price the guard accepts.
        Call[] memory bundle = new Call[](2);
        bundle[0] = _callValue(address(adapter), "", amount);
        bundle[1] =
            _adapterCall(abi.encodeCall(adapter.stakeEth, (amount, _sharePriceE27(amount), address(0), receiver)));
        _exec(staker, amount, bundle);

        assertEq(steth.balanceOf(receiver), amount, "receiver holds the staked stETH");
        assertEq(staker.balance, 0, "all ETH staked");
    }

    function testRevert_stakeEth_zeroAmount() public {
        Call[] memory bundle = new Call[](1);
        bundle[0] =
            _adapterCall(abi.encodeCall(adapter.stakeEth, (0, MAX_SHARE_PRICE_E27, address(0), _actor("staker"))));

        vm.expectRevert(BundlerErrorsLib.ZeroAmount.selector);
        bundler3.multicall(bundle);
    }

    function testRevert_stakeEth_sharePriceAboveLimit() public {
        address staker = _actor("staker");
        uint256 amount = 1 ether;
        vm.deal(staker, amount);

        Call[] memory bundle = new Call[](2);
        bundle[0] = _callValue(address(adapter), "", amount);
        bundle[1] =
            _adapterCall(abi.encodeCall(adapter.stakeEth, (amount, _sharePriceE27(amount) - 1, address(0), staker)));

        vm.prank(staker);
        vm.expectRevert(BundlerErrorsLib.SlippageExceeded.selector);
        bundler3.multicall{value: amount}(bundle);
    }

    // ---
    // wrapStEth / unwrapStEth
    // ---

    function test_wrapStEth_toThirdParty_transfersWstEth() public {
        address holder = _actor("stEthHolder");
        address receiver = _actor("wstEthReceiver");
        uint256 amount = 1.5 ether;
        steth.mint(holder, amount);
        vm.prank(holder);
        steth.approve(address(adapter), amount);
        uint256 expectedWst = (amount * 1e18) / wsteth.stEthPerToken();

        Call[] memory bundle = new Call[](2);
        bundle[0] = _adapterCall(abi.encodeCall(adapter.erc20TransferFrom, (address(steth), address(adapter), amount)));
        bundle[1] = _adapterCall(abi.encodeCall(adapter.wrapStEth, (type(uint256).max, receiver)));
        _exec(holder, 0, bundle);

        assertEq(wsteth.balanceOf(receiver), expectedWst, "receiver holds the wrapped wstETH");
        assertEq(steth.balanceOf(holder), 0, "holder's stETH was wrapped");
    }

    /// @dev The Lido actions are `onlyBundler3`: a direct call, even from the would-be initiator, reverts.
    function testRevert_lidoActions_outsideBundle() public {
        vm.expectRevert(BundlerErrorsLib.UnauthorizedSender.selector);
        adapter.stakeEth(1 ether, MAX_SHARE_PRICE_E27, address(0), address(this));
        vm.expectRevert(BundlerErrorsLib.UnauthorizedSender.selector);
        adapter.wrapStEth(1 ether, address(this));
        vm.expectRevert(BundlerErrorsLib.UnauthorizedSender.selector);
        adapter.unwrapStEth(1 ether, address(this));
    }

    function testRevert_wrapStEth_zeroAmount() public {
        Call[] memory bundle = new Call[](1);
        bundle[0] = _adapterCall(abi.encodeCall(adapter.wrapStEth, (0, _actor("wrapper"))));

        vm.expectRevert(BundlerErrorsLib.ZeroAmount.selector);
        bundler3.multicall(bundle);
    }

    /// @dev Unwrapped to the adapter itself, the stETH stays there for the next step: a max-amount transfer of it
    ///      would revert `ZeroAmount` had it been sent on.
    function test_unwrapStEth_toAdapter_keepsStEthForNextStep() public {
        address holder = _actor("wstEthHolder");
        address receiver = _actor("stEthReceiver");
        uint256 amount = 2 ether;
        wsteth.mint(holder, amount);
        vm.prank(holder);
        wsteth.approve(address(adapter), amount);
        uint256 expectedStEth = (amount * wsteth.stEthPerToken()) / 1e18;

        Call[] memory bundle = new Call[](3);
        bundle[0] = _adapterCall(abi.encodeCall(adapter.erc20TransferFrom, (address(wsteth), address(adapter), amount)));
        bundle[1] = _adapterCall(abi.encodeCall(adapter.unwrapStEth, (type(uint256).max, address(adapter))));
        bundle[2] = _adapterCall(abi.encodeCall(adapter.erc20Transfer, (address(steth), receiver, type(uint256).max)));
        _exec(holder, 0, bundle);

        assertEq(steth.balanceOf(receiver), expectedStEth, "the adapter's stETH reached the next step");
        assertEq(wsteth.balanceOf(holder), 0, "holder's wstETH was unwrapped");
    }

    function testRevert_unwrapStEth_zeroAmount() public {
        Call[] memory bundle = new Call[](1);
        bundle[0] = _adapterCall(abi.encodeCall(adapter.unwrapStEth, (0, _actor("unwrapper"))));

        vm.expectRevert(BundlerErrorsLib.ZeroAmount.selector);
        bundler3.multicall(bundle);
    }

    // ---
    // HELPERS
    // ---

    /// @dev Wei paid per stETH share, in ray, rounded up as the adapter's guard rounds it: `MockStETH` mints stETH 1:1
    ///      for ETH and reports shares at `stEthPerShare` stETH each.
    function _sharePriceE27(uint256 amount) internal view returns (uint256) {
        uint256 shares = (amount * 1e18) / steth.stEthPerShare();
        return (amount * 1e27 + shares - 1) / shares;
    }

    /// @dev A raw `create` that returns the constructor's revert data. The adapter pins solc 0.8.28, so this suite
    ///      cannot `new` it, and `deployCode` drops the revert reason.
    function _create(bytes memory initCode) private returns (bool deployed, bytes memory revertData) {
        address created;
        assembly ("memory-safe") {
            created := create(0, add(initCode, 0x20), mload(initCode))
            revertData := mload(0x40)
            mstore(revertData, returndatasize())
            returndatacopy(add(revertData, 0x20), 0, returndatasize())
            mstore(0x40, and(add(add(revertData, 0x3f), returndatasize()), not(0x1f)))
        }
        deployed = created != address(0);
    }
}
