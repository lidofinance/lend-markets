// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";
import {OssifiableProxy} from "../../src/proxy/OssifiableProxy.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {IERC1967} from "@openzeppelin/contracts/interfaces/IERC1967.sol";

/// @dev Minimal implementation to sit behind the proxy: an initializer, a setter to prove delegation, and a
///      `receive` so the proxy's `receive` -> `_fallback` -> delegatecall path lands somewhere.
contract Impl {
    uint256 public value;

    function initialize(uint256 v) external {
        value = v;
    }

    function setValue(uint256 v) external {
        value = v;
    }

    receive() external payable {}
}

contract Impl2 is Impl {}

/// @notice Unit suite for `OssifiableProxy`'s admin surface: the `onlyAdmin` gate (both sides), every `proxy__*`
///         mutator and getter, the ossify one-way lock, `receive`, and the inherited ERC-1967 reverts.
contract OssifiableProxyTest is Test {
    Impl internal impl;
    OssifiableProxy internal proxy;

    address internal constant ADMIN = address(0xA11CE);
    address internal constant STRANGER = address(0xB0B);

    function setUp() public {
        impl = new Impl();
        proxy = new OssifiableProxy(address(impl), ADMIN, "");
    }

    function _impl(OssifiableProxy p) internal view returns (address) {
        return p.proxy__getImplementation();
    }

    // ── getters ──

    function test_getters_initialState() public view {
        assertEq(proxy.proxy__getAdmin(), ADMIN, "admin");
        assertEq(proxy.proxy__getImplementation(), address(impl), "implementation");
        assertFalse(proxy.proxy__getIsOssified(), "not ossified");
    }

    // ── construction ──

    function test_constructor_runsInitData() public {
        OssifiableProxy p = new OssifiableProxy(address(impl), ADMIN, abi.encodeCall(Impl.initialize, (7)));
        assertEq(Impl(payable(address(p))).value(), 7, "init delegatecall ran");
    }

    function test_constructor_emptyData_skipsInit() public {
        // setUp already deployed with empty data; nothing initialized, but the proxy is live and delegates.
        assertEq(Impl(payable(address(proxy))).value(), 0, "no init ran");
    }

    function test_constructor_revertsOnNonContractImplementation() public {
        vm.expectRevert(abi.encodeWithSelector(ERC1967Utils.ERC1967InvalidImplementation.selector, STRANGER));
        new OssifiableProxy(STRANGER, ADMIN, "");
    }

    // ── changeAdmin ──

    function test_changeAdmin() public {
        vm.expectEmit(false, false, false, true, address(proxy));
        emit IERC1967.AdminChanged(ADMIN, STRANGER);
        vm.prank(ADMIN);
        proxy.proxy__changeAdmin(STRANGER);
        assertEq(proxy.proxy__getAdmin(), STRANGER, "admin rotated");
    }

    function test_changeAdmin_onlyAdmin() public {
        vm.prank(STRANGER);
        vm.expectRevert(OssifiableProxy.NotAdmin.selector);
        proxy.proxy__changeAdmin(STRANGER);
    }

    function test_changeAdmin_zeroReverts() public {
        vm.prank(ADMIN);
        vm.expectRevert(abi.encodeWithSelector(ERC1967Utils.ERC1967InvalidAdmin.selector, address(0)));
        proxy.proxy__changeAdmin(address(0));
    }

    // ── upgradeTo ──

    function test_upgradeTo() public {
        Impl2 impl2 = new Impl2();
        vm.expectEmit(true, false, false, false, address(proxy));
        emit IERC1967.Upgraded(address(impl2));
        vm.prank(ADMIN);
        proxy.proxy__upgradeTo(address(impl2));
        assertEq(_impl(proxy), address(impl2), "implementation upgraded");
    }

    function test_upgradeTo_onlyAdmin() public {
        Impl2 impl2 = new Impl2();
        vm.prank(STRANGER);
        vm.expectRevert(OssifiableProxy.NotAdmin.selector);
        proxy.proxy__upgradeTo(address(impl2));
    }

    // ── upgradeToAndCall ──

    function test_upgradeToAndCall_withSetupData() public {
        Impl2 impl2 = new Impl2();
        vm.expectEmit(true, false, false, false, address(proxy));
        emit IERC1967.Upgraded(address(impl2));
        vm.prank(ADMIN);
        proxy.proxy__upgradeToAndCall(address(impl2), abi.encodeCall(Impl.setValue, (9)));
        assertEq(_impl(proxy), address(impl2), "upgraded");
        assertEq(Impl(payable(address(proxy))).value(), 9, "setup call ran");
    }

    function test_upgradeToAndCall_emptyData_skipsCall() public {
        Impl2 impl2 = new Impl2();
        vm.prank(ADMIN);
        proxy.proxy__upgradeToAndCall(address(impl2), "");
        assertEq(_impl(proxy), address(impl2), "upgraded, no setup call");
    }

    function test_upgradeToAndCall_onlyAdmin() public {
        Impl2 impl2 = new Impl2();
        vm.prank(STRANGER);
        vm.expectRevert(OssifiableProxy.NotAdmin.selector);
        proxy.proxy__upgradeToAndCall(address(impl2), "");
    }

    // ── ossify ──

    function test_ossify() public {
        vm.expectEmit(true, true, false, false, address(proxy));
        emit IERC1967.AdminChanged(ADMIN, address(0));
        vm.expectEmit(false, false, false, false, address(proxy));
        emit OssifiableProxy.ProxyOssified();

        vm.prank(ADMIN);
        proxy.proxy__ossify();

        assertTrue(proxy.proxy__getIsOssified(), "ossified");
        assertEq(proxy.proxy__getAdmin(), address(0), "admin zeroed");
    }

    function test_ossify_onlyAdmin() public {
        vm.prank(STRANGER);
        vm.expectRevert(OssifiableProxy.NotAdmin.selector);
        proxy.proxy__ossify();
    }

    /// @dev After ossification the admin slot is zero, so even the former admin trips the ossified branch.
    function test_afterOssify_adminCallsRevertOssified() public {
        vm.prank(ADMIN);
        proxy.proxy__ossify();

        vm.prank(ADMIN);
        vm.expectRevert(OssifiableProxy.ProxyIsOssified.selector);
        proxy.proxy__changeAdmin(STRANGER);
    }

    // ── receive ──

    function test_receive_delegatesAndHoldsEther() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(proxy).call{value: 1 ether}("");
        assertTrue(ok, "receive path succeeded");
        assertEq(address(proxy).balance, 1 ether, "ether held by the proxy");
    }
}
